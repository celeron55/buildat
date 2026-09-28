#!/bin/bash
# tier: full
# cost: 120s (this desk, 2026-09-28)
# covers: extensions/luanti_client/res/*.glsl builtin/voxel_shading/client_lua/** games/vanilla/main/client_lua/init.lua
#
# **Nothing in this tree could fail on a change to the shader the Luanti
# clients draw with** (user, 2026-09-25; [UNDERGROUND_LIGHT] (3)).
# games/voxel_lighting/check.sh guards its own game's look and reads
# builtin/voxel_shading's shader; `extensions/luanti_client/res/
# PBRVoxel.glsl` -- the one games/vanilla actually draws with -- had no
# runner at all, and the light terms, the gray ramp and the zone the
# ambient comes from were all changed in a week with nothing able to go
# red.
#
# **Three views at 13:00 against the stored set**, by RMSE, the same
# shape games/voxel_lighting/check.sh uses: vp1 (the open surface the
# ambient is fitted to), vp8 (a lamp in a cave) and vp10 (a chamber with
# no sky of its own). One mode, three states: two minutes rather than
# [PROBE_CYCLE]'s ten.
#
# The reference is local/reference_shots/module_pbr_r150, which
# reference_shots/shoot_buildat_server.sh writes; this shoots into a
# scratch directory of its own and never touches it.
#
#   builtin/luanti/test/pbr_shader.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me="$here/builtin/luanti/test/reference_shots"
ref="$here/local/reference_shots/module_pbr_r150"
out="$here/local/pbr_shader"; mkdir -p "$out"
. "$here/builtin/luanti/test/lib.sh" 2>/dev/null || true
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 77
fi
if [ ! -d "$ref" ]; then
	echo "SKIP: no reference set at $ref -- take one with" \
			"reference_shots/shoot_buildat_server.sh pbr" >&2
	exit 77
fi
built=$(mktemp -d /tmp/pbr_shader_build.XXXXXX)
"$me/build.sh" "$built" >/dev/null || { echo "FAIL: build.sh"; exit 1; }
. "$built/env.sh"
rm -rf "$out/shot"; mkdir -p "$out/shot"
REFSHOT_SHOTS_DIR="$out/shot" STATES="1:1300 8:1300 10:1300" \
	timeout 900 bash "$me/shoot_buildat_server.sh" pbr > "$out/shoot.log" 2>&1
shot="$out/shot/module_pbr_r${REFSHOT_RANGE}"
# **The bar is measured, not picked** ([CHECK_BASELINE]): two shoots of
# one unchanged tree differ by the sky-visibility sweep, whose rays are
# not the same rays twice. Read on this desk 2026-09-28 at 1.4, 0.6 and
# 0.5 for the three views; twenty is far above that and far below a real
# change (voxel_lighting measures those at 72 to 868).
bar=20
python3 - "$shot" "$ref" "$REFSHOT_SEED" "$bar" <<'PY' | tee "$out/read.txt"
import sys, os, math
sys.path.insert(0, "")
from PIL import Image, ImageChops
shot, ref, seed, bar = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
bad = 0
for vp in ("vp1", "vp8", "vp10"):
    name = "%s_%s_1300_none.png" % (seed, vp)
    a, b = os.path.join(shot, name), os.path.join(ref, name)
    if not (os.path.exists(a) and os.path.exists(b)):
        print("%-6s missing (%s)" % (vp, "shot" if not os.path.exists(a) else "reference"))
        bad += 1
        continue
    ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if ia.size != ib.size:
        print("%-6s size differs" % vp); bad += 1; continue
    px = list(ImageChops.difference(ia, ib).getdata())
    rmse = math.sqrt(sum(r*r+g*g+bb*bb for r, g, bb in px)/(len(px)*3))
    print("%-6s RMSE %7.2f  (bar %.1f)%s" % (vp, rmse, bar,
            "  OVER" if rmse > bar else ""))
    if rmse > bar:
        bad += 1
print("BAD=%d" % bad)
PY
bad=$(sed -n 's/^BAD=//p' "$out/read.txt")
if [ "${bad:-1}" != "0" ]; then
	echo "FAIL: the Luanti clients' pbr shader draws a different picture" \
			"than the stored set; if the change was meant, re-take the set" \
			"with reference_shots/shoot_buildat_server.sh pbr"
	exit 1
fi
echo "PASS: vp1, vp8 and vp10 at 13:00 are the stored set's, within the" \
		"noise this scene has"
exit 0
