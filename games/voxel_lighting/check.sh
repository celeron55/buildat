#!/bin/bash
# games/voxel_lighting: **the look check, run rather than eyeballed**
# ([LOOK_CHECK], the rule the user calls not negotiable: a game's look is
# not allowed to change, and a change under builtin/voxel_shading or the
# mesher is checked against this game's views). The views themselves are
# `check.txt`, which a person has been driving by hand -- so "a change
# passes it by not being run" ([CHECK_BASELINE]).
#
#   games/voxel_lighting/check.sh            # against the kept reference
#   games/voxel_lighting/check.sh --accept   # this run becomes it
#
# **What it compares**: the fourteen framings of check.txt, each against
# the same framing of the reference run in local/voxel_lighting/ref/, by
# RMSE. The numbers are printed whatever the verdict, because the size
# of a difference is the reading -- two runs of the same code measured 0
# for nine views, 3.9 to 6.1 for three and 28.9 for the pond, while the
# change that put the speckle back measured 72 to 868
# ([CHECK_BASELINE], 2026-09-19). So the bar is 30: under it is the
# noise this scene has, over it is a change somebody has to look at.
#
# **The reference is a run, not a committed picture** (user,
# 2026-09-19): no image set in git. Until a BASELINE commit is picked,
# the reference is the last run somebody accepted on this machine, and a
# tree with no reference yet says so rather than passing.
#
# tier: quick
# cost: 35s
# covers: builtin/voxel_shading/** src/impl/mesh.cpp src/impl/voxel.cpp src/impl/voxel_volume.cpp builtin/voxelworld/**
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/builtin/luanti/test/lib.sh"
out="$here/local/voxel_lighting"; mkdir -p "$out"
ref="$out/ref"
run="$out/run"
accept=""
[ "${1:-}" = "--accept" ] && accept=1
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi

# check.txt writes into ../tmp/voxel_lighting_check/, which is this
# game's own scratch and is where a person's hand run leaves them too
shots="$here/tmp/voxel_lighting_check"
rm -rf "$shots"; mkdir -p "$shots"
rm -rf "$run"; mkdir -p "$run"

port=31881
rm -f "$out/server.log"
bin/buildat_server -m ../games/voxel_lighting -D ../user -P "$port" -l 3 \
	> "$out/server.log" 2>&1 &
server=$!
for i in $(seq 1 180); do
	grep -aq "STATUS Listening" "$out/server.log" && break
	sleep 1
done
if ! grep -aq "STATUS Listening" "$out/server.log"; then
	kill -9 "$server" 2>/dev/null; wait "$server" 2>/dev/null
	echo "the server did not come up:"
	tail -5 "$out/server.log"
	echo "SKIP: the voxel_lighting server does not start here" >&2
	exit 2
fi

# **The window size is the check's, not the desk's**: the framings are
# comparable between runs only at one size, and -w leaves the remembered
# one alone
run_client 90 "$out/cli.log" timeout 300 bin/buildat -s "localhost:$port" \
	-w 1600x900 -l 3 -c @../games/voxel_lighting/check.txt > /dev/null 2>&1
rc=$?
kill "$server" 2>/dev/null; wait "$server" 2>/dev/null
cp "$shots"/*.png "$run"/ 2>/dev/null
shot_count=$(ls "$run"/*.png 2>/dev/null | wc -l)
echo "the run drew $shot_count views (client status $rc)"
if [ "$shot_count" -lt 14 ]; then
	echo "FAIL: the run did not draw every view"
	tail -3 "$out/cli.log"
	exit 1
fi

if [ -n "$accept" ]; then
	rm -rf "$ref"; mkdir -p "$ref"
	cp "$run"/*.png "$ref"/
	git -C "$here" rev-parse HEAD > "$ref/COMMIT" 2>/dev/null
	echo "the reference is this run, at $(cat "$ref/COMMIT" 2>/dev/null)"
	echo "PASS: the reference is taken"
	exit 0
fi

if [ ! -d "$ref" ] || [ -z "$(ls "$ref"/*.png 2>/dev/null)" ]; then
	echo "no reference to compare against;" \
			"take one with $(basename "$0") --accept on a tree whose look" \
			"you have confirmed"
	echo "SKIP: there is no reference run on this machine" >&2
	exit 2
fi

python3 - "$run" "$ref" <<'PY'
import os, sys, math
from PIL import Image, ImageChops
run, ref = sys.argv[1], sys.argv[2]
# Over this a difference is a change somebody has to look at; under it is
# the noise two runs of the same code have ([CHECK_BASELINE]'s numbers)
BAR = 30.0
worst, worst_name, missing = 0.0, "", []
for name in sorted(os.listdir(ref)):
    if not name.endswith(".png"):
        continue
    a_path, b_path = os.path.join(ref, name), os.path.join(run, name)
    if not os.path.exists(b_path):
        missing.append(name)
        continue
    a, b = Image.open(a_path).convert("RGB"), Image.open(b_path).convert("RGB")
    if a.size != b.size:
        print("%-28s different size %s against %s" % (name, b.size, a.size))
        missing.append(name)
        continue
    h = ImageChops.difference(a, b).histogram()
    # RMSE over the three channels together
    total = sum(h[i] for i in range(len(h)))
    sq = sum((i % 256) ** 2 * n for i, n in enumerate(h))
    rmse = math.sqrt(sq / float(total))
    print("%-28s RMSE %7.2f%s" % (name, rmse, "   <- over the bar"
            if rmse > BAR else ""))
    if rmse > worst:
        worst, worst_name = rmse, name
if missing:
    print("FAIL: these views are missing or a different size: " +
            ", ".join(missing))
    raise SystemExit(1)
print("the worst view is %s at RMSE %.2f, and the bar is %.0f"
        % (worst_name, worst, BAR))
if worst > BAR:
    print("FAIL: the look changed -- look at " + worst_name +
            " against the reference before committing")
    raise SystemExit(1)
print("PASS: the look is the reference's, within the noise this scene has")
raise SystemExit(0)
PY
verdict_keep
verdict_exit
# vim: set noet ts=4 sw=4:
