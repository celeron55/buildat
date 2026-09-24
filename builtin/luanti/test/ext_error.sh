#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [MENU_ERRORS]: an error raised inside a session is a notice line and not
# a dialog -- a dialog under a world takes the mouse from the player. A
# worldmod sends the client a formspec it cannot read; the client's log says
# which way the error was shown. Needs the Luanti checkout the way
# camera_ext.sh does.
#
#   builtin/luanti/test/ext_error.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/ext_error"; mkdir -p "$out"
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
{ cat "$me/camera.lua"; cat <<'LUA'
core.register_on_joinplayer(function(player)
	core.after(9, function()
		core.show_formspec(player:get_player_name(), "broken",
				"formspec_version[9]size[8,8]nosuchelement[1,1;2,2;x;y]"..
				"image[a,b;c,d;nope.png]field[]")
		core.log("action", "ext_error: the broken formspec is sent")
	end)
end)
LUA
} > "$work/worldmods/camera/init.lua"
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
wait_log 60000 error shown
delay 1500
screenshot $out/notice.png
delay 500
quit
CMDS
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=cam \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
shown=$(grep -a "error shown" "$out/extension_cli.log" | sed 's/.*error shown /error shown /' | head -2)
echo "${shown:-no error was reported}"
if echo "$shown" | grep -q "as a notice"; then
	echo "PASS: the error under a session is a notice line"
else
	echo "FAIL: the error under a session was not a notice"
	exit 1
fi
