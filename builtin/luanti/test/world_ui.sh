#!/bin/bash
# [WORLD_LIST]: the world screen, driven -- the launcher's VoxeLibre tile,
# the row SAVE (buildat_test_sprites unless given; a test save of this
# tree's own, a VoxeLibre one) picked, its
# glance in the panel, "Creative mode" ticked and the save's world.mt
# read, then unticked. Read through the UI scan, as menu_drive.py reads
# screens. Prints PASS or FAIL; the shot is local/world_ui/world.png.
#
#   builtin/luanti/test/world_ui.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
out="$here/local/world_ui"; mkdir -p "$out"
cd "$here/Build"
SAVE="${SAVE:-buildat_test_sprites}"
save=../user/games/vanilla/saves/$SAVE
[ -d "$save" ] || { echo "FAIL: no save $SAVE; a drive or fixture run makes one" >&2; exit 1; }
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
cli=""
trap 'exec 3>&- 2>/dev/null; kill "$cli" 2>/dev/null; pkill -INT -x buildat_server 2>/dev/null' EXIT
bin/buildat -w 1280x720 -l 3 -c - < "$fifo" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$tmp/cli.log" &
cli=$!
exec 3> "$fifo"
python3 - "$tmp/cli.log" "$fifo" "$save/luanti/world.mt" "$out/world.png" "$SAVE" <<'PY'
import re, sys, time
log, fifo, world_mt, shot, SAVE = sys.argv[1:6]
out = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        out.write(c + "\n")
    out.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
def scan(label):
    global seen
    write("delay 800", "event scan " + label)
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan %s: done" % label in data:
            seen = len(open(log, "rb").read())
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
    for e in els:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left", "delay 600")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
def flag(key):
    try:
        for line in open(world_mt):
            if line.split("=")[0].strip() == key:
                return line.split("=", 1)[1].strip()
    except IOError:
        pass
    return None
time.sleep(8)
els = scan("a")
if not els: fail("no menu scan")
b = find(els, "VoxeLibre")
if not b: fail("no VoxeLibre tile; saw " + ", ".join(e[5] for e in els)[:300])
click(b)
time.sleep(3)
els = scan("b")
edit = els and [e for e in els if e[0] == "LineEdit" and e[3] > 0]
if not edit: fail("no filter field")
click(edit[0])
# Enter would also reach the menu's keyboard walk once the screen is redrawn
# under it; a click on the title ends the edit the same way (TextFinished)
write("text " + SAVE, "delay 200", "keypress Return", "delay 1000")
els = scan("b2")
# The row, not the filter field that now says the same
# The row's text is below the filter field, which now says the same
fy = edit[0][2]
row = els and [e for e in els if e[0] == "Text" and e[5] == SAVE and e[2] > fy + 20]
row = row and row[0]
if not row: fail("no row " + SAVE + "; saw " + ", ".join(e[5] for e in els or [])[:400])
click(row)
els = scan("c")
if not (els and find(els, "explored")): fail("no glance in the panel; saw " + ", ".join(e[5] for e in els or [])[:400])
write("screenshot " + shot, "delay 500")
before = flag("creative_mode")
c = find(els, "Creative mode")
if not c: fail("no Creative mode row")
click(c)
els = scan("d")
c = els and find(els, "Creative mode")
if not c or not c[5].startswith("[x]"): fail("the tick did not show: " + str(c and c[5]))
time.sleep(0.5)
now = flag("creative_mode")
if now != "true": fail("world.mt says creative_mode %r after the tick" % now)
click(c)
els = scan("e")
c = els and find(els, "Creative mode")
if not c or not c[5].startswith("[ ]"): fail("the untick did not show: " + str(c and c[5]))
time.sleep(0.5)
if flag("creative_mode") != "false": fail("world.mt not put back")
print("PASS (creative_mode was %s before; false now)" % before)
write("quit")
PY
status=$?
exec 3>&-
exit $status
