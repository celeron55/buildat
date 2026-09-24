#!/bin/bash
# [LAUNCH_WORLD]'s floor, an options round: the same standing frame with
# the floor's light squares at four values and two finishes, into
# local/options_for_LAUNCH_WORLD_floor/.
#
#   extensions/launch_world/floor_sheet.sh
#
# **Why the floor and not the lighting** (2026-09-24): reading the look
# against the reference frame at the new standing place, the median sits
# under the reference's and the 90th and the white share sit over it,
# and both are the floor -- its light squares are the brightest surface
# in the room and they clip near the camera. The sources are where they
# should be.
#
# The knobs are BUILDAT_LAUNCH_FLOOR_VALUE (the light square's value)
# and BUILDAT_LAUNCH_FLOOR_GLOSS (its roughness; lower is glossier), so
# trying one is a flag rather than an edit.
#
# Taken on an empty user path, since a sphere the player parked in front
# of the camera is worth several points of every number here.
#
# No tier line: this makes a picture for a person to choose from, and
# decides nothing itself.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD_floor"; mkdir -p "$out"
rm -f "$out"/*.png
mkdir -p "$out/emptyuser"
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
{ echo "delay 5000"; echo "screenshot $out/RUN.png"; echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
# **The room as the reference frame has it** (user, 2026-09-24): no
# launch actions, no saves, no servers and no save read, so the wall is
# lit by the light from above and the orbs in their pockets rather than
# by a game somebody left standing on the floor.
#
# **And the probe that lets the finish matter**: with one mip level a
# rough surface reflects as sharply as a mirror, so the gloss knob moved
# the picture six tenths of a level and the round could not be judged
# (user, 2026-09-24). An eight-bit cube takes a mip chain -- the float16
# one blacks every primitive that reflects it, its own shader having no
# guard against what the levels hold -- so the finish is shot on that
# one. What it costs is the top of a source inside a reflection, which
# is [PBR_HDR]'s own trade and is the user's to make.
bare="BUILDAT_LAUNCH_BARE=1 BUILDAT_LAUNCH_PROBE8=1 BUILDAT_LAUNCH_PROBEMIPS=1"
for v in 1.00 0.80 0.60 0.45; do
	for g in 0.07 0.40; do
		name="v${v}_g${g}"
		sed "s#RUN#$name#" "$out/cmds.txt" > "$out/cmds_$name.txt"
		env $bare BUILDAT_LAUNCH_FLOOR_VALUE=$v BUILDAT_LAUNCH_FLOOR_GLOSS=$g \
			bin/buildat -m launch_world -D "$out/emptyuser" \
			-w 1280x720 -l 3 -c @"$out/cmds_$name.txt" > /dev/null 2>&1
	done
done
python3 - "$out" "$here/local/launch_world_reference/images/fps-stood.png" <<'PY'
import sys, os
from PIL import Image

out, ref = sys.argv[1], sys.argv[2]
HUD = 70

def read(path):
	im = Image.open(path).convert("L")
	w, h = im.size
	d = sorted(im.crop((0, 0, w, h - HUD)).getdata())
	n = len(d)
	return (sum(d) / float(n), d[n // 2], d[int(n * 0.90)],
			100.0 * sum(1 for v in d if v >= 254) / n)

rows = []
print("%-14s %6s %6s %6s %7s" % ("floor", "mean", "med", "90th", "white%"))
for v in ("1.00", "0.80", "0.60", "0.45"):
	for g in ("0.07", "0.40"):
		p = "%s/v%s_g%s.png" % (out, v, g)
		if not os.path.exists(p):
			continue
		rows.append((v, g, p))
		print("%-14s %6.1f %6d %6d %7.2f" % ("value %s gloss %s" % (v, g),
				*read(p)))
if os.path.exists(ref):
	print("%-14s %6.1f %6d %6d %7.2f" % ("(reference)", *read(ref)))
if rows:
	from PIL import ImageDraw, ImageFont
	shots = []
	for v, g, p in rows:
		im = Image.open(p).convert("RGB")
		# **Say which candidate each tile is** ([USER_INPUT]: candidates
		# are named so the answer can be a name). The room's own label in
		# the corner is the palette preset, which is not what varies here.
		d = ImageDraw.Draw(im)
		label = "value %s   gloss %s" % (v, g)
		try:
			font = ImageFont.truetype(
					"/usr/share/fonts/liberation-mono/LiberationMono-Bold.ttf", 34)
		except Exception:
			font = ImageFont.load_default()
		d.rectangle((0, 0, 470, 54), fill=(0, 0, 0))
		d.text((14, 8), label, fill=(255, 220, 120), font=font)
		shots.append(im)
	w, h = shots[0].size
	cols, n = 2, len(shots)
	sheet = Image.new("RGB", (w * cols + 8, ((n + 1) // cols) * (h + 8)),
			(0, 0, 0))
	for i, im in enumerate(shots):
		sheet.paste(im, ((i % cols) * (w + 8), (i // cols) * (h + 8)))
	sheet = sheet.resize((sheet.size[0] // 3, sheet.size[1] // 3),
			Image.LANCZOS)
	sheet.save("%s/sheet.png" % out)
	print("the sheet: %s/sheet.png -- every tile says its own two "
			"numbers, the left column glossy and the right matt" % out)
PY
