#!/bin/bash
# games/launch_world: [LAUNCH_WORLD]'s palette experiment. One picture of
# each of the four presets from the one viewpoint, into
# local/options_for_LAUNCH_WORLD/, which is what settles the palette.
#
# It is also a check: four presets that differ have to come out as four
# pictures that differ, so a preset that quietly stops being applied fails
# a run rather than producing four copies of the same room.
#
#   games/launch_world/check.sh
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD"; mkdir -p "$out"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
bin/buildat_server -m ../games/launch_world -D ../user -P 29795 -l 3 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 60); do
	grep -q "Server::start\|Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
names="cold_in_warm_out warm_in_cold_out all_cold wrong"
{ echo "delay 5000"
	n=1
	for name in $names; do
		echo "keypress $n"
		echo "delay 800"
		echo "screenshot $out/$n-$name.png"
		n=$((n + 1))
	done
	echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
bin/buildat -s localhost:29795 -w 1280x720 -l 3 -c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep -a "palette preset" "$out/cli.log" | sed 's/.*launch_world: //'
python3 - "$out" <<'PY'
import sys, os, itertools
from PIL import Image, ImageChops
out = sys.argv[1]
shots = sorted(f for f in os.listdir(out) if f.endswith(".png"))
if len(shots) != 4:
	print("FAIL: %d pictures, wanted 4" % len(shots)); sys.exit(1)
ims = {}
for f in shots:
	im = Image.open(os.path.join(out, f)).convert("RGB")
	d = list(im.getdata())
	n = float(len(d))
	ims[f] = (im, tuple(sum(p[i] for p in d) / n for i in range(3)))
	print("%-28s mean rgb %5.1f %5.1f %5.1f" % ((f,) + ims[f][1]))
worst = 255.0
for a, b in itertools.combinations(shots, 2):
	d = ImageChops.difference(ims[a][0], ims[b][0])
	px = list(d.getdata())
	mean = sum(sum(p) for p in px) / (3.0 * len(px))
	worst = min(worst, mean)
print("the closest two presets are %.2f of a level apart" % worst)
ok = worst > 1.0
print("PASS: the four presets are four pictures" if ok
		else "FAIL: two presets look the same")
sys.exit(0 if ok else 1)
PY
