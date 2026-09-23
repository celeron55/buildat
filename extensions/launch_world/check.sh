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
#
# tier: quick
#
# It keeps builtin/luanti/test/lib.sh's contract ([CI_RUNS] (1)): exit 0
# passed, 1 failed, 2 could not run, and a last line saying which.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/options_for_LAUNCH_WORLD"; mkdir -p "$out"
# **Last run's pictures are not this run's.** The client crashed halfway
# through a run and every check still reported PASS, off the shots left
# behind by the run before (2026-09-23).
rm -f "$out"/*.png
# The player's own voxels are a save, so a run starts from none
rm -f "$here/user/launch_world/room.txt"
# The room's description asserts itself first: it is a function of
# (x, y, z), and a wall with no slabs in it fails here rather than in a
# picture nobody reads
lua "$here/extensions/launch_world/room.lua" || exit 1
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi

# **The room is a launch UI the setting can name** ([LAUNCH_SANDBOX]:
# the launch UI is a slot). Two short runs before the long one: the
# preference picks the room, and a name that is not there falls back to
# the menu rather than leaving the client with no launcher. -o is used
# so that a check never writes the user's preferences.
{ echo "delay 2500"; echo "quit"; } > "$out/cmds_slot.txt"
slot=$(bin/buildat -D ../user -w 640x360 -l 3 -o launch_ui=launch_world 	-c @"$out/cmds_slot.txt" 2>&1 |
	sed -e 's/\x1b\[[0-9;]*m//g' | grep -ac "launch_w.*: contents: ")
back=$(bin/buildat -D ../user -w 640x360 -l 3 -o launch_ui=nosuchthing 	-c @"$out/cmds_slot.txt" 2>&1 |
	sed -e 's/\x1b\[[0-9;]*m//g' |
	grep -ac "the launch UI is __menu")
# **And the room runs in the sandbox** ([LAUNCH_SANDBOX]), which is what
# its launch_ui.txt asks for: the marker is what the client reads, so a
# room that quietly went back to running trusted would still pass every
# assertion below. This is the one that would not.
sandboxed=$(grep -c "^sandboxed$" "$here/extensions/launch_world/launch_ui.txt")
if [ "$sandboxed" -lt 1 ]; then
	echo "FAIL: launch_world no longer asks to be run in the sandbox"
	exit 1
fi
echo "the slot: picked by name $slot, fell back to the menu $back, sandboxed"
if [ "$slot" -lt 1 ] || [ "$back" -lt 1 ]; then
	echo "FAIL: the launch UI setting does not pick the room," \
			"or a missing one does not fall back to the menu"
	exit 1
fi
{ echo "delay 5000"
	# **It starts in FPS mode**, so the walking is checked first and then
	# Tab goes to menu mode, where the prompt and the digits live. A held
	# key needs keydown/delay/keyup; keypress is one frame and moves
	# nothing.
	echo "screenshot $out/fps-stood.png"
	echo "delay 400"
	# **Carrying**: the orb the crosshair is already on comes into the
	# hand with E and goes back down with right click. A scripted run
	# cannot aim with the mouse -- SetMouseVisible(false) stands down in
	# one, so GetMouseMove reads zero -- which is why the arrows turn.
	echo "keypress E"
	echo "delay 500"
	echo "screenshot $out/carried.png"
	echo "delay 300"
	echo "mouse_click right"
	echo "delay 500"
	echo "keydown W"
	echo "delay 1400"
	echo "keyup W"
	echo "delay 600"
	echo "screenshot $out/fps-walked.png"
	echo "delay 400"
	# **Placing and digging**: walk up to the wall, put one of the
	# player's own voxels on it and prise it out again. The room's own
	# stone has no wireframe and cannot be dug, so what is dug here is
	# what was just placed.
	echo "keydown W"
	echo "delay 3600"
	echo "keyup W"
	echo "delay 700"
	echo "mouse_click right"
	echo "delay 700"
	# **A dig let go of inside the second puts the voxel back**, so this
	# short hold has to leave the count where it was
	echo "mouse_down left"
	echo "delay 300"
	echo "mouse_up left"
	echo "delay 600"
	echo "mouse_down left"
	echo "delay 1500"
	echo "mouse_up left"
	echo "delay 900"
	# And one left behind, for the second run below to find
	echo "mouse_click right"
	echo "delay 700"
	echo "keypress Tab"
	echo "delay 600"
	# **A server is connected to, and says so when it cannot be.**
	# "localhost" is always in the list and nothing listens on its port
	# in a check run, so this is the failure path: a notice line, the
	# room still standing, no dialog and no crash.
	echo "keypress H"
	echo "keypress O"
	echo "keypress S"
	echo "keypress T"
	echo "delay 400"
	echo "keypress Return"
	echo "delay 2500"
	echo "screenshot $out/connect-failed.png"
	echo "delay 400"
	echo "keypress Escape"
	echo "delay 1500"
	# **Escape pops a level**, so it left menu mode as well as the
	# connect; Tab comes back for the arrows below
	echo "keypress Tab"
	echo "delay 600"
	# **The arrows browse the room** with the prompt empty: along a row
	# and between the rows, the wall first and the floor's ranks after
	echo "keypress Right"
	echo "delay 250"
	echo "keypress Down"
	echo "delay 250"
	echo "keypress Left"
	echo "delay 400"
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
	# The dissolve: a bay opens and closes again. What is checked is that
	# the wall moves and comes back -- states being configurations of one
	# scene, the closed picture has to be the picture it was.
	#
	# **Through the prompt, not through Enter alone.** Enter takes what
	# is browsed now ("Enter launches, always"), and what is browsed is
	# whatever the arrows above left selected -- which may be a game with
	# a server to start. Three letters name the empty pocket and Enter
	# opens that one, every run.
	echo "keypress F1"
	echo "delay 800"
	echo "screenshot $out/dissolve-closed.png"
	# A screenshot lands a frame or two after the command, so the next
	# key has to wait or it is in the picture (2026-09-23)
	echo "delay 600"
	echo "keypress I"
	echo "keypress N"
	echo "keypress S"
	echo "delay 300"
	echo "keypress Return"
	echo "delay 1600"
	echo "screenshot $out/dissolve-open.png"
	echo "delay 600"
	echo "keypress Escape"
	# The cubes land in 0.9 s, but the voxels coming back have to be
	# remeshed and relit before the picture is the picture it was
	echo "delay 5000"
	echo "screenshot $out/dissolve-closed-again.png"
	echo "delay 600"
	# The typing path: three letters fuzzy-match a name, Enter takes it
	# and the camera flies in; Escape brings the room back.
	#
	# **The empty pocket, not a game.** This typed "und" and launched
	# undermine for real: a local server that has to compile its modules
	# first, and when that ran long the connect failed and the game's own
	# Escape exited the client -- taking the other 55 commands of this
	# sequence with it, so half the assertions below read missing files
	# (2026-09-23). What is being checked here is the prompt, the flight
	# and the way back, and the empty pocket exercises all three with
	# nothing to start.
	echo "keypress I"
	echo "keypress N"
	echo "keypress S"
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
	# on to it and the panel flat over it. **Menu mode first**: in FPS
	# the letters are movement, so "set" would walk the player backwards
	# and pick a sphere up instead of typing.
	echo "keypress Tab"
	echo "delay 500"
	echo "keypress S"
	echo "keypress E"
	echo "keypress T"
	echo "delay 400"
	echo "keypress Return"
	echo "delay 2400"
	echo "screenshot $out/terminal.png"
	# **A setting changed and changed back.** A -w run never writes the
	# preferences file (save_preferences stands down when the size is
	# forced), so this asserts the change, not the file -- and the
	# user's own settings are safe from a check.
	echo "delay 300"
	echo "keypress Down"
	echo "delay 200"
	echo "keypress Right"
	echo "delay 400"
	echo "screenshot $out/terminal-changed.png"
	echo "delay 300"
	echo "keypress Right"
	echo "delay 400"
	echo "delay 400"
	echo "keypress Escape"
	echo "delay 2600"
	echo "delay 600"
	# The ornament, stripped: the friezes go plain and the frame has to
	# change. The generator's own check passed for a day while nothing in
	# the room wore what it made.
	# **F6 re-meshes the whole room**, the ornament being voxels now, and
	# a shot 900 ms later sometimes landed before the mesh did -- which
	# read as "nothing wears the generated maps" (2026-09-23)
	echo "keypress F6"
	echo "delay 2200"
	echo "screenshot $out/no-ornament.png"
	echo "delay 400"
	echo "keypress F6"
	echo "delay 2200"
	# The room as it is, and then the same frame with the reflection
	# probe taken off the zone, which is what says the probe reaches the
	# metals
	echo "screenshot $out/room.png"
	echo "delay 400"
	echo "keypress F5"
	echo "delay 800"
	echo "screenshot $out/room-noprobe.png"
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
	# program: in FPS with nothing left to pop, Escape comes up with it;
	# Escape again takes it away.
	#
	# **Escape pops one level in this room**, so a sequence has to know
	# which level it is on: the terminal step above typed in menu mode
	# and the Escape that left the desk did not pop it, so this one pops
	# menu -> walking and the next is the one that pauses.
	echo "keypress Escape"
	echo "delay 700"
	echo "keypress Escape"
	echo "delay 700"
	echo "screenshot $out/paused.png"
	echo "delay 400"
	echo "keypress Escape"
	echo "delay 700"
	echo "screenshot $out/unpaused.png"
	echo "delay 400"
	# **The developer console, over the room** ([LAUNCH_CONSOLE] offers
	# its screen and the room takes it): the pause dialog's third item,
	# a line typed at it, and Escape to put the room back.
	echo "keypress Escape"
	echo "delay 600"
	echo "keypress Down"
	echo "keypress Down"
	echo "delay 300"
	echo "keypress Return"
	echo "delay 1200"
	echo "screenshot $out/room-console.png"
	echo "delay 300"
	echo "text buildat.version()"
	echo "delay 300"
	echo "keypress Return"
	echo "delay 600"
	echo "keypress Escape"
	echo "delay 1200"
	echo "delay 400"
	# **A hold on a game's sphere launches it** (the playtest's first
	# finding: it looped and started nothing). Last of all, because it
	# starts a server and takes the client into the game.
	echo "mouse_down left"
	echo "delay 1400"
	echo "mouse_up left"
	echo "delay 9000"
	echo "screenshot $out/in-game.png"
	# **And back out of it** ([MENU_CONTEXT]): the room stands behind the
	# game the whole time, so the way back is the client's own
	# leave_to_menu plus a viewport. F10 is the room's key for it; a game
	# with a menu leaves through buildat.leave(), and this tree has one.
	echo "delay 400"
	echo "keypress F10"
	echo "delay 2500"
	echo "screenshot $out/back-from-game.png"
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
grep -aE "palette preset|ornament ok|synth ok|orb sizes" "$out/cli.log" |
	sed 's/.*launch_w[a-z]*: //'
# **An orb is as big as its game**: a tree with more than one game has to
# spread them, or the size is saying nothing
sizes=$(grep -a "launch_w.*: orb sizes: " "$out/cli.log" | head -1)
if ! echo "$sizes" | grep -q "1.20 to 1.80"; then
	echo "FAIL: the orbs are not sized by their games -- $sizes"
	exit 1
fi
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
# **The player's own voxels**: one placed, one dug, and the save written
# both times. The save is a diff against a generated room, so a room that
# forgot it would look exactly the same.
# **The arrows walk the room's own grid**: a row along the wall and the
# floor's ranks after it, read off where the things are rather than off a
# second list. Four different things for four presses.
browsed=$(grep -a "launch_w.*: browse: " "$out/cli.log" | sed 's/.*browse: //' |
	sort -u | wc -l)
echo "the arrows browsed $browsed different places"
if [ "$browsed" -lt 3 ]; then
	echo "FAIL: the arrows do not browse the room"
	exit 1
fi

# **The terminal changes a setting**, rather than showing one
changes=$(grep -a "launch_w.*: setting: " "$out/cli.log" | wc -l)
first=$(grep -a "launch_w.*: setting: " "$out/cli.log" | head -1 | sed 's/.*setting: //')
last=$(grep -a "launch_w.*: setting: " "$out/cli.log" | tail -1 | sed 's/.*setting: //')
echo "the terminal changed $changes settings: $first then $last"
if [ "$changes" -lt 2 ] || [ "$first" = "$last" ]; then
	echo "FAIL: the terminal's rows do not change anything"
	exit 1
fi

conn=$(grep -a "launch_w.*: connect: " "$out/cli.log" | head -1 |
	sed 's/.*launch_w[a-z]*: //')
echo "a server was asked for: ${conn:-(nothing)}"
if [ -z "$conn" ]; then
	echo "FAIL: Enter on a server does not connect to it"
	exit 1
fi

console=$(grep -ac "launch_w.*: console: over the room" "$out/cli.log")
console_ran=$(grep -ac "launch_c.*: console: buildat.version() = " "$out/cli.log")
console_shut=$(grep -ac "launch_c.*: console: closed" "$out/cli.log")
echo "the console opened $console times, ran a line $console_ran, closed $console_shut"
if [ "$console" -lt 1 ] || [ "$console_ran" -lt 1 ] || [ "$console_shut" -lt 1 ]; then
	echo "FAIL: the room's developer console does not open, run or close"
	exit 1
fi

back=$(grep -ac "launch_w.*: game: back in the room" "$out/cli.log")
swept=$(grep -a "forget_game_ui" "$out/cli.log" | tail -1 |
	sed 's/.*forget_game_ui(): //')
echo "leaving the game swept ${swept:-nothing}"
if [ "$back" -lt 1 ]; then
	echo "FAIL: the room does not come back from a game"
	exit 1
fi

held=$(grep -ac "launch_w.*: hold: launching " "$out/cli.log")
echo "a hold on a sphere launched $held times"
if [ "$held" -ne 1 ]; then
	echo "FAIL: holding on a game's sphere launched $held times, not once"
	exit 1
fi

# **The opening hint**, which is the room's whole answer to a first-time
# user who does not know it is a first-person game: one line, and the
# first step takes it away again. A line that stayed would be a HUD.
hint_up=$(grep -ac "launch_w.*: hint: the three keys" "$out/cli.log")
hint_gone=$(grep -ac "launch_w.*: hint: taken away" "$out/cli.log")
echo "the hint was shown $hint_up and taken away $hint_gone"
if [ "$hint_up" -lt 1 ] || [ "$hint_gone" -lt 1 ]; then
	echo "FAIL: the hint does not appear, or does not leave when the" \
			"player moves"
	exit 1
fi

picked=$(grep -ac "launch_w.*: carry: picked up" "$out/cli.log")
putdown=$(grep -ac "launch_w.*: carry: put down" "$out/cli.log")
echo "the player carried $picked spheres and put down $putdown"
if [ "$picked" -lt 1 ] || [ "$putdown" -lt 1 ]; then
	echo "FAIL: E picks nothing up, or right click puts nothing down"
	exit 1
fi

placed=$(grep -ac "launch_w.*: place: " "$out/cli.log")
dug=$(grep -ac "launch_w.*: dig: " "$out/cli.log")
wrote=$(grep -ac "launch_w.*: save: .* written" "$out/cli.log")
echo "the player placed $placed voxels, dug $dug, and the save was written $wrote times"
if [ "$placed" -lt 2 ] || [ "$dug" -lt 1 ] || [ "$wrote" -lt 3 ]; then
	echo "FAIL: placing or digging did nothing"
	exit 1
fi
# **Exactly what the sequence asks for, and nothing more.** Two right
# clicks place and one hold digs; the third right click puts a carried
# sphere down and must not leave a voxel behind it, and the short hold
# above must not dig. Both were bugs (user, 2026-09-23).
if [ "$placed" -ne 2 ] || [ "$dug" -ne 1 ]; then
	echo "FAIL: putting a sphere down also placed a voxel," \
			"or a dig let go of early still dug"
	exit 1
fi

# **And it survives a restart**, which is the whole point of a diff
# against a generated room: a second client, booted and closed, has to
# find the voxel the first one left.
{ echo "delay 2500"; echo "quit"; } > "$out/cmds2.txt"
bin/buildat -m launch_world -D ../user -w 640x400 -l 3 \
	-c @"$out/cmds2.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli2.log"
read_back=$(grep -a "launch_w.*: save: .* rows read" "$out/cli2.log" |
	head -1 | sed 's/.*save: //')
echo "a second client read back: ${read_back:-(nothing)}"
put=$(echo "$read_back" | sed -n 's/.*, \([0-9]*\) spheres put back.*/\1/p')
if [ -z "$read_back" ] || [ "${put:-0}" -lt 1 ]; then
	echo "FAIL: the room forgot what the player placed or moved"
	exit 1
