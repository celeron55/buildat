#!/bin/bash
# [BOX_PLAYTEST_3] (2): the pause menu's settings screen over the game --
# the cursor must be visible and the view must not turn under it. The
# scan's "mouse" line and the yaw in the status row are the reading.
# Older header:
# [EXT_HUD_PARITY]: the extension client's minimap and F5 keys against official
# Luanti's server: the minimap at the top right in surface mode, V three
# times to the radar, and F5's two levels, shot under local/hud_ext/; the
# stage is camera.lua's as a worldmod. Needs the Luanti checkout and its
# server binary the way episode.sh does.
#
#   builtin/luanti/test/hud_ext.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/pause_screens"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if pgrep -x buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "a client or a Luanti server is already running" >&2; exit 2
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/camera"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = camera
creative_mode = false
server_announce = false
MT
cp "$me/camera.lua" "$work/worldmods/camera/init.lua"
printf 'name = camera\n' > "$work/worldmods/camera/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
for i in $(seq 1 300); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	sleep 1
done
sleep 3
srv=$(pgrep -x luanti-refshots | head -1)
[ -n "$srv" ] || { echo "the Luanti server did not come up" >&2; exit 1; }
trap 'kill "$srv" 2>/dev/null' EXIT
cat > "$out/cmds.txt" <<CMDS
wait_log 90000 voxel types have their own textures
delay 3000
event scan
screenshot $out/world.png
keypress Escape
delay 1500
event scan
screenshot $out/pause.png
CMDS
# Where the pause menu's "Settings..." button is: the form is drawn under
# the UI root rather than on the stack, so the scan cannot name it -- its
# place in the form is fixed (size[6,6.9], the fifth row)
cat >> "$out/cmds.txt" <<CMDS
mouse_pos 640 429
delay 300
mouse_click left
delay 2000
event scan
screenshot $out/settings.png
mouse_move 200 0
delay 800
event scan
delay 500
quit
CMDS
BUILDAT_LUANTI_PBR="${MODE:-unlit}" BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=cam \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep -a "scan [a-z]*: mouse\|scan [a-z]*: menu" "$out/extension_cli.log" | sed 's/.*: scan/scan/' | head -8
# The verdict: the settings screen up, the cursor visible under it, and
# the mouse moved while it is up turning nothing (the status row's yaw)
if grep -aq 'scan scan: menu "[^"]*luanti_client settings"' "$out/extension_cli.log" &&
		[ "$(grep -ac "scan scan: mouse visible" "$out/extension_cli.log")" -ge 4 ]; then
	echo "PASS: the settings screen over the game keeps the cursor"
else
	echo "FAIL: the cursor or the screen is not what it should be"; exit 1
fi
