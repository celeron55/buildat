#!/bin/bash
# games/launch_world: [LAUNCH_WORLD]'s palette experiment. One picture of
# each of the four presets from the one viewpoint, into
# local/options_for_LAUNCH_WORLD/, which is what settles the palette.
#
# It is also a check: four presets that differ have to come out as four
# pictures that differ, so a preset that quietly stops being applied fails
# a run rather than producing four copies of the same room.
#
#   games/launch_world/check.sh
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD"; mkdir -p "$out"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
bin/buildat_server -m ../games/launch_world -D ../user -P 29795 -l ${SRVLOG:-3} 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 60); do
	grep -q "Server::start\|Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
names="cold_in_warm_out warm_in_cold_out all_cold wrong"
{ echo "delay 5000"
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
	# And the first preset again with the reflection probe taken off the
	# zone, which is what says the probe reaches the metals
	echo "keypress F1"
	echo "delay 800"
	echo "keypress P"
	echo "delay 800"
	echo "screenshot $out/1-cold_in_warm_out-noprobe.png"
	echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
bin/buildat -s localhost:29795 -w 1280x720 -l 3 -c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep -aE "palette preset|ornament ok|synth ok" "$out/cli.log" |
	sed 's/.*launch_w[a-z]*: //'
# The ornament generator asserts its own patterns as it builds them
# (ornament.lua's self_check); a generator that quietly returned a flat
# field would pass an eye on a dark slab and fail there
# The bay numbers live in main.cpp and in init.lua -- the room is carved
# on one side and the orbs are placed on the other -- so a run compares
# the two lists and fails if they have drifted
srv_bays=$(grep -a "launch_world: bays " "$out/srv.log" | head -1 |
	sed 's/.*launch_world: bays //')
cli_bays=$(grep -a "launch_w.*: bays " "$out/cli.log" | head -1 |
	sed 's/.*: bays //')
echo "bays, server: ${srv_bays:-(none)}"
if [ "$srv_bays" != "$cli_bays" ]; then
	echo "FAIL: the client's bays are '$cli_bays'"
	exit 1
fi
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
out = sys.argv[1]
# The numbered presets only: the directory also keeps the shot the plan
# points at and whatever else has been left in it
shots = sorted(f for f in os.listdir(out)
		if f.endswith(".png") and "noprobe" not in f and f[0].isdigit())
if len(shots) != 4:
	print("FAIL: %d pictures, wanted 4" % len(shots)); sys.exit(1)
ims = {}
for f in shots:
	im = Image.open(os.path.join(out, f)).convert("RGB")
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
ok = worst > 1.0
print("PASS: the four presets are four pictures" if ok
		else "FAIL: two presets look the same")

# The probe: the same frame with it and with an environment of nothing
# in its place. What is asserted is that some part of the picture moves a
# lot -- the search is over blocks rather than a fixed crop, because the
# room gets recomposed and a crop that was on a mirror ends up on a wall
# (it read 61.4 against 60.4 on a sphere's dark side while another block
# moved 86 levels, 2026-09-23).
a = Image.open("%s/1-cold_in_warm_out.png" % out).convert("L")
b = Image.open("%s/1-cold_in_warm_out-noprobe.png" % out).convert("L")
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
probe_ok = best > 10.0
print("PASS: the probe reaches the metals" if probe_ok
		else "FAIL: the probe changes nothing on a metal")

# The dissolve: the wall has to move, and the closed picture has to be
# the picture it was
def mean_of(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("L")
	d = list(im.getdata())
	return im, d

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
sys.exit(0 if (ok and probe_ok and dissolve_ok and typing_ok and
		terminal_ok) else 1)
PY
