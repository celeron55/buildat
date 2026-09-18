#!/bin/bash
# The probe table, read out of the reference shots -- what a tuning cycle
# ends with, so that "did that work" is a command rather than a memory.
# See [RENDER_MODES] and [GREEN_BIAS] in doc/plan/rendering_plan.md.
#
#   builtin/luanti/test/reference_shots/probes.sh          read what is on disk
# Every run also writes <set>/probes.png: every crop with its context and
# its box, one sheet per set, beside the pictures it was read from.
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

# [PBR_FIT] part 1: what the fit is run against, in linear light -- the
# 16-bit sRGB PNG undone to linear (magick's RGB colourspace) on both sides.
# simplified: the client's frame is read after its tonemap, not before it,
# and the tonemap is not inverted; the render's PNG has the same metering
# and no tonemap, so the ratios below carry the tonemap's own compression
# on the pbr side until part 2's last term replaces it. Each row is a
# ratio, render and pbr side by side, per crop pair:
#   contrast    sunlit face over shadowed face of one material
#   saturation  max over min channel of a coloured surface
#   sky_to_sun  a sky patch over a sunlit white
# name | picture | crop A | crop B (empty for a single crop) | what
FIT="
contrast_dirt|vp1_1300|64x10+280+530|20x20+0+310|vp1 dirt: the lit row over a shaded dirt face under open sky, the cliff top at the left edge
contrast_dirt_pit|vp1_1300|64x10+280+530|48x10+216+530|vp1 dirt: the lit row over the shaded row in the pit beside the stone block, hemmed in on three sides
incidence_dirt|vp1_1300|40x12+957+690|40x12+666+564|vp1 dirt: a sunlit side over a side facing the camera -- the face-shade table and the sun's direction
contrast_snow|vp5_1000|60x40+420+540|60x30+400+660|vp5 snow: the sunlit field over the tree's shadow
contrast_cave|vp7_1300|60x8+560+650|128x36+320+252|vp7 the sunlit floor step over the deep wall: the sun reaching in
cave_wall_near|vp7_1300|60x40+560+560|128x36+320+252|vp7 the near wall over the deep wall: the interior's falloff
cave_opening|vp7_1300|128x36+704+252|128x36+320+252|vp7 the sky through the mouth over the deep wall: the range the meter spans
cave_rim|vp7_1300|64x36+768+324|128x36+320+252|vp7 the sunlit rim over the deep wall; the sky must read above the rim
cave_outside|vp7_1300|64x36+512+432|128x36+320+252|vp7 the half-lit terrain through the mouth over the deep wall
saturation_grass|vp1_1300|40x12+666+534||vp1 grass top, lit
saturation_leaves|vp1_1300|30x20+390+160||vp1 canopy
saturation_water|vp1_1300|80x40+1120+430||vp1 the sea
saturation_flowers|vp5_1000|10x10+646+482||vp5 a rose's petals
sky_to_sun|vp5_1000|60x40+20+20|60x40+420+540|vp5 a sky patch over the sunlit snow
terrain_occlusion|vp1_0545|33x11+271+498|56x40+871+562|vp1 05:45: a grass top under the mountain over one with an open horizon, per channel
sun_glint_grass|vp1_0545|34x25+653+409|40x15+600+440|vp1 05:45: the sun's glint on a grass top over the same grass beside it, per channel
translucency_canopy|vp2_0545|38x18+955+352|19x21+887+317|vp2 05:45: a back-lit canopy face over a front-lit one
"

linear_rgb() {   # file crop -> "r g b" in linear light
	case "$1" in
		*.exr) magick "$1" -crop "$2" +repage \
			-format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]' info: 2>/dev/null ;;
		*) magick "$1" -crop "$2" +repage -colorspace RGB \
			-format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]' info: 2>/dev/null ;;
	esac
}
# The fit's ratios are read off the render's EXR where it is there: its
# metered PNG clips the sunlit snow (34 in the sky's units, exposed past
# 1), and a ratio against a clipped top is a floor. The pbr side is its
# PNG; its own clipping is what BUILDAT_LUANTI_LINEAR's frame shows.
fit_file_of() {   # set pic -> path
	local f="$shots/$1/cycles_$2_none.exr"
	case "$1" in
		pathtrace*) [ -f "$f" ] && { echo "$f"; return; } ;;
	esac
	file_of "$1" "$2"
}

