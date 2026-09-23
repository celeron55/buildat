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

# **The floor's example servers say they are examples** ([TWO_AUDIENCES]:
# a first-time player learns what the room is by trying one, and nine
# invented hostnames that read as joinable teach the wrong thing). This
# desk's client has ten addresses of its own, so none of the padding
# shows here -- the assertion needs a client with no history, which is
# an empty user path of its own.
mkdir -p "$out/emptyuser"
{ echo "delay 4000"; echo "quit"; } > "$out/cmds_cold.txt"
examples=$(bin/buildat -m launch_world -D "$out/emptyuser" -w 640x360 -l 3 \
	-c @"$out/cmds_cold.txt" 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' |
	grep -a "launch_w.*: servers: .* on the floor" | head -1 |
	sed -n 's/.*floor, \([0-9]*\) of them saying.*/\1/p')
echo "a client with no history draws ${examples:-0} example servers"
if [ "${examples:-0}" -lt 1 ]; then
	echo "FAIL: the floor's made-up servers do not say they are examples"
	exit 1
fi

# **The room's sound levels are the room's, and they are kept**
# ([ROOM_SOUND]: the design is to be played against and iterated on by
# ear, which wants the levels reachable without an edit). Two rows on
# the terminal, two numbers in the room's own save; a written save is
# read back here, which is the half a listening session depends on.
mkdir -p "$out/tieruser/launch_world"
printf '!sound 0.40 0.30\n' > "$out/tieruser/launch_world/room.txt"
{ echo "delay 4000"; echo "quit"; } > "$out/cmds_snd.txt"
bin/buildat -m launch_world -D "$out/tieruser" -w 640x360 -l 3 \
	-L "$out/snd.log" -c @"$out/cmds_snd.txt" > /dev/null 2>&1
snd=$(grep -a "launch_w.*: sound: the orbs at " "$out/snd.log" | head -1 |
	sed 's/.*sound: //')
echo "a saved room came up with $snd"
rm -f "$out/tieruser/launch_world/room.txt"
if [ "$snd" != "the orbs at 0.40, the bed at 0.30" ]; then
	echo "FAIL: the room does not keep the levels it was left at"
	exit 1
fi

# **A tight target wins over a generous one** (user): an orb in front of
# the player is what they want -- unless they are pointing at a voxel
# they placed, and then they want the voxel. The room's contents are the
# tree's, so the run is aimed off what the room says about itself: one
# floor orb and where it stands, and a placed voxel written into the
# room's own save on the line between the two. The same look one way and
# the other settles it -- through the voxel, the voxel wins; over it, the
# orb does.
mkdir -p "$out/tieruser/launch_world"
{ echo "delay 4000"; echo "quit"; } > "$out/cmds_tier0.txt"
bin/buildat -m launch_world -D "$out/tieruser" -w 640x360 -l 3 \
	-L "$out/tier0.log" -c @"$out/cmds_tier0.txt" > /dev/null 2>&1
sample=$(grep -a "launch_w.*: orb sample: " "$out/tier0.log" | head -1 |
	sed 's/.*orb sample: //')
if [ -z "$sample" ]; then
	echo "FAIL: the room names no floor orb to aim at"
	exit 1
fi
python3 - "$sample" "$out/tieruser/launch_world/room.txt" "$out/aim.txt" <<'PYAIM' || exit 1
import math, sys
# "<name> at x y z from sx sy sz", in voxels
text = sys.argv[1]
at = text.split(" at ")[1]
o, st = at.split(" from ")
ox, oy, oz = (float(v) for v in o.split())
sx, sy, sz = (float(v) for v in st.split())
dx, dy, dz = ox - sx, oy - sy, oz - sz
d = math.sqrt(dx * dx + dy * dy + dz * dz)
# Urho3D's forward at a yaw is (sin, 0, cos); pitch is negative upward
# here, which is what the room's own look command takes
yaw = math.degrees(math.atan2(dx, dz)) % 360.0
pitch = math.degrees(math.atan2(-dy, math.sqrt(dx * dx + dz * dz)))
# On the line, inside the five metres the player can reach: six voxels
t = 6.0 / d
vx = round(sx + dx * t)
vy = round(sy + dy * t)
vz = round(sz + dz * t)
open(sys.argv[2], "w").write("%d,%d,%d\n" % (vx, vy, vz))
# The two looks: through the voxel, and a little over it
open(sys.argv[3], "w").write("%.2f %.2f %.2f\n" % (yaw, pitch, pitch - 8.0))
print("aiming at the orb: yaw %.1f pitch %.1f, a placed voxel at %d,%d,%d"
		% (yaw, pitch, vx, vy, vz))
