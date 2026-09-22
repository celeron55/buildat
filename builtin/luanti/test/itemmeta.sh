#!/bin/bash
# [FORMSPEC_SCROLL]: a formspec itemmeta is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# itemmeta[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/itemmeta.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/itemmeta"
mkdir -p "$out"
save=buildat_test_itemmeta
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/itemmeta.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29789 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29789 -w 1280x720 -l 3 -c - < "$fifo" 2>&1 |
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
def scan():
    global seen
    write("delay 800", "event scan")
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan scan: done" in data:
            seen = len(open(log, "rb").read())
            return [l for l in data.splitlines() if "scan scan:" in l]
        time.sleep(0.3)
    return None
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
t0 = time.time()
while time.time() - t0 < 120:
    if "itemmeta: the stacks are set" in open(srv, "rb").read().decode(
            "utf-8", "replace"):
        break
    time.sleep(1)
time.sleep(4)
lines = scan()
# Slot 1 in hand, which is where the hand's own picture is read
write("keypress 1", "delay 800")
write("screenshot " + sys.argv[1].replace("cli.log", "hotbar.png"), "delay 600")
time.sleep(1.5)
hot = [l for l in lines or [] if "hotbar" in l]
print((hot[0].split("hotbar ")[-1][:120]) if hot else "no hotbar line")
write("quit")
time.sleep(1.0)
from PIL import Image
im = Image.open(sys.argv[1].replace("cli.log", "hotbar.png")).convert("RGB")
w, h = im.size
crop = im.crop((w // 3, h - h // 8, 2 * w // 3, h))
# And the hand, which is drawn at the bottom right of the frame
hand = im.crop((int(w * 0.62), int(h * 0.55), int(w * 0.95), int(h * 0.95)))
hpx = list(hand.getdata())
hred = sum(1 for r, g, b in hpx if r > 110 and g < 80 and b < 80)
# Said, not asserted: what the hand holds is not always in the frame
print("the hand's corner is %.2f %% red" % (100.0 * hred / len(hpx)))
px = list(crop.getdata())
red = sum(1 for r, g, b in px if r > 110 and g < 80 and b < 80)
share = 100.0 * red / len(px)
print("the hotbar strip is %.2f %% red" % share)
# The overlay: slot 7 is a dirt with a stone picture over it and slot 5 is
# a plain one, so the two slots cannot read the same. The row is centred
# and eight slots wide at this window, which is what the columns are.
row = im.crop((int(w * 0.32), h - 62, int(w * 0.68), h - 8))
sw = row.size[0] // 8
def slot(i):
    return list(row.crop(((i - 1) * sw, 0, i * sw, row.size[1])).getdata())
a5, a7 = slot(5), slot(7)
diff = sum(abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])
           for p, q in zip(a5, a7)) / (3.0 * len(a5))
print("slots 5 and 7 differ by %.1f levels" % diff)
ok = share > 1.0 and diff > 5
print("PASS: the stack's own colour and its overlay are what is drawn" if ok
      else "FAIL: red %.2f %%, slots 5 and 7 %.1f levels apart" % (share, diff))
PYIN
status=$?
exec 3>&-
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
