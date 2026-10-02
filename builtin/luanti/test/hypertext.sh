#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 20s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORMSPEC_SCROLL]: a formspec hypertext is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# hypertext[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/hypertext.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/hypertext"
mkdir -p "$out"
save=buildat_test_hypertext
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/hypertext.lua" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D ../user -P 29787 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29787 -w 1280x720 -l 3 -c - < "$fifo" 2>&1 |
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
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
t0 = time.time()
while time.time() - t0 < 90:
    if "hypertext: the form is shown" in open(srv, "rb").read().decode(
            "utf-8", "replace"):
        break
    time.sleep(1)
time.sleep(3)
els = scan()
write("screenshot " + sys.argv[1].replace("cli.log", "form.png"), "delay 400")
body = [e for e in els or [] if "Some words in it" in e[5]]
if not body:
    fail("the hypertext is not on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
if "<" in body[0][5]:
    fail("the tags are still in the text: %r" % body[0][5])
act = None
for e in els or []:
    if e[5] == "press here":
        act = e
if not act:
    fail("no action button; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
write("mouse_pos %d %d" % (act[1] + act[3] // 2, act[2] + act[4] // 2),
      "delay 200", "mouse_click left", "delay 800")
time.sleep(1.5)
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "hypertext: fields doc=" in l]
if not got:
    fail("the server received no fields")
last = got[-1].split("hypertext: fields ")[-1]
print("the text reads %r" % body[0][5][:60])
print("the server received " + last)
print("PASS: the action says which one it was" if last == "doc=action:here"
      else "FAIL: the server received " + last)
write("quit")
PYIN
status=$?
exec 3>&-
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
