#!/bin/bash
# The probe table, read out of the reference shots -- what a tuning cycle
# ends with, so that "did that work" is a command rather than a memory.
# See [RENDER_MODES] and [GREEN_BIAS] in doc/plan/rendering_plan.md.
#
#   builtin/luanti/test/reference_probes.sh          read what is on disk
#   builtin/luanti/test/reference_probes.sh --shoot  re-take all three module
#                                                    modes first, then read
#
# Each mode is compared against its own reference -- shadows against
# official, unlit against official_noshadow, pbr against neither, being the
# mode that is allowed to differ. **Hue is what this judges**: the ratio
# between channels on a surface, which is [GREEN_BIAS]'s subject. How much
# brighter than Luanti a mode is belongs to [TOO_BRIGHT] and is printed
# without an opinion.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
shots="${SHOTS_DIR:-$here/local/reference_shots}"
seed=2845188330406634615

if [ "${1:-}" = "--shoot" ]; then
	for m in unlit shadows pbr; do
		bash "$me/reference_shots_module.sh" "$m" || exit 1
	done
fi

# name | picture | crop | what it is for
PROBES="
grass|vp4_1300|40x30+280+545|colourised, top face: the one GREEN_BIAS owns
grasstop|vp4_1300|200x30+500+560|the same, over the whole field
grassside|vp4_1300|60x40+1100+500|the same node's SIDE: says whether the fault is the face or the palette
stone|vp4_1300|30x20+625+320|CONTROL, no palette: must not move
dirt|vp4_1300|30x20+45+420|colourised, weaker
cave|vp4_1300|60x40+610+360|the floor, TOO_BRIGHT's black caves
wall|vp4_1300|30x40+880+300|shaded: what tells the modes apart
snow|vp5_1000|60x40+420+540|no colour of its own to hide a cast
leaf|vp5_1000|50x30+700+560|colourised, against snow
"

# mode -> the set it must match; pbr matches nothing on purpose
target_of() {
	case "$1" in
		*_shadows) echo official ;;
		*_unlit)   echo official_noshadow ;;
		*)         echo "" ;;
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
	case "$s" in official*) note="(reference, no need to re-take)" ;; *)
		if [ "$t" -lt "${newest_src:-0}" ]; then note="** STALE: older than the source **"
		else note="current" ; fi ;;
	esac
	printf "  %-18s %s  %s\n" "$s" "$(date -d @"$t" +%H:%M)" "$note"
done

echo "$PROBES" | while IFS='|' read -r name pic crop why; do
	[ -n "$name" ] || continue
	echo
	echo "=== $name -- $why"
	for s in $sets; do
		f="$shots/$s/${seed}_${pic}_none.png"
		[ -f "$f" ] || continue
		rgb=$(read_probe "$f" "$crop")
		[ -n "$rgb" ] || continue
		tgt=$(target_of "$s")
		line=$(echo "$rgb" | awk -v s="$s" '{printf "  %-18s %3d,%3d,%3d  B/R %.2f  mean %.3f",
				s, $1*255, $2*255, $3*255, $3/($1+1e-9), ($1+$2+$3)/3}')
		if [ -n "$tgt" ] && [ -f "$shots/$tgt/${seed}_${pic}_none.png" ]; then
			t_rgb=$(read_probe "$shots/$tgt/${seed}_${pic}_none.png" "$crop")
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
