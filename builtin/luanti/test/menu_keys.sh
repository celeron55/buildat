#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 20s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [MENU_KEYS]: the launch menu's keyboard. The client is started with no
# server, because the launch menu is what it shows when it has nothing to
# connect to.
#
# Two halves, and the second is why the first broke once: menu navigation
# stands down while a text field has the focus, and reading that as "the
# focus exists" turns the keyboard off everywhere, because the UI stack
# gives its own root the focus as it pushes it.
#
#   1. On the launch menu, Down moves the selection.
#   2. On "Join a Buildat server", which opens with the address field focused,
#      Down moves nothing in the server list beside it: since the user's
#      "rows by Up and Down" (2026-10-07) it goes to the Port field, and
#      the list is what must stay.
#
# The pictures are compared by how many pixels differ, because a focused
# field blinks its caret and that is not the selection moving.
#
# **The screen is found by its text, not by a count of keystrokes**: it was
# Down-then-Return until 2026-09-22, which on the launch menu lands on
# whatever tile is under the first one -- a game, whose saves list answers
# Down by moving its selection, and the check failed on the wrong screen.
#
#   KEEP_TMP=1 builtin/luanti/test/menu_keys.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_menu_keys.XXXXXX")
# KEEP_TMP keeps the four pictures: what a failure here is about is what
# moved between two of them, and the answer is only in the pictures.
trap 'if [ -n "${KEEP_TMP:-}" ]; then echo "kept $tmp" >&2; else rm -rf "$tmp"; fi' EXIT
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "a client is already running" >&2; exit 2
fi
fifo="$tmp/cmds.fifo"; mkfifo "$fifo"
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" > "$tmp/cli.log" 2>&1 &
exec 3> "$fifo"
python3 - "$tmp" <<'PY'
import os, re, sys, time
from PIL import Image, ImageChops
d = sys.argv[1]
log = os.path.join(d, "cli.log")
w = open(os.path.join(d, "cmds.fifo"), "w")
seen = 0
n = 0
def write(*cmds):
	for c in cmds:
		w.write(c + "\n")
	w.flush()
UI = re.compile(r'ui\s+(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)'
		r'(?: text "(.*?)")?(?: image "(.*?)")?(?: (hidden))?$')
def scan():
	global seen, n
	n += 1
	label = "m%d" % n
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
							int(m.group(4)), int(m.group(5)), m.group(6) or ""))
			return els
		time.sleep(0.3)
	return None
def shot(name):
	write("screenshot %s/%s.png" % (d, name), "delay 900")
	time.sleep(1.2)
def differing(one, two, right=None):
	a = Image.open(os.path.join(d, one + ".png")).convert("RGB")
	b = Image.open(os.path.join(d, two + ".png")).convert("RGB")
	if right:
		a, b = a.crop((0, 0, right, a.size[1])), b.crop((0, 0, right, b.size[1]))
	diff = ImageChops.difference(a, b)
	return sum(1 for p in diff.getdata() if p != (0, 0, 0))

write("delay 6000")
time.sleep(7)
# 1. The menu answers the arrows
shot("a")
write("keypress DOWN", "delay 800")
time.sleep(1.2)
shot("b")
# 2. The connect screen, found by its own text
write("text join a bu", "delay 800")
els = scan()
entry = None
for e in els or []:
	if "join a buildat server" in e[5].lower() and e[3] > 0:
		entry = e
if entry is None:
	print("FAIL: no \"Join a Buildat server\" in the menu; saw " +
			", ".join("%r" % x[5] for x in els or [])[:200])
	write("quit"); sys.exit(1)
write("mouse_pos %d %d" % (entry[1] + entry[3] // 2, entry[2] + entry[4] // 2),
		"delay 300", "mouse_click left", "delay 1800")
time.sleep(2.5)
shot("c")
# The fields' column: the list is left of it
fields = [e for e in scan() or [] if e[0] == "LineEdit" and e[3] > 0]
left_of = min(e[1] for e in fields) - 8 if fields else None
write("keypress DOWN", "delay 800")
time.sleep(1.2)
shot("d")
write("delay 300", "quit")

CARET = 400
moved = differing("a", "b")
still = differing("c", "d", left_of)
ok = True
if moved <= CARET:
	print("FAIL: Down moved nothing on the menu (%d pixels)" % moved)
	ok = False
else:
	print("ok: Down moves the selection (%d pixels)" % moved)
if not left_of:
	print("FAIL: no fields on the connect screen")
	ok = False
elif still > CARET:
	print("FAIL: Down moved the server list while the address field had the "
			"focus (%d pixels)" % still)
	ok = False
else:
	print("ok: the list stays while a field has the focus (%d pixels)" % still)
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
status=$?
exec 3>&-
sleep 2
check_pkill buildat 2>/dev/null
exit $status
