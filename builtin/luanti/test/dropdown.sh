#!/bin/bash
# [FORMSPEC_SCROLL]: a formspec dropdown is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# dropdown[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/dropdown.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/dropdown"
mkdir -p "$out"
save=buildat_test_dropdown
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/dropdown.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29785 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29785 -w 1280x720 -l 3 -c - < "$fifo" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log" &
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/srv.log" <<'PY'
import re, sys, time
log, fifo, srv = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text "(.*)"')
def scan(label):
    # vanilla's scan names its own lines "scan scan:" whatever the event's
    # label is; the label here is only what the command carries
    global seen
    label = "scan"
    write("delay 800", "event scan")
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
def find(els, text):
    for e in els or []:
        if e[5] == text and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 200",
          "mouse_click left", "delay 600")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# The form comes up three seconds after the join
t0 = time.time()
while time.time() - t0 < 90:
    if "dropdown: the form is shown" in open(srv, "rb").read().decode(
            "utf-8", "replace"):
        break
    time.sleep(1)
time.sleep(3)
els = scan("a")
box = find(els, "alpha")
if not box:
    fail("no dropdown on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
click(box)
els = scan("b")
item = find(els, "gamma")
if not item:
    fail("the list did not open; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
click(item)
time.sleep(1.5)
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "dropdown: fields pick=" in l]
if not got:
    fail("the server received no fields")
last = got[-1].split("dropdown: fields ")[-1]
print("the server received " + last)
print("PASS: the picked item is what was sent" if last == "pick=gamma"
      else "FAIL: the server received " + last)
write("quit")
PY
status=$?
exec 3>&-
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
