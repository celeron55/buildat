#!/bin/bash
# extensions/launch_world: [LAUNCH_WORLD]'s own check. One picture of each
# of the four lighting presets from the one viewpoint, into
# local/options_for_LAUNCH_WORLD/, which is what settles the palette, and
# then the room's features one at a time.
#
# **No server.** The room is an extension: it is the launcher, and
# starting a game is `ctx.launch` on the trusted side. So this runs the
# client alone with -m launch_world.
#
#   extensions/launch_world/check.sh
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD"; mkdir -p "$out"
# **Last run's pictures are not this run's.** The client crashed halfway
# through a run and every check still reported PASS, off the shots left
# behind by the run before (2026-09-23).
rm -f "$out"/*.png
# The room's description asserts itself first: it is a function of
# (x, y, z), and a wall with no slabs in it fails here rather than in a
# picture nobody reads
lua "$here/extensions/launch_world/room.lua" || exit 1
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "a buildat client is already running" >&2; exit 2
fi
names="cold_in_warm_out warm_in_cold_out all_cold wrong"
{ echo "delay 5000"
	# **It starts in FPS mode**, so the walking is checked first and then
	# Tab goes to menu mode, where the prompt and the digits live. A held
	# key needs keydown/delay/keyup; keypress is one frame and moves
	# nothing.
	echo "screenshot $out/fps-stood.png"
	echo "delay 400"
	echo "keydown W"
	echo "delay 1400"
	echo "keyup W"
	echo "delay 600"
	echo "screenshot $out/fps-walked.png"
	echo "delay 400"
	echo "keypress Tab"
	echo "delay 600"
	# Back to the standing place, so every frame below has the same
	# viewpoint as the one Escape returns to
	echo "keypress Escape"
	echo "delay 1800"
	# **The room is never static** -- the era reference's own rule, and
	# the reason every comparison below freezes it first. Two frames a
	# second apart, then F7.
	echo "screenshot $out/drift-a.png"
	echo "delay 1200"
	echo "screenshot $out/drift-b.png"
	echo "delay 400"
	echo "keypress F7"
	echo "delay 800"
	n=1
	for name in $names; do
		echo "keypress F$n"
		echo "delay 800"
		echo "screenshot $out/$n-$name.png"
		n=$((n + 1))
	done
	# The dissolve: the bay of the orb being pointed at opens, and closes
	# again. What is checked is that the wall moves and comes back --
	# states being configurations of one scene, the closed picture has to
	# be the picture it was.
	echo "keypress F1"
	echo "delay 800"
	echo "screenshot $out/dissolve-closed.png"
	# A screenshot lands a frame or two after the command, so the next
	# key has to wait or it is in the picture (2026-09-23)
	echo "delay 600"
	echo "keypress Return"
	echo "delay 1600"
	echo "screenshot $out/dissolve-open.png"
	echo "delay 600"
	echo "keypress Backspace"
	# The cubes land in 0.9 s, but the voxels coming back have to be
	# remeshed and relit before the picture is the picture it was
	echo "delay 5000"
	echo "screenshot $out/dissolve-closed-again.png"
	echo "delay 600"
	# The typing path: three letters fuzzy-match a name, Enter launches
	# it and the camera flies in; Escape brings the room back
	echo "keypress U"
	echo "keypress N"
	echo "keypress D"
	echo "delay 600"
	echo "screenshot $out/typed.png"
	echo "delay 400"
	echo "keypress Return"
	echo "delay 2200"
	echo "screenshot $out/launched.png"
	echo "delay 400"
	echo "keypress Escape"
	echo "delay 2600"
	echo "screenshot $out/back-home.png"
	echo "delay 600"
	# The terminal: found by name like anything else, the camera square
	# on to it and the panel flat over it
	echo "keypress S"
	echo "keypress E"
	echo "keypress T"
	echo "delay 400"
	echo "keypress Return"
	echo "delay 2400"
	echo "screenshot $out/terminal.png"
	echo "delay 400"
	echo "keypress Escape"
	echo "delay 2600"
	echo "delay 600"
	# The ornament, stripped: the friezes go plain and the frame has to
	# change. The generator's own check passed for a day while nothing in
	# the room wore what it made.
	echo "keypress F6"
	echo "delay 900"
	echo "screenshot $out/no-ornament.png"
	echo "delay 400"
	echo "keypress F6"
	echo "delay 900"
	# And the first preset again with the reflection probe taken off the
	# zone, which is what says the probe reaches the metals
	echo "keypress F1"
	echo "delay 800"
	echo "keypress F5"
	echo "delay 800"
	echo "screenshot $out/1-cold_in_warm_out-noprobe.png"
	# The attract mode: left alone the room shows itself off. The drift
	# is unfrozen for it and BUILDAT_LAUNCH_ATTRACT makes the wait short.
	echo "keypress F7"
	echo "delay 600"
	echo "screenshot $out/attract-home.png"
	echo "delay 400"
	echo "keypress F8"
	echo "delay 5000"
	echo "screenshot $out/attract-away.png"
	echo "delay 400"
	echo "keypress Space"
	echo "delay 2400"
	echo "screenshot $out/attract-back.png"
	echo "delay 500"
	# **The pause dialog**, which is the room's own way out of the
	# program: Tab back to FPS, where Escape has nothing to cancel, and
	# it comes up; Escape again takes it away
	echo "keypress Tab"
	echo "delay 600"
	echo "keypress Escape"
	echo "delay 700"
	echo "screenshot $out/paused.png"
	echo "delay 400"
	echo "keypress Escape"
	echo "delay 700"
	echo "screenshot $out/unpaused.png"
	echo "delay 400"
	echo "quit"; } > "$out/cmds.txt"
bin/buildat -m launch_world -D ../user -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
# And the client has to have got to the end of the sequence
if grep -aq "Crash: SIG" "$out/cli.log"; then
	echo "FAIL: the client crashed --" \
			"$(grep -a "Crash: SIG" "$out/cli.log" | head -1)"
	exit 1
fi
grep -aE "palette preset|ornament ok|synth ok" "$out/cli.log" |
	sed 's/.*launch_w[a-z]*: //'
# The ornament generator asserts its own patterns as it builds them
# (ornament.lua's self_check); a generator that quietly returned a flat
# field would pass an eye on a dark slab and fail there
# The room is described in room.lua and nowhere else now, so what the
# room says out loud is checked against itself rather than against a
# second copy on a server
grep -a "launch_w.*: room " "$out/cli.log" | head -1 | sed 's/.*: //'
grep -a "launch_w.*: bays " "$out/cli.log" | head -1 | sed 's/.*: //'
# **The room holds what the tree offers**, not a list written here: the
# pockets are the launch grid's games and the floor is everything else
# that launches. A room that found nothing would still draw, and would
# still pass every picture check above.
contents=$(grep -a "launch_w.*: contents: " "$out/cli.log" | head -1 |
	sed 's/.*contents: //')
echo "contents: ${contents:-(none)}"
games=$(echo "$contents" | sed -n 's/^\([0-9]*\) games.*/\1/p')
floor=$(echo "$contents" | sed -n 's/.* \([0-9]*\) other.*/\1/p')
if [ "${games:-0}" -lt 1 ] || [ "${floor:-0}" -lt 1 ]; then
	echo "FAIL: the room found no launch actions in the tree"
	exit 1
