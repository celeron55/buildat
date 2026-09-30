#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [WATER_LIGHT]: the shore where a flow meets a pool, in a world of a fixed
# seed at a fixed place, shot once as the code stands and once with
# BUILDAT_LIQUID_CORNER_AVG=1 (the corner rule before ce2a4eaf).
#
# **The two shots agree, and that is what this asserts.** Luanti's
# getCornerLevel() answers a corner that any source touches with the full
# height of the voxel and returns there; the averaging it replaced only ever
# differed where a source carries a variant of its own, and no game
# installed here gives its water one -- so the rule is a parity guard with
# nothing in this stage to show for it. A difference here means something
# else moved.
#
# What it also prints is the reading [WATER_LIGHT] 2 is about: the flowing
# row against the pool beside it, the same surface at the same angle.
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
	bin/buildat_server -u launcher=1 -m ../games/vanilla -D ../user -P 29788 \
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
	{ echo "wait_log 180000 chat: liquid_shore: ready"
		# And the client's own world drawn before the shot, not only the
		# server's light settled
		echo "wait_log 120000 0 undrawn within 2"
		echo "delay 8000"
		# Straight down: the flowing row under the eye, the pool just
		# beyond it, both flat-on and both near
		echo "look 0 -89"
		echo "delay 1500"
		echo "screenshot $out/top_$1.png"
		# And across the shore, which is where the corner rule would show
		echo "look 0 -25"
		echo "delay 1500"
		echo "screenshot $out/$1.png"
		echo "delay 500"
		echo "quit"; } > "$out/cmds_$1.txt"
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
def mean(im, box):
	d = list(im.crop(box).getdata())
	return sum(sum(p) for p in d) / (3.0 * len(d))
def band(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("RGB")
	w, h = im.size
	# Looking straight down over the waterline: the pool runs away from the
	# eye and the flowing row is the strip nearest it, so the two are the
	# halves above and below the middle of the frame
	box = (w // 3, h // 2 - 70, 2 * w // 3, h // 2 + 10)
	d = list(im.crop(box).getdata())
	blue = sum(1 for p in d if p[2] > p[0] + 12 and p[2] > 40)
	return sum(sum(p) for p in d) / (3.0 * len(d)), 100.0 * blue / len(d), im
a, ab, ia = band("level")
b, bb, ib = band("sagged")
print("the shore's band: level %.2f (%.1f %% water), averaged %.2f (%.1f %%)"
		% (a, ab, b, bb))
print("the two shots differ by %.2f levels and %.1f points of water" %
		(abs(a - b), abs(ab - bb)))
# And what [WATER_LIGHT] 2 asks, off the shot taken straight down: the
# flowing row is the band under the eye and the pool the band beyond it,
# both flat-on and both near, so nothing but the two nodes differs
it = Image.open("%s/top_level.png" % out).convert("RGB")
w, h = it.size
# The boundary runs a little below the middle of the frame: the pool is
# what is beyond it and the flowing row what is this side of it
flow = mean(it, (w // 3, h // 2 + 30, 2 * w // 3, h // 2 + 80))
pool = mean(it, (w // 3, h // 2 - 190, 2 * w // 3, h // 2 - 130))
print("straight down: the pool reads %.1f and the flowing row %.1f, "
		"%.1f apart" % (pool, flow, flow - pool))
# [WATER_LIGHT] 2: the two are the same water in the same light seen the
# same way, so what is left between them is the game's own art -- a flow
# twice the pool's brightness is a tint that did not reach it
near = abs(flow - pool) < 0.25 * pool
same = abs(a - b) < 0.5 and abs(ab - bb) < 0.5
ok = same and near
print("PASS: the shore is the same either way and the flowing row is the "
		"pool's own colour" if ok else
		"FAIL: shore %.2f apart, flow and pool %.1f apart" % (
		abs(a - b), abs(flow - pool)))
sys.exit(0 if ok else 1)
PY