PYAIM
read -r tyaw tpitch tover < "$out/aim.txt"
{ echo "delay 5000"; echo "look $tyaw $tpitch"; echo "delay 1500"
	echo "look $tyaw $tover"; echo "delay 1500"; echo "quit"
	} > "$out/cmds_tier.txt"
bin/buildat -m launch_world -D "$out/tieruser" -w 640x360 -l 3 \
	-L "$out/tier.log" -c @"$out/cmds_tier.txt" > /dev/null 2>&1
wins=$(grep -ac "launch_w.*: pointing: the voxel at .* wins over orb" "$out/tier.log")
takes=$(grep -ac "launch_w.*: pointing at orb .*(up its column)" "$out/tier.log")
echo "the voxel won $wins times and the orb was taken over it $takes times"
rm -f "$out/tieruser/launch_world/room.txt"
if [ "$wins" -lt 1 ] || [ "$takes" -lt 1 ]; then
	echo "FAIL: a placed voxel does not win over the orb behind it," \
			"or winning it costs the orb beside it"
	exit 1
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
# **And a launcher that cannot be left with no launcher** ([MENU_FALLBACK]):
# with the chosen one missing *and* the fallback failing, the client says
# so in its own window and keeps running -- it used to abort, which is
# the one failure a slot anybody can fill must not have.
last=$(BUILDAT_TEST_NO_LAUNCHER=1 bin/buildat -D ../user -w 640x360 -l 3 \
	-o launch_ui=nosuchthing -c @"$out/cmds_slot.txt" 2>&1 |
	sed -e 's/\x1b\[[0-9;]*m//g' |
	grep -acE "could not start a launch UI|Crash: SIG")
echo "the slot: picked by name $slot, fell back to the menu $back, sandboxed"
if [ "$last" -ne 1 ]; then
	echo "FAIL: with no launcher at all the client does not say so," \
			"or it crashes"
	exit 1
