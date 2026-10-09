#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 16s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [KEY_BINDINGS]: the editor screen, driven -- the launcher's menu, its
# "Luanti settings", "Key bindings...", the forward row picked and U
# pressed, the row then says U; "Defaults" puts W back. Read through the
# UI scan, as menu_drive.py reads screens. Prints PASS or FAIL; the
# settings.json is put back after.
#
#   builtin/luanti/test/keys_ui.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "/tmp/buildat_keys_ui.XXXXXX")
cd "$here/Build"
settings=$BUILDAT_USER_PATH/shared/vanilla/settings.json
mkdir -p $BUILDAT_USER_PATH/shared/vanilla
[ -f "$settings" ] && cp "$settings" "$tmp/settings.json.bak"
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
cli=""
trap 'exec 3>&- 2>/dev/null; kill "$cli" 2>/dev/null; check_pkill -INT buildat_server 2>/dev/null;
	if [ -f "$tmp/settings.json.bak" ]; then cp "$tmp/settings.json.bak" "$settings"; else rm -f "$settings"; fi;
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"' EXIT
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$tmp/cli.log" "$fifo" <<'PY'
import re, sys, time
log, fifo = sys.argv[1], sys.argv[2]
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
    while time.time() - t0 < 30:
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
          "mouse_click left", "delay 300")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
time.sleep(8)
write("text luanti sett")
els = scan("a")
if not els: fail("no menu scan")
b = find(els, "Luanti settings")
if not b: fail("no settings button; saw " + ", ".join(e[5] for e in els)[:300])
click(b)
# The game's server starts behind the row: scanned until its screen is up
b = None
for i in range(20):
    els = scan("b%d" % i)
    b = els and find(els, "Key bindings")
    if b: break
    time.sleep(2)
if not b: fail("no Key bindings row; saw " + ", ".join(e[5] for e in els or [])[:200])
click(b)
els = scan("c")
row = els and find(els, "Walk forward")
if not row: fail("no forward row")
click(row)
els = scan("d")
if not (els and find(els, "Press a key")): fail("the row did not listen")
write("keypress U", "delay 500")
els = scan("e")
row = els and find(els, "Walk forward")
if not row or not row[5].startswith("U"): fail("forward is not U: " + str(row and row[5]))
d = find(els, "Defaults")
if not d: fail("no Defaults")
click(d)
els = scan("f")
row = els and find(els, "Walk forward")
if not row or not row[5].startswith("W"): fail("Defaults did not put W back: " + str(row and row[5]))
print("PASS")
write("quit")
PY
status=$?
exec 3>&-
exit $status
