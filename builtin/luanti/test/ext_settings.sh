#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# [EXT_SETTINGS]: the "Luanti client settings" tile, driven -- the render
# mode row cycled once and the file read back, the key editor's forward
# row rebound to Y and read back and put back, then Back to the grid. The
# settings file is put back after. Prints PASS or FAIL.
#
#   builtin/luanti/test/ext_settings.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_ext_settings.XXXXXX")
cd "$here/Build"
file=../user/luanti_client/settings.json
[ -f "$file" ] && cp "$file" "$tmp/settings.bak"
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; if [ -f "$tmp/settings.bak" ]; then cp "$tmp/settings.bak" "$file"; else rm -f "$file"; fi' EXIT
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -w 1280x720 -l 3 -c - < "$fifo" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$tmp/cli.log" &
cli=$!
exec 3> "$fifo"
python3 - "$tmp/cli.log" "$fifo" "$file" <<'PY'
import re, sys, time, json
log, fifo, path = sys.argv[1:4]
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
          "mouse_click left", "delay 500")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
time.sleep(8)
els = scan("a")
if not els: fail("no menu scan")
tiles = [e for e in els if "luanti client settings" in e[5].lower() and e[3] > 0]
if not tiles: fail("no settings tile; saw " + ", ".join(e[5] for e in els)[:300])
click(max(tiles, key=lambda e: e[2]))
els = scan("b")
row = els and find(els, "Render mode")
if not row: fail("no render mode row; saw " + ", ".join(e[5] for e in els or [])[:300])
before = row[5]
click(row)
els = scan("c")
row = els and find(els, "Render mode")
if not row or row[5] == before: fail("the mode did not cycle: %r -> %r" % (before, row and row[5]))
time.sleep(0.5)
data = json.load(open(path))
if data.get("mode") not in row[5]: fail("the file says %r, the row %r" % (data.get("mode"), row[5]))
# The key editor: the forward row rebound to Y, read back, and the
# default put back with Backspace
click(find(els, "Key bindings"))
els = scan("e")
row = els and find(els, "Walk forward")
if not row: fail("no key editor; saw " + ", ".join(e[5] for e in els or [])[:300])
click(row)
write("keypress Y", "delay 300")
els = scan("f")
row = els and find(els, "Walk forward")
if not row or not row[5].startswith("Y"): fail("the forward key did not rebind: %r" % (row and row[5]))
time.sleep(0.5)
keys = json.load(open(path)).get("keys", {})
if keys.get("forward") != "Y": fail("the file's keys say %r" % keys)
click(row)
write("keypress Backspace", "delay 300")
els = scan("g")
row = els and find(els, "Walk forward")
if not row or not row[5].startswith("W"): fail("the default did not come back: %r" % (row and row[5]))
# Escape is Back on both screens ([BOX_PLAYTEST_2] 6, 7): out of the
# editor to the settings screen, out of that to the grid
write("keypress Escape", "delay 300")
els = scan("h")
if not (els and find(els, "Render mode")): fail("Escape did not leave the editor for the settings screen")
write("keypress Escape", "delay 300")
els = scan("d")
if not (els and find(els, "Luanti client settings") and not find(els, "Render mode (next")):
    fail("not back on the grid")
print("PASS: mode %s in %s; forward rebound to Y and back" % (data["mode"], path))
write("quit")
PY
status=$?
exec 3>&-
exit $status