fi
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
	# **Look at the floor first**: flush against the wall the ray starts
	# inside the stone, so there is no empty voxel in front of what is
	# pointed at and nothing to place against -- which is what the
	# standing pitch changing by a few degrees did to this step
	# (2026-09-23). Twenty degrees down is the floor a step ahead.
	echo "look 180 -20"
	echo "delay 500"
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
	echo "event mode menu"
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
	echo "event mode menu"
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
	echo "event mode fps"
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
	# **Menu mode first, and before the reference picture**: every
	# Escape above pops back to walking, and in FPS these three letters
	# are movement and Return opens the desk -- which is what this step
	# was doing for a while, with the assertion passing on the
	# terminal's own arrival. The closed picture has to be taken in the
	# mode the reopened one will be, or "it comes back" compares two
	# cameras (2026-09-23).
	# **The mode is said, not guessed** ([CMD_EVENT]): menu mode at the
	# standing place, which is also where the reopened picture is taken
	# from -- the player walked to the wall to dig, and a reference
	# frame from there compares two cameras rather than two walls.
	echo "event mode menu"
	echo "delay 1800"
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
	echo "event mode menu"
	echo "delay 600"
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
	# on to it and the panel flat over it.
	echo "event mode menu"
	echo "delay 600"
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
	# **The mode is said** ([CMD_EVENT]), so the Escape below is the one
	# that pauses rather than the one that pops a level.
	echo "event mode fps"
	echo "delay 900"
	echo "screenshot $out/prepause.png"
	echo "delay 400"
	echo "keypress Escape"
	echo "delay 700"
	echo "screenshot $out/paused.png"
	echo "delay 400"
	# **The mouse does not turn the camera while a screen is up**
	# (user, 2026-09-23: the pause menu turned it into yaw and pitch).
	# A quarter turn's worth of movement, and the frame behind the
	# dialog has to be the frame it was. **This goes first**, before
	# anything that moves the pointer: once the dialog is gone the
	# mouse turns the camera again, which is the point of it.
	echo "mouse_move 220 40"
	echo "delay 500"
	echo "keypress Escape"
	echo "delay 700"
	echo "screenshot $out/unpaused.png"
	echo "delay 400"
	# **And the dialog answers the mouse** (the third playtest, 1):
	# hovering a row selects it, and a click on the first row is "back
	# to the room", which closes the dialog. Every menu this room draws
	# has to do both; the desk's rows are the same machinery.
	echo "keypress Escape"
	echo "delay 700"
	echo "mouse_pos 640 400"
	echo "delay 600"
	echo "screenshot $out/pause-hover.png"
	echo "delay 300"
	echo "mouse_pos 640 290"
	echo "delay 400"
	echo "mouse_click left"
	echo "delay 700"
	echo "screenshot $out/pause-clicked.png"
	echo "delay 400"
	# **The search walks its matches and the camera follows** (the
	# second playtest, 5 and 6): a term with many matches, then the
	# arrows, and each one has to be a different picture.
	echo "event mode menu"
	echo "delay 600"
	echo "keypress T"
	echo "keypress E"
	echo "keypress S"
	echo "delay 1200"
	echo "screenshot $out/search1.png"
	echo "delay 400"
	echo "keypress Down"
	echo "delay 1000"
	echo "screenshot $out/search2.png"
	echo "delay 400"
	echo "keypress Down"
	echo "delay 1000"
	echo "screenshot $out/search3.png"
	echo "delay 400"
	echo "event mode fps"
	echo "delay 900"
	# **Menu mode's furniture is menu mode's** (the second playtest, 3
	# and 4): a term in the prompt, Tab away, and nothing of the search
	# is on screen in FPS -- and Tab back finds the term again.
	echo "event mode menu"
	echo "delay 600"
	echo "keypress D"
	echo "keypress I"
	echo "keypress G"
	echo "delay 400"
	echo "screenshot $out/term-menu.png"
	echo "delay 300"
	echo "keypress Tab"
	echo "delay 700"
	echo "screenshot $out/term-fps.png"
	echo "delay 300"
	echo "keypress Tab"
	echo "delay 700"
	echo "screenshot $out/term-back.png"
	echo "delay 400"
	# **Not Escape**: with a term in the prompt Escape clears the term
	# and stays in menu mode, so the console's own Escape below would
	# pop the mode instead of opening the dialog
	echo "event mode fps"
	echo "delay 900"
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
	# **And an orb answers the mouse** (the third playtest's rule, in
	# the room rather than in a dialog): a click on one launches it, the
	# way Enter launches what is browsed. Last, because it starts
	# something -- the same reason the hold above is last.
	# **Tab, not the mode event**: the room answering a key at all after
	# a game is half of what this step proves -- its own handlers used
	# to go with the game's ([LAUNCH_SANDBOX]'s reset dropped every
	# sandboxed handler, and the room is sandboxed now)
	echo "keypress Tab"
	echo "delay 1800"
	echo "mouse_pos 300 420"
	echo "delay 400"
	echo "mouse_click left"
	echo "delay 1200"
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
grep -aE "palette preset|ornament ok|synth ok|orb sizes|the room hums" "$out/cli.log" |
	sed 's/.*launch_w[a-z]*: //'
# **The room hums, and the pattern answers what the player is doing**
# ([ROOM_SOUND]): six voices take the nearest orbs and the beat rises
# from barely-there when something is being looked at.
hums=$(grep -a "launch_w.*: the room hums" "$out/cli.log" | head -1 |
	sed 's/.*launch_w[a-z]*: //')
if [ -z "$hums" ]; then
	echo "FAIL: the room says nothing about its own sound"
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

# **Each step of the sequence says it did its own thing**, so a mode
# that drifted cannot pass on another step's picture: the dissolve was
# typing into FPS for a while and its assertion was satisfied by the
# terminal opening instead (2026-09-23).
for want in "dissolve: bay" "launch: " "terminal: sat down"; do
	if ! grep -aq "launch_w.*: $want" "$out/cli.log"; then
		echo "FAIL: the sequence never got to \"$want\" -- a step typed" \
				"into the wrong mode"
		exit 1
	fi
done

# **Every orb has a mark and they are not all the same one** (the
# playtests asked for this three times and no check covered it): the
# room says how many pixels of each mark are the mark, so an empty one
# and a shared one are both visible from the log.
inks=$(grep -a "launch_w.*: mark: " "$out/cli.log" | sed 's/.*ink //' |
	sort -u | wc -l)