fi

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
# **The palette comparison is gone** (user, 2026-09-23: the right
# colours are already known). This shot four presets from one viewpoint
# and asserted they differed, which was how the palette was to be picked;
# it is picked. The presets are still in the room, on F1 to F4 and in the
# terminal's rows.
# The probe: the same frame with it and with an environment of nothing
# in its place. What is asserted is that some part of the picture moves a
# lot -- the search is over blocks rather than a fixed crop, because the
# room gets recomposed and a crop that was on a mirror ends up on a wall
# (it read 61.4 against 60.4 on a sphere's dark side while another block
# moved 86 levels, 2026-09-23).
a = world(Image.open("%s/room.png" % out).convert("L"))
b = world(Image.open("%s/room-noprobe.png" % out).convert("L"))
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
shot = sorted(Image.open("%s/room.png" % out)
		.convert("L").crop((0, 0, 1280, 720 - HUD_STRIP)).getdata())
top = shot[int(len(shot) * 0.999)]
lit = sum(1 for v in shot if v >= 248) / float(len(shot))
print("the room's 99.9th percentile is %d and %.2f%% of it is a source"
		% (top, lit * 100))
hdr_ok = top >= 240 and lit > 0.002
print("PASS: a source is brighter than a lit wall" if hdr_ok
		else "FAIL: the picture clips before its shoulder -- HDR is off")
every = (probe_ok and dissolve_ok and typing_ok and terminal_ok
		and ornament_ok and drift_ok and attract_ok and hdr_ok and walk_ok
		and pause_ok)
# The one line a machine reads, after the ones a person does
print("PASS: the room is what it says it is" if every
		else "FAIL: the room is not what it says it is")
sys.exit(0 if every else 1)
PY
