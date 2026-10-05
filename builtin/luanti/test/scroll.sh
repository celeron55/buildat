#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 24s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORMSPEC_SCROLL]: a formspec scroll is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# scroll[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/scroll.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/scroll"
mkdir -p "$out"
save=buildat_test_scroll
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/scroll.lua" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -P 29786 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(check_pgrep buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29786 -w 1280x720 -l 3 -c - < "$fifo" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log" &
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/srv.log" <<'PYIN'
import re, sys, time
log, fifo, srv = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(?: text "(.*)")?')
def scan():
    global seen
    write("delay 800", "event scan")
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan scan: done" in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and "scan scan:" in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)),
                                m.group(6) or ""))
            return els
        time.sleep(0.3)
    return None
def rows(els):
    # The scan walks the element tree, so a row clipped out of sight is
    # still listed; where it is is what says whether the box scrolled
    return {e[5]: e[2] for e in els or [] if e[5].startswith("row ")}
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
t0 = time.time()
while time.time() - t0 < 90:
    if "scroll: the form is shown" in open(srv, "rb").read().decode(
            "utf-8", "replace"):
        break
    time.sleep(1)
time.sleep(3)
write("screenshot " + sys.argv[1].replace("cli.log", "before.png"),
      "delay 400")
els = scan()
before = rows(els)
if not before:
    fail("no rows on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
if len(before) < 12:
    fail("only %d rows drawn" % len(before))
bar = None
for e in els:
    if e[0] == "BorderImage" and e[3] < 40 and e[4] > 100:
        bar = e
if not bar:
    fail("no scrollbar found")
for _ in range(2):
    write("mouse_pos %d %d" % (bar[1] + bar[3] // 2,
                               bar[2] + int(bar[4] * 0.75)),
          "delay 200", "mouse_click left", "delay 700")
# And the thumb dragged to the top of the trough, which is the third way
write("mouse_pos %d %d" % (bar[1] + bar[3] // 2, bar[2] + int(bar[4] * 0.9)),
      "delay 200", "mouse_down left", "delay 200")
for f in (0.6, 0.3, 0.05):
    write("mouse_pos %d %d" % (bar[1] + bar[3] // 2, bar[2] + int(bar[4] * f)),
          "delay 200")
write("mouse_up left", "delay 700")
# And the wheel over the container itself, which is the other way in:
# the box is the UIElement the rows are children of
boxes = [e for e in els if e[0] == "UIElement" and e[3] > 150 and e[4] > 80]
if boxes:
    b = boxes[0]
    write("mouse_pos %d %d" % (b[1] + b[3] // 2, b[2] + b[4] // 2),
          "delay 300", "mouse_wheel -1", "delay 900")
write("screenshot " + sys.argv[1].replace("cli.log", "after.png"),
      "delay 400")
els = scan()
after = rows(els)
print("row 1 at y=%s before, y=%s after" % (before.get("row 1"),
                                            after.get("row 1")))
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "scroll: fields bar=" in l]
print("the server received " + (", ".join(
        l.split("scroll: fields ")[-1] for l in got[-3:]) if got
        else "nothing"))
moved = (before.get("row 1") is not None and
         after.get("row 1") is not None and
         before["row 1"] - after["row 1"] > 20)
print("PASS: the container scrolled and the bar was sent"
      if moved and got else
      "FAIL: the rows moved %s and the server got %s" % (
          (before.get("row 1", 0) - after.get("row 1", 0)), bool(got)))
write("quit")
PYIN
status=$?
exec 3>&-
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
