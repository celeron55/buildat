#!/bin/bash
# The probe table, read out of the reference shots -- what a tuning cycle
# ends with, so that "did that work" is a command rather than a memory.
# See [RENDER_MODES] and [GREEN_BIAS] in doc/plan/rendering_plan.md.
#
#   builtin/luanti/test/reference_shots/probes.sh          read what is on disk
#   builtin/luanti/test/reference_shots/probes.sh --shoot  re-take all three
#                                                          module modes, then read
#
# Each mode is compared against its own reference -- shadows against
# official_shadows, unlit against official_unlit, pbr against the
# path-traced set. The crops are set.lua's, read through build.sh. **Hue is what this judges**: the ratio
# between channels on a surface, which is [GREEN_BIAS]'s subject. How much
# brighter than Luanti a mode is belongs to [TOO_BRIGHT] and is printed
# without an opinion.
set -u
here=$(cd "$(dirname "$0")/../../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
shots="${REFSHOT_SHOTS_DIR:-$here/local/reference_shots}"
built=$(mktemp -d /tmp/refshots_build.XXXXXX)
"$me/build.sh" "$built" || exit 2
. "$built/env.sh"
seed=$REFSHOT_SEED

if [ "${1:-}" = "--shoot" ]; then
	bash "$me/shoot_buildat_server.sh" unlit shadows pbr || exit 1
fi

# name | picture | crop | what it is for
PROBES=$REFSHOT_PROBES

# mode -> the set it must match, at the same range: a set's _r<RANGE>
# postfix carries over, so module_shadows_r150 is read against
# official_r150 and never against a set of another range. pbr's is the
# path-traced set, textured since 2026-09-17 ([PATH_TRACE_TEX]).
target_of() {
	local r=${1##*_r}
	case "$1" in
		*_shadows_r*) echo "official_shadows_r$r" ;;
		*_unlit_r*)   echo "official_unlit_r$r" ;;
		*_pbr_r*)     echo "pathtrace_r$r" ;;
		*)            echo "" ;;
	esac
}

# The picture a set has of a probe. The path-traced set names its renders
# without the seed -- cycles_vp6_1300_none.png beside the dump -- and is a
# reference like official ([PATH_TRACE_REF]).
file_of() {   # set pic -> path
	case "$1" in
		pathtrace*) echo "$shots/$1/cycles_$2_none.png" ;;
		*) echo "$shots/$1/${seed}_$2_none.png" ;;
	esac
}

read_probe() {   # file crop -> "r g b"
	magick "$1" -crop "$2" +repage -format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]' info: 2>/dev/null
}

# Anything shot before the newest source file cannot be measuring it
newest_src=$(find "$here/builtin" "$here/games" "$here/extensions" \
		-name '*.lua' -o -name '*.cpp' -o -name '*.h' -o -name '*.glsl' \
		2>/dev/null | xargs -r stat -c %Y 2>/dev/null | sort -rn | head -1)

sets=""
for d in "$shots"/*/; do sets="$sets $(basename "$d")"; done

echo "=== staleness ==="
for s in $sets; do
	newest=$(ls -t "$shots/$s" 2>/dev/null | head -1)
	[ -n "$newest" ] || continue
	t=$(stat -c %Y "$shots/$s/$newest")
	case "$s" in official*|pathtrace*) note="(reference, no need to re-take)" ;; *)
		if [ "$t" -lt "${newest_src:-0}" ]; then note="** STALE: older than the source **"
		else note="current" ; fi ;;
	esac
	printf "  %-24s %s  %s\n" "$s" "$(date -d @"$t" +%H:%M)" "$note"
done

echo "$PROBES" | while IFS='|' read -r name pic crop why; do
	[ -n "$name" ] || continue
	echo
	echo "=== $name -- $why"
	for s in $sets; do
		f=$(file_of "$s" "$pic")
		[ -f "$f" ] || continue
		rgb=$(read_probe "$f" "$crop")
		[ -n "$rgb" ] || continue
		tgt=$(target_of "$s")
		line=$(echo "$rgb" | awk -v s="$s" '{printf "  %-24s %3d,%3d,%3d  B/R %.2f  mean %.3f",
				s, $1*255, $2*255, $3*255, $3/($1+1e-9), ($1+$2+$3)/3}')
		if [ -n "$tgt" ] && [ -f "$(file_of "$tgt" "$pic")" ]; then
			t_rgb=$(read_probe "$(file_of "$tgt" "$pic")" "$crop")
			flag=$(echo "$rgb $t_rgb" | awk -v n="$name" '{
				br=$3/($1+1e-9); tbr=$6/($4+1e-9); d=br-tbr; if(d<0)d=-d;
				lim=(n=="stone")?0.03:0.05;
				printf "  vs %s B/R %.2f  %s", "target", tbr,
						(d>lim ? (n=="stone" ? "** CONTROL MOVED **" : "** HUE OFF **") : "ok")}')
			line="$line$flag"
		fi
		echo "$line"
	done
done
echo
echo "Hue is the verdict; mean is for TOO_BRIGHT and carries no pass mark."
