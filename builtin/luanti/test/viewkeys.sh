#!/bin/bash
# [VIEW_KEYS]: F3 (fog), Z held (zoom) and F12 (the engine's screenshot)
# driven on camera.lua's stage: local/viewkeys/plain.png, nofog.png,
# zoom.png and back.png; then V through the minimap's modes: map_x2.png,
# map_x1.png, radar_x4.png, map_off.png. Prints the chat and log lines the keys made.
#
#   builtin/luanti/test/viewkeys.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/viewkeys"
mkdir -p "$out"
save=buildat_test_viewkeys
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
wait_log 60000 the server put the player
wait_log 60000 0 undrawn within 2
delay 2000
look_dir 0 -0.1 1
delay 1500
screenshot $out/plain.png
keypress F3
delay 1500
screenshot $out/nofog.png
keypress F3
keydown Z
delay 1500
screenshot $out/zoom.png
keyup Z
delay 800
screenshot $out/back.png
keypress F12
delay 1500
keypress V
delay 1200
screenshot $out/map_x2.png
keypress V
delay 1200
screenshot $out/map_x1.png
keypress V
delay 1200
screenshot $out/radar_x4.png
keypress V
keypress V
keypress V
delay 1200
screenshot $out/map_off.png
keypress F11
delay 4000
screenshot $out/fullscreen.png
keypress F11
delay 4000
screenshot $out/after_f11.png
delay 500
quit
CMDS
bin/buildat -s localhost:29778 -w 1280x720 -l 3 -c @"$out/cmds.txt" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "chat (local)\|F12: screenshot\| E " "$out/cli.log" | sed 's/.*: //'
ls "$out"/*.png
# F11 twice: the world drawn in and after fullscreen ([BOX_PLAYTEST_3] 1;
# the extension's atlas is filled by hand, vanilla's is voxelworld's,
# which already restores -- this is the check that says so)
python3 - "$out" <<'PY'
import sys, statistics
from PIL import Image
out = sys.argv[1]
means = {}
for n in ("plain", "fullscreen", "after_f11"):
	im = Image.open("%s/%s.png" % (out, n)).convert("L")
	w, h = im.size
	means[n] = statistics.mean(list(im.crop((0, h // 2, w, h)).getdata()))
print("frame means: " + ", ".join("%s %.0f" % (k, v) for k, v in means.items()))
print("FAIL: the world went black across a screen mode change" if min(means.values()) < 25
		else "PASS: drawn before, in and after fullscreen")
PY