fi
# The orb being pointed at says its name; it was drawn inside the stone
# above its niche for a while, which is the kind of thing a log line
# does not catch and a shot does
if ! grep -aq "pointing at orb" "$out/cli.log"; then
	echo "FAIL: no orb is ever pointed at"
	exit 1
fi
grep -a "pointing at orb" "$out/cli.log" | head -1 | sed 's/.*launch_w[a-z]*: //'
for what in "ornament" "synth"; do
	if ! grep -aq "$what ok" "$out/cli.log"; then
		echo "FAIL: the $what did not pass its own check"
		grep -aiE "error|assert" "$out/cli.log" | tail -3
		exit 1
	fi
done
# A -c run is muted, so what can be checked here is the data path and the
# pattern, which is what the two self-checks assert; whether it sounds
# like anything is a listen.
python3 - "$out" <<'PY'
import sys, os, itertools
from PIL import Image, ImageChops

# **The world, not the HUD.** Every check here compares whole frames, so
# anything that changes any pixel can satisfy one -- and the preset
# label and the typing prompt both live along the bottom and both change
# with what is being checked. Two checks were already passing on the
# prompt's own text (2026-09-23), so the comparisons take the frame
# above the strip and nothing else.
HUD_STRIP = 70

def world(im):
	w, h = im.size
	return im.crop((0, 0, w, h - HUD_STRIP))
out = sys.argv[1]
# The numbered presets only: the directory also keeps the shot the plan
# points at and whatever else has been left in it
shots = sorted(f for f in os.listdir(out)
		if f.endswith(".png") and "noprobe" not in f and f[0].isdigit())
if len(shots) != 4:
	print("FAIL: %d pictures, wanted 4" % len(shots)); sys.exit(1)
ims = {}
for f in shots:
	im = world(Image.open(os.path.join(out, f)).convert("RGB"))
	d = list(im.getdata())
	n = float(len(d))
	ims[f] = (im, tuple(sum(p[i] for p in d) / n for i in range(3)))
	print("%-28s mean rgb %5.1f %5.1f %5.1f" % ((f,) + ims[f][1]))
