#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 150s (this desk, 2026-09-27; local/run_all/costs corrects it per machine)
# [MENU_LEAVE]: **leaving a world**, which nothing drove before -- leave_ui.sh
# leaves the world *screen* for the menu, and everything between picking a
# world and coming back out of it was untested. The launcher's menu, the
# VoxeLibre row, a world played for ten seconds, Escape, and "Leave the
# game" from the game's own pause menu. What it holds:
#
#   * the played world has none of the launcher over it -- the "Starting
#     <game>..." screen used to be left on the stack, drawn in the middle
#     of the world;
#   * Escape pauses the game and does not stop the server -- that screen's
#     Escape was still live under it and cancelled the start;
#   * after the leave the client has let go of the game's picture: the
#     grid used to come up over the last frame of the world, still there
#     to the pixel two seconds later, because the render-scale image the
#     client draws a game through is the client's own and the leave did
#     not drop it.
#
# Prints PASS or FAIL; the pictures are under local/leave_world/.
#
#   builtin/luanti/test/leave_world.sh
#
# covers: extensions/launch_menu/init.lua src/client/app.cpp
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/lib.sh"
out="$here/local/leave_world"; mkdir -p "$out"; rm -f "$out"/*.png
tmp=$(mktemp -d "/tmp/buildat_leave_world.XXXXXX")
cd "$here/Build"
for i in $(seq 1 60); do check_pgrep buildat_server >/dev/null || break; sleep 1; done
if check_pgrep buildat_server >/dev/null; then
	echo "SKIP: a buildat_server is already running" >&2; exit "$SKIP"
fi
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
cli=""
trap 'exec 3>&- 2>/dev/null; kill "$cli" 2>/dev/null; check_pkill -INT buildat_server 2>/dev/null; rm -rf "$tmp"' EXIT
# The menu by name, not by preference ([MENU_FALLBACK]); leave_ui.sh says why
bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" \
	> "$out/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out" <<'PY'
import re, subprocess, sys, time
log, fifo, out = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
# What the last scan's own lines were, whoever answered it: uistack's
# ("menu \"ui_stack...") or the world's ("keys forward=...")
last_scan = ""
def scan(label, wait=40):
    # The resolution first: the world's own scan (vanilla's scan.lua) takes
    # "<res> <label>" and answers to the label "scan" without it, while
    # uistack's takes either -- so a scan of a game's screen needs it
    global seen, last_scan
    write("delay 800", "event scan 8 " + label)
    t0 = time.time()
    while time.time() - t0 < wait:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan %s: done" % label in data:
            seen = len(open(log, "rb").read())
            last_scan = data
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and ("scan %s:" % label) in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)), m.group(6)))
            return els
        time.sleep(0.3)
    return None
def find(els, word):
    for e in els or []:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left", "delay 600")
def fail(why):
    print("FAIL: " + why)
    write("quit")
    sys.exit(1)
def server_up():
    return subprocess.run(["bash", "-c", "check_pgrep buildat_server"],
                          capture_output=True).returncode == 0
def waitlog(text, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        if text in open(log, "rb").read().decode("utf-8", "replace"):
            return True
        time.sleep(0.5)
    return False
def logtext():
    return open(log, "rb").read().decode("utf-8", "replace")

time.sleep(8)
write("text voxel")
els = scan("grid")
tiles = [e for e in els or [] if "voxelibre" in e[5].lower() and e[3] > 0]
tile = tiles and max(tiles, key=lambda e: e[2])
if not tile:
    fail("no VoxeLibre row; saw " + ", ".join(e[5] for e in els or [])[:300])
click(tile)
for i in range(40):
    time.sleep(1)
    els = scan("world%d" % i)
    if find(els, "which world?"):
        break
else:
    fail("no world screen; saw " + ", ".join(e[5] for e in els or [])[:300])
# A world on the left: the saves are the rows under the filter box
rows = [e for e in els if e[2] > 160 and e[1] < 500 and e[3] > 40 and e[4] > 10
        and e[5].strip() and "which world" not in e[5].lower()
        and "back to the launcher" not in e[5].lower()
        and "new world" not in e[5].lower() and "import" not in e[5].lower()
        and "filter" not in e[5].lower()]
if not rows:
    fail("no world rows; saw " + ", ".join(e[5] for e in els)[:300])
# The day's own test world if it is there, else the first row
pick = find(rows, "buildat_test_fuzz_5") or min(rows, key=lambda e: e[2])
click(pick)
els = scan("picked")
play = None
for e in els or []:
    if e[5].strip() == "Play" and e[3] > 0:
        play = e
if not play:
    fail("no Play row; saw " + ", ".join(e[5] for e in els or [])[:300])
click(play)
if not waitlog("the server put the player", 240):
    fail("the world never came up; see " + log)
time.sleep(10)
write("screenshot %s/in_world.png" % out, "delay 1500")

# (1) The world is the player's own screen: the launcher's start screen
# used to be left on the stack, and a scan then answers with *its* name
# instead of the world's
els = scan("world")
if find(els, "Starting "):
    fail("the launcher's start screen is still over the world")
if 'menu "ui_stack' in last_scan:
    fail("a launcher screen is on top of the played world: " +
         last_scan.split('menu "', 1)[1].split('"', 1)[0])
if "keys forward=" not in last_scan:
    fail("the world's own scan did not answer; the stack's top is not the "
         "placeholder a game runs under")

# (2) Escape pauses the game rather than cancelling the start
write("keypress Escape", "delay 1500")
write("screenshot %s/paused.png" % out, "delay 1000")
els = scan("pause")
leave = find(els, "Leave the game")
if not leave:
    fail("no pause menu after Escape; saw " +
         ", ".join(e[5] for e in els or [] if e[5].strip())[:300])
if not server_up():
    fail("Escape stopped the local server instead of pausing the game")

# (3) And the leave lets go of the game's picture
click(leave)
time.sleep(4)
write("screenshot %s/after_leave.png" % out, "delay 1500")
time.sleep(3)
els = scan("back")
if not find(els, "Browse"):
    fail("not back in the menu; saw " +
         ", ".join(e[5] for e in els or [] if e[5].strip())[:300])
left = [l for l in logtext().splitlines() if "what is left after" in l]
if not left:
    fail("the client said nothing about what the leave left")
print("the client says: " + left[-1].split(": ", 1)[-1][:200])
if "the preferred image is still here" in left[-1]:
    fail("the last frame of the world is still on the screen under the menu")
print("PASS: the world came up clean, Escape paused it, and the leave took "
      "the game's picture with it")
write("quit")
PY
status=$?
exec 3>&-
# The pictures are worth keeping whatever happened
exit $status
# vim: set noet ts=4 sw=4:
