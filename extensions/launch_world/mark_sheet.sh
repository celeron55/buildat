#!/bin/bash
# [LAUNCH_WORLD]'s mark, the options round: the same orbs from the same
# place, both ways, into local/options_for_LAUNCH_WORLD_mark/.
#
#   extensions/launch_world/mark_sheet.sh
#
#   A  the icon in full colour in the diffuse, padded so the whole of it
#      shows -- a coloured picture in a glass marble
#   B  the same logo as one bit in the roughness -- an etch, the surface
#      taking the light differently where the mark is
#
# The glowing orbs are one way in both sheets: nothing greyer than about
# four per cent survives an emissive of 26, so their mark is one bit
# whatever is picked. What the sheets are for is **the white and the
# chrome ones**.
#
# No tier line: this makes a picture for a person to choose from, and
# decides nothing itself.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD_mark"; mkdir -p "$out"
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
# The standing place first, then walked up to the floor's spheres: a
# mark has to read from both, and the second is where a player looks at
# one on purpose
{ echo "delay 5000"
	echo "screenshot $out/RUN-standing.png"
	echo "delay 400"
	echo "keydown W"
	echo "delay 1500"
	echo "keyup W"
	echo "look 150 -6"
	echo "delay 900"
	echo "screenshot $out/RUN-close.png"
	echo "delay 400"
	echo "quit"; } > "$out/cmds.txt"
for opt in A B; do
	sed "s/RUN/$opt/g" "$out/cmds.txt" > "$out/cmds_$opt.txt"
	BUILDAT_LAUNCH_MARK=$opt bin/buildat -m launch_world -D ../user \
		-w 1280x720 -l 3 -c @"$out/cmds_$opt.txt" 2>&1 |
		sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli_$opt.log"
done
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
names = ["standing", "close"]
shots = [[Image.open("%s/%s-%s.png" % (out, o, n)).convert("RGB")
		for n in names] for o in "AB"]
w, h = shots[0][0].size
sheet = Image.new("RGB", (w, h * 2 + 8), (0, 0, 0))
for i, o in enumerate("AB"):
	sheet.paste(shots[i][1], (0, i * (h + 8)))
sheet = sheet.resize((w // 2, (h * 2 + 8) // 2), Image.LANCZOS)
sheet.save("%s/sheet_close.png" % out)
print("the sheet: %s/sheet_close.png, A above B" % out)
PY
echo "and the single shots beside it, A-standing.png and the rest"
