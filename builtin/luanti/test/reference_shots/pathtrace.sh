#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [PATH_TRACE_REF]: dump the client's meshes at each viewpoint, render in Cycles.
set -eu
here=$(cd "$(dirname "$0")/../../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
shots_root="${REFSHOT_SHOTS_DIR:-$here/local/reference_shots}"
# The runner names the dump set pathtrace_r<RANGE> under the same root; the
# pictures it takes on the way are module_shadows_r<RANGE>'s, warm
RANGE="${RANGE:-$(lua -e "dofile('$me/set.lua')" -e 'print(REFSET.range)')}"
out="$shots_root/pathtrace_r$RANGE"
mkdir -p "$out"

# 150 is the set: viewpoint 5 draws nothing at 50. RANGE=50 for iterating.
# The shooter's exit is its picture checks' verdict; the dumps are there
# either way and the render is what this script is for
PATHTRACE=1 RANGE="$RANGE" \
	bash "$me/shoot_buildat_server.sh" shadows || echo "shooter exit $?" >&2

export BUILDAT_PATHTRACE_OUT="$out"
blender -b -P "$me/pathtrace_render.py" || {
	echo "blender render failed" >&2
	exit 1
}
echo "renders in $out"
