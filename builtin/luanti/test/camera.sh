#!/bin/bash
# [THIRD_PERSON]: the camera key cycled through the three views and each
# shot: local/camera/first.png, behind.png, front.png. The stage is
# camera.lua's floor with a wall two nodes behind the player. Prints the
# chat lines the client logged for the modes.
#
#   builtin/luanti/test/camera.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/camera"
mkdir -p "$out"
save=buildat_test_camera
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/camera.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29778 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
delay 20000
look_dir 0 -0.1 1
delay 1500
screenshot $out/first.png
keypress C
delay 1500
screenshot $out/behind.png
keypress C
delay 1500
screenshot $out/front.png
keypress C
delay 500
quit
CMDS
bin/buildat -s localhost:29778 -w 1280x720 -l 3 -c @"$out/cmds.txt" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "person view\|camera:\| E " "$out/cli.log" | sed 's/.*: //'
ls "$out"/*.png
