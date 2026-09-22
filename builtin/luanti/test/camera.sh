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
wait_log 60000 the server put the player
wait_log 60000 0 undrawn within 2
delay 2000
look_dir 0 -0.6 1
delay 1500
screenshot $out/first.png
keypress C
delay 1500
screenshot $out/behind.png
event scan
look_dir 1 -0.3 0
delay 1200
event scan
screenshot $out/behind_turned.png
look_dir 0 0.8 1
delay 1200
screenshot $out/behind_up.png
look_dir 0 -0.8 1
delay 1200
screenshot $out/behind_down.png
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
grep -a "self model at" "$out/cli.log" | sed 's/.*: scan/scan/'
# The back view's pitch follows the look ([BOX_PLAYTEST_4] 3): looking up
# the sky is the top of the frame, looking down the ground is the bottom
python3 - "$out" <<'PY'
import sys, statistics
from PIL import Image
out = sys.argv[1]
r = {}
for n in ("behind_up", "behind_down"):
	im = Image.open("%s/%s.png" % (out, n)).convert("L")
	w, h = im.size
	r[n] = (statistics.mean(list(im.crop((0, 0, w, h // 3)).getdata())),
			statistics.mean(list(im.crop((0, 2 * h // 3, w, h)).getdata())))
print("behind, looking up: top %.0f bottom %.0f; down: top %.0f bottom %.0f" %
		(r["behind_up"][0], r["behind_up"][1], r["behind_down"][0], r["behind_down"][1]))
print("PASS: the back view's pitch follows the look"
		if r["behind_up"][0] > r["behind_up"][1] and r["behind_down"][0] < r["behind_down"][1]
		else "FAIL: the back view's pitch is inverted")
PY
grep "person view\|camera:\| E " "$out/cli.log" | sed 's/.*: //'
ls "$out"/*.png