echo
echo "=== the fit, in linear light: render | pbr (ratio to the render)"
echo "$FIT" | while IFS='|' read -r name pic a b why; do
	[ -n "$name" ] || continue
	line=$(printf "  %-18s" "$name")
	for s in pathtrace_r150 module_pbr_r150; do
		f=$(fit_file_of "$s" "$pic")
		[ -f "$f" ] || { line="$line  (no $s)"; continue; }
		ra=$(linear_rgb "$f" "$a")
		if [ -n "$b" ] && { [ "$name" = terrain_occlusion ] || [ "$name" = sun_glint_grass ]; }; then
			rb=$(linear_rgb "$f" "$b")
			v=$(echo "$ra $rb" | awk '{printf "%.2f/%.2f/%.2f", $1/($4+1e-9), $2/($5+1e-9), $3/($6+1e-9)}')
		elif [ -n "$b" ]; then
			rb=$(linear_rgb "$f" "$b")
			v=$(echo "$ra $rb" | awk '{la=0.2126*$1+0.7152*$2+0.0722*$3; lb=0.2126*$4+0.7152*$5+0.0722*$6; printf "%.3f", la/(lb+1e-9)}')
		else
			v=$(echo "$ra" | awk '{mx=$1; mn=$1; for(i=2;i<=3;i++){if($i>mx)mx=$i; if($i<mn)mn=$i}; printf "%.3f", mx/(mn+1e-9)}')
		fi
		line="$line  $v"
	done
	echo "$line" | awk '{ if (NF >= 3 && $2+0 > 0) printf "%s  (%.2f)  ", $0, $3/$2; else printf "%s  ", $0; }'
	echo "-- $why"
done

# And the sky as a surface of its own (user, 2026-09-18): the render's
# Nishita sky is the reference for it, and the fixture has taken the
# clouds, the moon disc and the stars out of every client's. Absolute
# linear values, render against pbr, per patch:
#   zenith  the top of the frame, straight up as the view allows
#   horizon a patch near the horizon away from the sun
#   glow    a patch in the sun's own glow
#   night   a patch away from where the moon would be
SKY="
sky_zenith_1300|vp1_1300|60x40+900+30|vp1 near the top, 13:00
sky_horizon_1300|vp1_1300|60x20+1100+225|vp1 just over the sea, away from the sun
sky_glow_0545|vp2_0545|60x40+600+30|vp2 the dawn glow, 05:45, mid-gradient toward the disc
sky_horizon_0545|vp1_0545|60x20+1100+225|vp1 the horizon opposite the dawn
sky_night_0200|vp5_0200|60x40+20+20|vp5 away from the moon, 02:00
"
# Water's reflection at a grazing angle (user, 2026-09-18): vp3 at 05:45,
# the sun behind the camera, the far water near the horizon over the near
# water below it, per channel -- the Fresnel and the reflected sky in one
# number, which is the water's roughness and spec and the cube it reflects.
WATER="
water_far|vp3_0545|120x15+40+355|vp3 the water near the horizon, 05:45
water_near|vp3_0545|120x20+40+550|vp3 the near water, 05:45
"
echo
echo "=== the sky, in linear light: render | pbr (ratio to the render)"
echo "$SKY" | while IFS='|' read -r name pic crop why; do
	[ -n "$name" ] || continue
	line=$(printf "  %-18s" "$name")
	for s in pathtrace_r150 module_pbr_r150; do
		f=$(file_of "$s" "$pic")
		[ -f "$f" ] || { line="$line  (no $s)"; continue; }
		v=$(linear_rgb "$f" "$crop" | awk '{printf "%.4f", 0.2126*$1+0.7152*$2+0.0722*$3}')
		line="$line  $v"
	done
	echo "$line" | awk '{ if (NF >= 3 && $2+0 > 0) printf "%s  (%.2f)  ", $0, $3/$2; else printf "%s  ", $0; }'
	echo "-- $why"
done