worst = 255.0
for a, b in itertools.combinations(shots, 2):
	d = ImageChops.difference(ims[a][0], ims[b][0])
	px = list(d.getdata())
	mean = sum(sum(p) for p in px) / (3.0 * len(px))
	worst = min(worst, mean)
print("the closest two presets are %.2f of a level apart" % worst)
# 4, not 1: with the label out of the comparison the closest two
# presets are 11 levels apart, and 1 was low enough that the label's own
# text changing between them would have carried the check on its own
ok = worst > 4.0
print("PASS: the four presets are four pictures" if ok
		else "FAIL: two presets look the same")

# **The four in one picture**, because the pick is the user's and four
# files in a directory is four looks where one sheet is one.
sheet_w = 640
sheet = Image.new("RGB", (sheet_w * 2, int(sheet_w * 0.5625) * 2 + 4),
		(0, 0, 0))
for i, f in enumerate(shots):
	im = ims[f][0].resize((sheet_w, int(sheet_w * 0.5625)))
	sheet.paste(im, ((i % 2) * sheet_w,
			(i // 2) * (int(sheet_w * 0.5625) + 4)))
sheet.save("%s/presets_sheet.png" % out)
print("the four presets in one picture: %s/presets_sheet.png" % out)

# The probe: the same frame with it and with an environment of nothing
# in its place. What is asserted is that some part of the picture moves a
# lot -- the search is over blocks rather than a fixed crop, because the
# room gets recomposed and a crop that was on a mirror ends up on a wall
# (it read 61.4 against 60.4 on a sphere's dark side while another block
# moved 86 levels, 2026-09-23).
a = world(Image.open("%s/1-cold_in_warm_out.png" % out).convert("L"))
b = world(Image.open("%s/1-cold_in_warm_out-noprobe.png" % out).convert("L"))
pa, pb = a.load(), b.load()
w, h = a.size
best, bx, by = 0.0, 0, 0
for y in range(0, h - 60, 30):
	for x in range(0, w - 60, 30):
		m = sum(abs(pa[xx, yy] - pb[xx, yy])
				for yy in range(y, y + 60) for xx in range(x, x + 60)) / 3600.0
		if m > best:
			best, bx, by = m, x, y
print("the probe moves a 60x60 block by %.2f of a level at its most, "
		"at %d,%d" % (best, bx, by))
# **15.** The threshold went down to 5 on a reading of 8.92 that was not
# the probe at all: the key that toggles it was a letter, the prompt ate
# it, and what moved was the prompt's own text at the bottom of the
# frame. On a function key the probe moves a sphere by 46 levels
# (2026-09-23).
probe_ok = best > 15.0
print("PASS: the probe reaches the metals" if probe_ok
		else "FAIL: the probe changes nothing on a metal")

# The dissolve: the wall has to move, and the closed picture has to be
# the picture it was
def mean_of(name):
	im = world(Image.open("%s/%s.png" % (out, name)).convert("L"))
	return im, list(im.getdata())

closed, dc = mean_of("dissolve-closed")
opened, do = mean_of("dissolve-open")
again, da = mean_of("dissolve-closed-again")
moved = sum(abs(p - q) for p, q in zip(dc, do)) / float(len(dc))
back = sum(abs(p - q) for p, q in zip(dc, da)) / float(len(dc))
print("the dissolve moves the frame by %.2f of a level and comes back "
		"to within %.2f" % (moved, back))
dissolve_ok = moved > 2.0 and back < moved / 3.0
print("PASS: a bay opens and closes again" if dissolve_ok
		else "FAIL: the dissolve does not open, or does not come back")

# The typing path: the prompt has to show the match it found, the launch
# has to move the camera, and Escape has to bring the room back to the
# picture it was
typed, _ = mean_of("typed")
launched, dl = mean_of("launched")
home, dh = mean_of("back-home")
flew = sum(abs(p - q) for p, q in zip(dc, dl)) / float(len(dc))
came_back = sum(abs(p - q) for p, q in zip(dc, dh)) / float(len(dc))
print("the launch moves the frame by %.2f of a level and Escape comes "
		"back to within %.2f" % (flew, came_back))
typing_ok = flew > 8.0 and came_back < flew / 2.0
print("PASS: typing a name flies the camera in, and Escape flies it out"
		if typing_ok else
		"FAIL: the typing path does not launch, or does not come back")

# The terminal: what says it is readable is that the panel covers the
# middle of the frame and has text's contrast in it, not the room's
term, dt = mean_of("terminal")
w, h = term.size
mid = term.crop((w // 2 - 320, h // 2 - 170, w // 2 + 320, h // 2 + 170))
# Text is a few per cent of a panel's area, so a percentile lands on
# the background whatever the rows say: what is counted is how many
# pixels are text-bright against a panel that is dark
px = sorted(mid.getdata())
n = len(px)
dark = px[int(n * 0.30)]
bright = sum(1 for v in px if v > 120)
print("the terminal panel is %d at its third and has %d text-bright "
		"pixels" % (dark, bright))
terminal_ok = dark < 40 and bright > 1500
print("PASS: the terminal is flat, dark and readable" if terminal_ok
		else "FAIL: the terminal panel is not on screen")

# **The two control modes**: walking has to move the room, and it is
# the mode the player lands in
stood, ds = mean_of("fps-stood")
walked, dw = mean_of("fps-walked")
walk = sum(abs(p - q) for p, q in zip(ds, dw)) / float(len(ds))
print("walking forward moves the frame by %.2f of a level" % walk)
walk_ok = walk > 3.0
print("PASS: FPS mode walks" if walk_ok
		else "FAIL: holding W moves nothing -- the room does not start in FPS")

# **The pause dialog**: it has to appear over the room and go away
# again. A room whose only way out is killing the process is not a
# launcher.
paused, dpa = mean_of("paused")
unpaused, dup = mean_of("unpaused")
came_up = sum(abs(p - q) for p, q in zip(dpa, dup)) / float(len(dpa))
print("the pause dialog moves the frame by %.2f of a level" % came_up)
pause_ok = came_up > 1.0
print("PASS: Escape pauses and Escape comes back" if pause_ok
		else "FAIL: no pause dialog")

# The drift: two frames a second apart, before anything was frozen
drift_a, da2 = mean_of("drift-a")
drift_b, db2 = mean_of("drift-b")
drift = sum(abs(p - q) for p, q in zip(da2, db2)) / float(len(da2))
print("the room drifts by %.2f of a level in a second" % drift)
drift_ok = drift > 0.20
print("PASS: nothing in the room is static" if drift_ok
		else "FAIL: the room is a still frame")

# The attract mode: the camera has to leave its standing place when the
# room is left alone, and come back when it is touched
ah, dah = mean_of("attract-home")
aw, daw = mean_of("attract-away")
ab, dab = mean_of("attract-back")
went = sum(abs(p - q) for p, q in zip(dah, daw)) / float(len(dah))
came = sum(abs(p - q) for p, q in zip(dah, dab)) / float(len(dah))
print("the attract mode moves the frame by %.2f of a level and a key "
		"brings it back to within %.2f" % (went, came))
attract_ok = went > 10.0 and came < went / 2.0
print("PASS: the room shows itself off when left alone" if attract_ok
		else "FAIL: the attract mode does not run, or does not come back")

# The ornament: the friezes stripped to plain stone have to change the
# frame, or the generated maps are not reaching anything
plain, dp = mean_of("no-ornament")
ornamented = sum(abs(p - q) for p, q in zip(dc, dp)) / float(len(dc))
print("stripping the ornament moves the frame by %.2f of a level"
		% ornamented)
ornament_ok = ornamented > 1.5
print("PASS: the generated ornament is on something" if ornament_ok
		else "FAIL: nothing in the room wears the generated maps")
# **The top of the picture** ([PBR_HDR]): a renderer that clips every
# radiance at 1.0 before the tonemap has nothing above its shoulder to
# roll off, and a source then cannot be brighter than a fully-lit wall.
#
# **The 99.9th and not the 99th.** The 99th was the measure while the
# orbs were 8-voxel pockets filling much of the frame; at 3 voxels and
# at a standing eye they are half a per cent of it, and the 99th then
# reads the wall (128) however bright the sources are -- it measured the
# composition, not the range (2026-09-23).
shot = sorted(Image.open("%s/1-cold_in_warm_out.png" % out)
		.convert("L").crop((0, 0, 1280, 720 - HUD_STRIP)).getdata())
top = shot[int(len(shot) * 0.999)]
lit = sum(1 for v in shot if v >= 248) / float(len(shot))
print("the room's 99.9th percentile is %d and %.2f%% of it is a source"
		% (top, lit * 100))
hdr_ok = top >= 240 and lit > 0.002
print("PASS: a source is brighter than a lit wall" if hdr_ok
		else "FAIL: the picture clips before its shoulder -- HDR is off")
sys.exit(0 if (ok and probe_ok and dissolve_ok and typing_ok and
		terminal_ok and ornament_ok and drift_ok and attract_ok and
		hdr_ok and walk_ok and pause_ok) else 1)
PY
