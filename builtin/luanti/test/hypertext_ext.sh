#!/bin/bash
# [FORMSPEC_SCROLL]: the same hypertext check as hypertext.sh, for
# extensions/luanti_client against official Luanti's server: the text with
# its tags taken out and its <action> clicked.
#
#   builtin/luanti/test/hypertext_ext.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/hypertext_ext"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if pgrep -x buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "a client or a Luanti server is already running" >&2; exit 2
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/hypertext"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = hypertext
creative_mode = false
server_announce = false
MT
cp "$me/hypertext.lua" "$work/worldmods/hypertext/init.lua"
printf 'name = hypertext\n' > "$work/worldmods/hypertext/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
for i in $(seq 1 300); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	sleep 1
done
sleep 3
srv=$(pgrep -x luanti-refshots | head -1)
[ -n "$srv" ] || { echo "the Luanti server did not come up" >&2; exit 1; }
trap 'kill "$srv" 2>/dev/null' EXIT
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=drop \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 -c - \
	< "$fifo" > "$out/cli.log" 2>&1 &
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/luanti_srv.log" <<'PYIN'
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
    write("delay 800", "event scan a")
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan a: done" in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and "scan a:" in line:
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
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
