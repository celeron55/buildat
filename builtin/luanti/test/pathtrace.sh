#!/bin/bash
# [PATH_TRACE_REF]: dump the client's meshes at each viewpoint, render in Cycles.
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
me="$here/builtin/luanti/test"
RANGE="${RANGE:-150}"
out="${BUILDAT_PATHTRACE_OUT:-$here/local/reference_shots/pathtrace_r$RANGE}"
mkdir -p "$out"

# 150 is the set: viewpoint 5 draws nothing at 50. RANGE=50 for iterating.
# The shooter's exit is its picture checks' verdict; the dumps are there
# either way and the render is what this script is for
PATHTRACE=1 RANGE="$RANGE" MESH_DIR="$out" OUT_DIR="$out/module_shots" \
	bash "$me/reference_shots_module.sh" shadows || echo "shooter exit $?" >&2

export BUILDAT_PATHTRACE_OUT="$out"
blender -b -P "$me/pathtrace_render.py" || {
	echo "blender render failed" >&2
	exit 1
}
echo "renders in $out"
