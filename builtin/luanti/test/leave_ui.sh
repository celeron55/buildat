#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [MENU_CONTEXT]: leaving a menu-only game for the launcher, driven -- the
# VoxeLibre tile opens the world screen (a local server behind it), "< back
# to the launcher" returns to the grid with the client still up and the
# server gone, then the tile is opened a second time and the world screen
# comes again over a fresh connection. Prints PASS or FAIL.
#
#   builtin/luanti/test/leave_ui.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_leave_ui.XXXXXX")
cd "$here/Build"
# A server of an earlier run still shutting down would be read as this
# run's; wait for it
for i in $(seq 1 60); do pgrep -x buildat_server >/dev/null || break; sleep 1; done
pgrep -x buildat_server >/dev/null && { echo "FAIL: a buildat_server is running" >&2; exit 2; }
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
cli=""
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; exec 3>&- 2>/dev/null; kill "$cli" 2>/dev/null; pkill -INT -x buildat_server 2>/dev/null' EXIT
# **The grid by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no tiles. `-m __menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
bin/buildat -m __menu -w 1280x720 -l 3 -c - < "$fifo" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$tmp/cli.log" &
cli=$!
exec 3> "$fifo"
python3 - "$tmp/cli.log" "$fifo" <<'PY'
import re, sys, time, subprocess
log, fifo = sys.argv[1:3]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
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
def server_up():
    return subprocess.run(["pgrep", "-x", "buildat_server"], capture_output=True).returncode == 0
def open_worlds(tag):
    els = scan("grid" + tag)
    # The tile, not the selected entry's name in the logo row (the same
    # word, higher up): the lowest match
    tiles = [e for e in els or [] if "voxelibre" in e[5].lower() and e[3] > 0]
    b = tiles and max(tiles, key=lambda e: e[2])
    if not b: fail("no VoxeLibre tile (%s); saw %s" % (tag, ", ".join(e[5] for e in els or [])[:300]))
    click(b)
    for i in range(40):
        time.sleep(1)
        els = scan("w%s%d" % (tag, i))
        if els and find(els, "which world?"):
            return els
    fail("the world screen did not come (%s); saw %s" % (tag, ", ".join(e[5] for e in els or [])[:300]))
time.sleep(8)
els = open_worlds("a")
if not server_up(): fail("no local server behind the world screen")
b = find(els, "back to the launcher")
if not b: fail("no back row")
click(b)
time.sleep(2)
els = scan("back")
if not (els and find(els, "VoxeLibre") and not find(els, "which world?")):
    fail("not back on the grid; saw " + ", ".join(e[5] for e in els or [])[:300])
for i in range(40):
    if not server_up(): break
    time.sleep(1)
if server_up():
    pid = subprocess.run(["pgrep", "-x", "buildat_server"], capture_output=True, text=True).stdout.split()[0]
    bt = subprocess.run(["gdb", "-batch", "-p", pid, "-ex", "thread apply all bt 8"], capture_output=True, text=True).stdout
    open(log + ".server_stack", "w").write(bt)
    fail("the local server is still running after leaving; its stack is in " + log + ".server_stack")
els = open_worlds("b")
if not server_up(): fail("no local server the second time")
errors = [l for l in open(log, "rb").read().decode("utf-8", "replace").splitlines()
          if " E " in l[:40] or "Exception" in l]
if errors: fail("error lines: " + errors[0][:200])
print("PASS")
write("quit")
PY
status=$?
exec 3>&-
exit $status
