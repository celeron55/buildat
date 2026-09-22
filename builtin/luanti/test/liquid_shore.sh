#!/bin/bash
# [WATER_LIGHT] 3: the shore where a flow meets a pool. Luanti's
# getCornerLevel() answers a corner that any source touches with the full
# height of the voxel; this used to average the source in with the flow, and
# the shore sagged into it. The same pool is shot twice -- once as it is and
# once with BUILDAT_LIQUID_CORNER_AVG=1, which puts the averaging back --
# and the waterline's band is read in each.
#
#   builtin/luanti/test/liquid_shore.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/liquid_shore"; mkdir -p "$out"
save=buildat_test_liquid_shore
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-mineclone2}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_PBR=unlit \
	BUILDAT_LUANTI_LUA="$me/liquid_shore.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29788 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
shoot() { # <tag> <env>
	printf 'wait_log 180000 chat: liquid_shore: ready\ndelay 6000\nscreenshot %s/%s.png\ndelay 500\nquit\n' \
		"$out" "$1" > "$out/cmds_$1.txt"
	env $2 bin/buildat -s localhost:29788 -w 1280x720 -l 3 \
		-c @"$out/cmds_$1.txt" 2>&1 |
		sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli_$1.log"
}
shoot level "BUILDAT_LIQUID_CORNER_AVG="
sleep 3
shoot sagged "BUILDAT_LIQUID_CORNER_AVG=1"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
def band(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("RGB")
	w, h = im.size
	# The waterline runs across the middle of the frame; the flowing row is
	# the band just below it
	box = (w // 4, h // 2 - 40, 3 * w // 4, h // 2 + 60)
	d = list(im.crop(box).getdata())
	blue = sum(1 for p in d if p[2] > p[0] + 12 and p[2] > 40)
	return sum(sum(p) for p in d) / (3.0 * len(d)), 100.0 * blue / len(d), im
a, ab, ia = band("level")
b, bb, ib = band("sagged")
print("the shore's band: level %.2f (%.1f %% water), averaged %.2f (%.1f %%)"
		% (a, ab, b, bb))
print("the two shots differ by %.2f levels and %.1f points of water" %
		(abs(a - b), abs(ab - bb)))
moved = abs(a - b) > 0.5 or abs(ab - bb) > 0.5
print("PASS: the source's corner is what the shore stands at, and the "
		"averaging draws it differently" if moved else
		"FAIL: the two rules draw the same shore")
sys.exit(0 if moved else 1)
PY
