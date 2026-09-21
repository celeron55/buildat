#!/bin/bash
# [REFVIEWS_MOD]: makes every copy the reference set's consumers want, out
# of the one file that owns each fact. Nothing it writes is committed.
#
#   builtin/luanti/test/reference_shots/build.sh <dir>
#
# writes into <dir>:
#   refviews/init.lua   the fixture as a worldmod: params, set.lua, runner.lua
#   refviews/mod.conf
#   fixture.lua         the same file by itself, for BUILDAT_LUANTI_LUA
#   luanti.conf         official Luanti's settings plus the frame and range
#   env.sh              seed, frame, range, probe crops, for the runners
#
# The params are the environment the runners already take: RANGE, HOLD,
# PROBE, PATHTRACE, KEEP, CYCLES, MODE (unlit turns official's shadows off).
set -eu
me=$(cd "$(dirname "$0")" && pwd)
dir="${1:?output directory}"
mkdir -p "$dir/refviews"

seed=$(sed -n 's/^seed = //p' "$me/map_meta.txt")
[ -n "$seed" ] || { echo "no seed in $me/map_meta.txt" >&2; exit 2; }
# The numbers set.lua owns, read with plain lua rather than sed
read -r w h range tilt < <(lua -e "dofile('$me/set.lua')" \
	-e 'print(REFSET.frame.w, REFSET.frame.h, REFSET.range, REFSET.orbit_tilt)')
RANGE="${RANGE:-$range}"
case "$RANGE" in
''|*[!0-9.]*) echo "RANGE must be a number, got: $RANGE" >&2; exit 2 ;;
esac

# The prelude: rawset rather than assignment, because the vendored builtin's
# strict.lua warns about a global nobody declared
{
	echo "rawset(_G, \"REFSHOT_SEED\", \"$seed\")"
	echo "rawset(_G, \"REFSHOT_RANGE\", $RANGE)"
	[ -n "${HOLD:-}" ] && echo "rawset(_G, \"REFSHOT_HOLD\", $HOLD)"
	[ -n "${PROBE:-}" ] && echo 'rawset(_G, "REFSHOT_PROBE", true)'
	[ -n "${PATHTRACE:-}" ] && echo 'rawset(_G, "REFSHOT_PATHTRACE", true)'
	[ -n "${KEEP:-}" ] && echo 'rawset(_G, "REFSHOT_KEEP", true)'
	[ -n "${CLOUDS:-}" ] && echo 'rawset(_G, "REFSHOT_CLOUDS", true)'
	[ -n "${CYCLES:-}" ] && echo "rawset(_G, \"REFSHOT_CYCLES\", $CYCLES)"
	# STATES="3:0545,5:0200": those states alone, in that order (a ladder)
	[ -n "${STATES:-}" ] && echo "rawset(_G, \"REFSHOT_STATES\", \"$STATES\")"
	cat "$me/set.lua" "$me/runner.lua"
} > "$dir/fixture.lua"
cp "$dir/fixture.lua" "$dir/refviews/init.lua"
cp "$me/mod.conf" "$dir/refviews/"

{
	cat "$me/luanti.conf"
	echo "screen_w = $w"
	echo "screen_h = $h"
	echo "viewing_range = $RANGE"
	# The last value of a key is the one Luanti keeps, which is why this is
	# an appended line and not a second config file
	[ "${MODE:-shadows}" = unlit ] && echo "enable_dynamic_shadows = false"
} > "$dir/luanti.conf"

{
	echo "REFSHOT_SEED=$seed"
	echo "REFSHOT_W=$w"
	echo "REFSHOT_H=$h"
	echo "REFSHOT_RANGE=$RANGE"
	echo "REFSHOT_ORBIT_TILT=$tilt"
	echo "REFSHOT_VL_VERSION=$(sed -n 's/^vl_world_initial_version = //p' "$me/map_meta.txt")"
	# A quoted heredoc, because the descriptions have apostrophes in them
	echo "REFSHOT_PROBES=\$(cat <<'REFSHOT_EOF'"
	lua -e "dofile('$me/set.lua')" -e 'for _, p in ipairs(REFSET.probes) do
		print(table.concat(p, "|")) end'
	echo "REFSHOT_EOF"
	echo ")"
} > "$dir/env.sh"
