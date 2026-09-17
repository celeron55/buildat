#!/bin/bash
# [PATH_TRACE_REF]: dump the client's meshes at each viewpoint, render in Cycles.
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
me="$here/builtin/luanti/test"
out="${BUILDAT_PATHTRACE_OUT:-$here/local/reference_shots/pathtrace}"
mkdir -p "$out"

PATHTRACE=1 MESH_DIR="$out" OUT_DIR="$out/module_shots" \
	bash "$me/reference_shots_module.sh" shadows

export BUILDAT_PATHTRACE_OUT="$out"
blender -b -P "$me/pathtrace_render.py" || {
	echo "blender render failed" >&2
	exit 1
}
echo "renders in $out"
