#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# [BOX_PLAYTEST_2] (12): the connect runs on a worker, so the frame keeps
# drawing while it waits. The client is pointed at a blackholed address
# (192.0.2.1, TEST-NET-1: the SYNs go nowhere and the connect sits for its
# five seconds); the screen's own counter must move while it does, and the
# failure must come as an error afterwards.
#
#   builtin/luanti/test/connect_async.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/connect_async"; mkdir -p "$out"
if pgrep -x buildat >/dev/null; then
	echo "a client is already running" >&2; exit 2
fi
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
( cd "$here/Build" && bin/buildat -w 1280x720 -l 3 -c - < "$fifo" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log" ) &
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" <<'PY'
import re, sys, time
log, fifo = sys.argv[1:3]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'ui\s+(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)'
                r'(?: text "(.*?)")?(?: image "(.*?)")?(?: (hidden))?$')
n = 0
def scan():
    global seen, n
    n += 1
    label = "c%d" % n
    write("event scan 8 %s" % label)
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan %s: done" % label in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and ("scan %s:" % label) in line and m.group(8) is None:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)),
                                m.group(6) or ""))
            return els
        time.sleep(0.3)
    return None
def find(els, word):
    for e in els or []:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2),
          "delay 200", "mouse_click left", "delay 600")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
time.sleep(6)
els = scan()
e = find(els, "Connect to server")
if not e:
    fail("no connect entry on the first screen; saw " +
         ", ".join("%r" % x[5] for x in els or [])[:300])
click(e)
els = scan()
edits = [x for x in els if x[0] == "LineEdit" and x[3] > 0]
if len(edits) < 2:
    fail("the connect screen has %d fields" % len(edits))
click(edits[0])
write("keypress End", *(["keypress Backspace"] * 40))
write("text 192.0.2.1", "delay 200")
e = find(els, "Connect")
if not e:
    fail("no Connect button")
click(e)
# Two readings while the connect runs: the counter has to have moved, which
# is only true if the frame loop ran at all
def counter():
    els = scan()
    t = find(els, "Connecting to")
    return t[5] if t else None
first = counter()
time.sleep(2.5)
second = counter()
print("the screen said %r and then %r" % (first, second))
if first is None or second is None:
    fail("no connecting screen: the connect blocked the frame")
def secs(text):
    m = re.search(r"(\d+) s$", text)
    return int(m.group(1)) if m else -1
moved = secs(second) > secs(first)
# And the failure arrives once the five seconds are up
t0 = time.time()
shown = None
while time.time() - t0 < 30:
    els = scan()
    if find(els, "Connect failed") or find(els, "failed"):
        shown = "an error"
        break
    time.sleep(1)
print("after the timeout: %s" % (shown or "nothing"))
print("PASS: the counter moved while the connect ran and it failed after"
      if moved and shown else
      "FAIL: counter %r -> %r, error %r" % (first, second, shown))
write("quit")
sys.exit(0 if (moved and shown) else 1)
PY
status=$?
exec 3>&-
sleep 2
pkill -x buildat 2>/dev/null
exit $status
