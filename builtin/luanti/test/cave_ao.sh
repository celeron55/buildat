#!/bin/bash
# [CAVE_AO]: one picture of a cave chamber whose nibbles are both nought,
# at whatever floor under the ambient is asked for. The ladder the user
# picks off is made by running this once per value:
#
#   for f in 0 0.01 0.02 0.04; do FLOOR=$f builtin/luanti/test/cave_ao.sh; done
#
# and the pictures land in local/options_for_CAVE_AO/floor<f>.png.
#
# The exposure is pinned (BUILDAT_LUANTI_KEY): with the meter free a
# darker room is simply metered brighter and every floor looks the same,
# which is the trap [DARK_INVARIANT]'s pair fell into first.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
FLOOR="${FLOOR:-0}"
out="$here/local/options_for_CAVE_AO"; mkdir -p "$out"
save=buildat_test_caveao
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-mineclone2}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_PBR="${MODE:-pbr}" \
	BUILDAT_LUANTI_LUA="$me/cave_ao.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29797 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
{ for what in dark torch; do
		echo "wait_log 240000 chat: cave_ao: ready $what"
		echo "delay 6000"
		echo "screenshot $out/${what}_floor$FLOOR${BUILDAT_SKY_REACH:+_reach$BUILDAT_SKY_REACH}.png"
	done
	echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
BUILDAT_CAVE_AO_FLOOR="$FLOOR" BUILDAT_LUANTI_KEY="${KEY:-0.15}" \
	bin/buildat -s localhost:29797 -w 640x480 -l 3 -c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep -a "chat: cave_ao:" "$out/cli.log" | sed 's/.*chat: //'
python3 - "$out" "$FLOOR" <<'PY'
import sys, os
from PIL import Image
out, floor = sys.argv[1], sys.argv[2]
for what in ("dark", "torch"):
	im = Image.open("%s/%s_floor%s%s.png" % (out, what, floor, os.environ.get("BUILDAT_SKY_REACH") and "_reach" + os.environ["BUILDAT_SKY_REACH"] or "")).convert("RGB")
	w, h = im.size
	box = (w // 4, h // 6, 3 * w // 4, 2 * h // 3)
	d = list(im.crop(box).getdata())
	n = float(len(d))
	mean = sum(sum(p) for p in d) / (3.0 * n)
	# What the ladder is actually about: whether there is any shape in
	# the dark at all. The spread of the crop says it -- a flat black
	# room has none, a room whose corners are shaped has some.
	lum = sorted(sum(p) / 3.0 for p in d)
	p10, p90 = lum[int(n * 0.10)], lum[int(n * 0.90)]
	print("floor %-4s %-5s: mean %6.2f, the crop's 10th to 90th "
			"percentile %6.2f to %6.2f, spread %6.2f" %
			(floor, what, mean, p10, p90, p90 - p10))
PY