blank=$(grep -ac "launch_w.*: mark: .* ink 0$" "$out/cli.log")
echo "the room drew marks of $inks different weights, $blank of them empty"
if [ "$inks" -lt 3 ] || [ "$blank" -gt 0 ]; then
	echo "FAIL: the orbs share a mark, or one of them has none"
	exit 1
fi

# **Every orb about two voxels across** ([LAUNCH_SIGNIFY]): the sizes
# come from what a launch action says about itself, ranked within its
# own category, so a server is no longer the largest thing in the room
# for want of anything saying otherwise. The band is asserted, and that
# more than one category answered -- a room where nothing had an
# opinion would draw every orb the same and still look right.
sizes=$(grep -a "launch_w.*: orb sizes: " "$out/cli.log" | head -1 |
	sed 's/.*orb sizes: //')
echo "orb sizes: ${sizes:-(none)}"
band=$(echo "$sizes" | sed -n 's/.*, \([0-9.]*\) to \([0-9.]*\) voxels.*/\1 \2/p')
ranked=$(echo "$sizes" | sed -n 's/.*ranked within //p')
if [ -z "$band" ] || [ "$ranked" = "nothing" ]; then
	echo "FAIL: the room does not size its orbs by what they say about" \
			"themselves"
	exit 1
fi
python3 - "$band" <<'PYSZ' || exit 1
import sys
lo, hi = (float(v) for v in sys.argv[1].split())
if not (1.6 <= lo <= hi <= 2.4):
	print("FAIL: an orb is outside the band around two voxels: %.2f to %.2f"
			% (lo, hi))
	raise SystemExit(1)
if hi - lo < 0.1:
	print("FAIL: every orb is the same size -- nothing is ranked")
	raise SystemExit(1)
PYSZ

walked=$(grep -ac "launch_w.*: prompt: match [0-9]* of " "$out/cli.log")
matched=$(grep -a "launch_w.*: prompt: \"tes\" matches " "$out/cli.log" |
	head -1 | sed 's/.*matches \([0-9]*\).*/\1/')
echo "the search found ${matched:-0} matches and the arrows walked $walked"
if [ "${matched:-0}" -lt 3 ] || [ "$walked" -lt 2 ]; then
	echo "FAIL: the search does not find several matches, or the arrows" \
			"do not walk them"
	exit 1
fi

hidden=$(grep -ac "launch_w.*: prompt: hidden with the mode" "$out/cli.log")
backagain=$(grep -ac "launch_w.*: prompt: back, \"dig\"" "$out/cli.log")
echo "the search term was hidden $hidden and came back $backagain"
if [ "$hidden" -lt 1 ] || [ "$backagain" -lt 1 ]; then
	echo "FAIL: the prompt does not hide with the mode, or does not" \
			"come back with its term"
	exit 1
fi

conn=$(grep -a "launch_w.*: connect: " "$out/cli.log" | head -1 |
	sed 's/.*launch_w[a-z]*: //')
echo "a server was asked for: ${conn:-(nothing)}"
if [ -z "$conn" ]; then
	echo "FAIL: Enter on a server does not connect to it"
	exit 1
fi

clicked=$(grep -a "launch_w.*: click: " "$out/cli.log" | head -1 |
	sed 's/.*click: //')
echo "a click on an orb took ${clicked:-(nothing)}"
if [ -z "$clicked" ]; then
	echo "FAIL: clicking an orb does nothing"
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
# **A sphere rests on what it is put on** (user): a carried orb used to
# be let go at arm's length and hang there at eye height. The room says
# what height it came to rest at, in voxels, and the standing eye is
# 3.56 of them -- so anything at or above that is floating.
resty=$(grep -a "launch_w.*: carry: put down .* at y " "$out/cli.log" |
	head -1 | sed -n 's/.* at y \([0-9.-]*\),.*/\1/p')
echo "the orb was put down at y ${resty:-(nothing)} voxels"
if [ -z "$resty" ] || [ "$(python3 -c "print(1 if float('${resty:-9}') < 3.2 else 0)")" != "1" ]; then
	echo "FAIL: a sphere put down floats instead of resting on the floor"
	exit 1
fi
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