# The low sun's colour (user, 2026-09-18): a dirt face lit at 05:45 and at
# 13:00, its R/B at dawn over its R/B at noon -- the sun's colour with the
# material controlled for, which is the number [PBR_FIT] term 3 is fitted
# to. The face is vp1's foreground block, the one dirt lit at both hours
# under the tilted sun (vp2's terrace sides and vp3's mountain are in
# shadow at noon). Read off the PNGs on both sides: a hue ratio survives
# the exposure.
DAWN="
dawn_sun_dirt|vp1|40x10+2+608|vp1 the foreground block's lit face, 05:45 over 13:00
"
echo
echo "=== water's reflection, per channel: far over near, render | pbr"
r=""; p=""
for s in pathtrace_r150 module_pbr_r150; do
	f=$(file_of "$s" "vp3_0545")
	[ -f "$f" ] || { echo "  (no $s)"; continue; }
	far=$(linear_rgb "$f" "120x15+40+355"); near=$(linear_rgb "$f" "120x30+80+490")
	echo "$far $near" | awk -v s="$s" '{printf "  %-18s far %.3f %.3f %.3f  near %.3f %.3f %.3f  far/near %.2f %.2f %.2f\n", s, $1,$2,$3, $4,$5,$6, $1/($4+1e-9), $2/($5+1e-9), $3/($6+1e-9)}'
done

# The crop sheet, on every run: every crop cut with three times its context
# and its box drawn, one sheet per set as probes.png inside the set's own
# directory, so it is dated with the pictures it was read from and an old
# set can be re-seen with its crops (user, 2026-09-18). A crop enters a
# table only after someone has looked at its cell: typed coordinates are a
# guess until seen.
show_cell() {   # out name file crop -> a cell png
	local geom="$4"
	local w=${geom%%x*}; local rest=${geom#*x}; local h=${rest%%+*}
	rest=${rest#*+}; local x=${rest%%+*}; local y=${rest#*+}
	local cx=$((x - w)); local cy=$((y - h)); [ $cx -lt 0 ] && cx=0; [ $cy -lt 0 ] && cy=0
	magick "$3" -crop "$((w * 3))x$((h * 3))+$cx+$cy" +repage \
		-fill none -stroke red -strokewidth 1 \
		-draw "rectangle $((x - cx)),$((y - cy)) $((x - cx + w - 1)),$((y - cy + h - 1))" \
		-scale 300% -gravity north -background black -fill white -pointsize 12 \
		-splice 0x14 -annotate +0+1 "$2" "$1/$2.png" 2>/dev/null
}
for s in pathtrace_r150 module_pbr_r150; do
	[ -d "$shots/$s" ] || continue
	cells=$(mktemp -d)
	{ echo "$FIT"; echo "$SKY"; echo "$WATER"; echo "$DAWN"; } |
	while IFS='|' read -r name pic a b why; do
		[ -n "$name" ] || continue
		case "$name" in dawn_*) pic="${pic}_0545" ;; esac
		f=$(file_of "$s" "$pic"); [ -f "$f" ] || continue
		show_cell "$cells" "${name}_A" "$f" "$a"
		case "$b" in *x*) show_cell "$cells" "${name}_B" "$f" "$b" ;; esac
	done
	magick montage "$cells"/*.png -tile 4x -geometry +4+4 -background gray20 \
		"$shots/$s/probes.png" 2>/dev/null && echo "crop sheet: $shots/$s/probes.png"
	rm -rf "$cells"
done

echo
echo "=== the low sun: R/B at 05:45 over R/B at 13:00, render | pbr (ratio to the render)"
echo "$DAWN" | while IFS='|' read -r name vp crop why; do
	[ -n "$name" ] || continue
	line=$(printf "  %-18s" "$name")
	for s in pathtrace_r150 module_pbr_r150; do
		d=$(file_of "$s" "${vp}_0545"); n=$(file_of "$s" "${vp}_1300")
		[ -f "$d" ] && [ -f "$n" ] || { line="$line  (no $s)"; continue; }
		v=$(echo "$(linear_rgb "$d" "$crop") $(linear_rgb "$n" "$crop")" |
			awk '{printf "%.3f", ($1/($3+1e-9)) / ($4/($6+1e-9))}')
		line="$line  $v"
	done
	echo "$line" | awk '{ if (NF >= 3 && $2+0 > 0) printf "%s  (%.2f)  ", $0, $3/$2; else printf "%s  ", $0; }'
	echo "-- $why"
done
