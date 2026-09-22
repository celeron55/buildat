#!/bin/bash
# [BOX_PLAYTEST_2] (9b): the minimap's brightness over half a minute. The
# stamp is drawn a few times a second and its meter used to get one step per
# stamp, so the map cycled between white and right; this shoots the minimap
# corner every four seconds and prints each shot's mean and white share.
#
#   builtin/luanti/test/minimap_exposure.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/minimap_exposure"
mkdir -p "$out"
save=buildat_test_minimap_exposure
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/camera.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29783 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
{
	echo "wait_log 60000 camera: the floor and the wall are placed"
	echo "delay 3000"
	for i in $(seq 1 8); do
		echo "screenshot $out/map_$i.png"
		echo "delay 4000"
	done
	echo "quit"
} > "$out/cmds.txt"
bin/buildat -s localhost:29783 -w 1280x720 -l 3 -c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
python3 - "$out" <<'PY'
import sys, statistics
from PIL import Image
out = sys.argv[1]
means = []
for i in range(1, 9):
	im = Image.open("%s/map_%d.png" % (out, i)).convert("L")
	w, h = im.size
	# The minimap sits in the top right corner, ten pixels in, 128 across
	# at this window size
	crop = im.crop((w - 138, 10, w - 10, 138))
	data = list(crop.getdata())
	mean = statistics.mean(data)
	white = 100.0 * sum(1 for v in data if v > 250) / len(data)
	means.append(mean)
	print("shot %d: mean %.0f, white %.2f %%" % (i, mean, white))
spread = max(means) - min(means)
print("spread %.0f levels over %d shots" % (spread, len(means)))
print("FAIL: the minimap's level moves between stamps" if spread > 20
		else "PASS: the minimap holds its level")
sys.exit(1 if spread > 20 else 0)
PY