# **And ContentDB opens from the room** ([LAUNCH_WORLD]'s version one
# asks for it, and nothing was checking it). The room's job is to get a
# player there: the action is the launch grid's, vanilla starts with
# menu=contentdb and draws its games screen with a row to install.
#
# **Against a mirror of this tree's own**, the one [FIRST_RUN] uses, so
# the check neither needs the network nor asks content.luanti.org for a
# listing on every run. Without one the screen is an error dialog, so
# this would otherwise be a check that fails when the tree is offline.
cdb_game=$(ls "$here/user/luanti/games" 2>/dev/null | head -1)
if [ -z "$cdb_game" ]; then
	echo "SKIP: no installed Luanti game to mirror for ContentDB" >&2
	exit 2
fi
rm -rf "$out/cdb_mirror"; mkdir -p "$out/cdb_mirror"
"$here/util/contentdb_mirror.sh" "$out/cdb_mirror" \
	"$here/user/luanti/games/$cdb_game" Wuzzy "$cdb_game" "$cdb_game" \
	> /dev/null || { echo "SKIP: no ContentDB mirror" >&2; exit 2; }
pkill -f "http.server 30211" 2>/dev/null || true
(cd "$out/cdb_mirror" && exec python3 -m http.server 30211 \
	> "$out/cdb_mirror.log" 2>&1) &
mirror=$!
sleep 1
{ echo "delay 6000"; echo "event mode menu"; echo "delay 600"
	for k in C O N T E N T D B; do echo "keypress $k"; done
	echo "delay 400"; echo "keypress Return"
	echo "delay 25000"; echo "event scan 8 cdb"
	echo "delay 2000"; echo "quit"; } > "$out/cmds_cdb.txt"
rm -f "$out/cdb_cli.log" "$out/cdb_cli_server.log"
BUILDAT_CONTENTDB_URL=http://localhost:30211 \
	timeout 150 bin/buildat -m launch_world -D ../user -w 960x540 -l 3 \
	-L "$out/cdb_cli.log" -c @"$out/cmds_cdb.txt" > /dev/null 2>&1
kill "$mirror" 2>/dev/null; wait "$mirror" 2>/dev/null
asked=$(grep -ac "launch_w.*: launch: ContentDB" "$out/cdb_cli.log")
drew=$(grep -ac 'scan cdb: .*text "ContentDB: games"' "$out/cdb_cli.log")
rows=$(grep -ac 'scan cdb: .*text "Install"' "$out/cdb_cli.log")
echo "the room asked for ContentDB $asked times; the screen drew $drew" \
		"with $rows rows to install"
if [ "$asked" -lt 1 ] || [ "$drew" -lt 1 ] || [ "$rows" -lt 1 ]; then
	echo "FAIL: ContentDB does not open from the room"
	grep -a "launch_w.*: launch: " "$out/cdb_cli.log" | tail -3
	exit 1
fi

# **A save opens by name, end to end** ([LAUNCH_WORLD]: the saves are the
# floor's, and a save is the one launch the grid has no tile for). This
# had only ever been demonstrated as far as the desk's data allowed: every
# save here old enough to try has an empty save.sqlite, so the server
# answered "save X does not say which game it needs" and the round trip
# was never run. The check makes its own save instead of hoping for one.
save=zz_launch_world_test
rm -rf "$here/user/games/vanilla/saves/$save"
port=31879
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE="$save" \
	bin/buildat_server -m ../games/vanilla -D ../user -P "$port" -l 3 \
	> "$out/save_server.log" 2>&1 &
maker=$!
for i in $(seq 1 90); do
	grep -aq "Mods loaded" "$out/save_server.log" 2>/dev/null && break
	sleep 1
done
kill "$maker" 2>/dev/null; wait "$maker" 2>/dev/null
if ! grep -aq "Running world $save (game devtest)" "$out/save_server.log"; then
	echo "SKIP: could not make a save to open (no devtest?)" >&2
	tail -3 "$out/save_server.log" >&2
	exit 2
fi
# Two letters name it and nothing else in the room, Enter opens it, and
# what is asserted is the far end: the server the room started took the
# save's own path and drew no menu on the way.
{ echo "delay 6000"; echo "event mode menu"; echo "delay 600"
	echo "keypress Z"; echo "keypress Z"
	echo "delay 400"; echo "keypress Return"
	# Ten seconds: the server says it opened the save about a second
	# after the launch, and the rest of a world coming up is devtest's
	# business, not this check's
	echo "delay 10000"; echo "quit"; } > "$out/cmds_save.txt"
