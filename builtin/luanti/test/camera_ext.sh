#!/bin/bash
# tier: full
# [THIRD_PERSON]: the extension client's camera key against official
# Luanti's server, the three views shot: local/camera_ext/first.png,
# behind.png, front.png; the stage is camera.lua's as a worldmod. Needs the
# Luanti checkout and its server binary the way episode.sh does.
#
#   builtin/luanti/test/camera_ext.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/camera_ext"; mkdir -p "$out"
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
look_dir 0 -0.1 1
delay 1500
screenshot $out/first.png
keypress C
delay 1500
event scan cam
delay 300
screenshot $out/behind.png
keypress C
delay 1500
screenshot $out/front.png
keypress C
delay 500
quit
CMDS
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=cam \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep -a "person view\|E " "$out/extension_cli.log" | sed 's/.*: //' | head -5
# [OVER_SHOULDER]'s open reading: where the camera and the model were in the
# frame the back view was shot in, said by the client itself
grep -a "camera at " "$out/extension_cli.log" | sed 's/.*: camera at/camera at/' | tail -1
ls "$out"/*.png