rm -f "$out/save_cli.log" "$out/save_cli_server.log"
# A client that entered a game does not always get to its own quit
# quickly; the tier's minute is not spent waiting for one that will not
timeout 120 bin/buildat -m launch_world -D ../user -w 640x400 -l 3 \
	-L "$out/save_cli.log" -c @"$out/cmds_save.txt" > /dev/null 2>&1
asked=$(grep -ac "launch_w.*: launch: save $save of vanilla" "$out/save_cli.log")
opened=$(grep -ac "untrusted_launch: opening save $save" "$out/save_cli_server.log")
echo "the save orb asked $asked times, the server opened it $opened times"
rm -rf "$here/user/games/vanilla/saves/$save"
if [ "$asked" -lt 1 ] || [ "$opened" -lt 1 ]; then
	echo "FAIL: a save on the floor does not open its own game by name"
	grep -a "launch_w.*: launch: " "$out/save_cli.log" | tail -3
	tail -3 "$out/save_cli_server.log" 2>/dev/null
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
# **And the selection volume is not the drawn volume** (user): close to a
# floor orb the player points over it, which is where the horizon sits,
# and the crosshair used to leave it. The room says when it answered up
# an orb's column rather than at its middle.
column=$(grep -ac "pointing at orb .*(up its column)" "$out/cli.log")
echo "the crosshair took an orb up its column $column times"
if [ "$column" -lt 1 ]; then
	echo "FAIL: pointing over a floor orb loses it"
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

# **And the camera goes to each match**: three pictures of three
# different places, so the arrows are not just relabelling a line
s1, d1 = mean_of("search1")
s2, d2 = mean_of("search2")
s3, d3 = mean_of("search3")
hop1 = sum(abs(p - q) for p, q in zip(d1, d2)) / float(len(d1))
hop2 = sum(abs(p - q) for p, q in zip(d2, d3)) / float(len(d2))
print("the search's arrows moved the camera by %.2f and %.2f of a level"
		% (hop1, hop2))
# Six, where the room's own drift over the same second and a half is
# three to five: a hop between two dark corners of the room moves fewer
# levels than one across the lit wall, and 7.8 was a real move read by
# an insensitive measure (2026-09-23)
search_ok = hop1 > 6.0 and hop2 > 6.0
print("PASS: the search walks its matches and the camera follows"
		if search_ok
		else "FAIL: the arrows do not move the camera between matches")

# **A screen on the stack takes the mouse**: with the pause dialog up,
# 220 pixels of mouse movement must not turn the camera, so the frame
# after it closes is the frame before it opened -- within the room's own
# drift, which is a few levels a second and is what the two seconds
# between these shots allow for.
# **The dialog's rows answer the mouse**: hovering one moves the
# selection, and clicking "back to the room" closes the dialog -- so the
# hovered picture differs from the plain one, and the clicked picture
# has no dialog in it
paused_plain, dpp = mean_of("paused")
hovered, dho = mean_of("pause-hover")
clicked, dcl = mean_of("pause-clicked")
hover_moved = sum(abs(p - q) for p, q in zip(dpp, dho)) / float(len(dpp))
closed = sum(abs(p - q) for p, q in zip(dpp, dcl)) / float(len(dpp))
print("hovering a row changed the dialog by %.2f, and clicking one "
		"changed the frame by %.2f" % (hover_moved, closed))
mouse_menu_ok = hover_moved > 0.05 and closed > 1.0
print("PASS: the dialog answers the mouse as well as the keyboard"
		if mouse_menu_ok
		else "FAIL: hovering or clicking a row does nothing")

before_pause, dbp = mean_of("prepause")
after_pause, dap = mean_of("unpaused")
turned = sum(abs(p - q) for p, q in zip(dbp, dap)) / float(len(dbp))
print("the mouse under the pause dialog moved the frame by %.2f of a "
		"level" % turned)
look_ok = turned < 8.0
print("PASS: a screen on the stack takes the mouse" if look_ok
		else "FAIL: the mouse still turns the camera under a menu")

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
		and pause_ok and look_ok and search_ok and mouse_menu_ok)
# The one line a machine reads, after the ones a person does
print("PASS: the room is what it says it is" if every
		else "FAIL: the room is not what it says it is")
sys.exit(0 if every else 1)
PY
