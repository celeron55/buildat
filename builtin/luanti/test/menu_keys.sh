#!/bin/bash
# Does the client's own menu answer the keyboard?
#
#   builtin/luanti/test/menu_keys.sh
#
# Run from anywhere; it needs Build/bin/buildat and nothing else -- no
# server, because the launch menu is what the client shows when it is
# started with nothing to connect to.
#
# Two halves, and the second is why the first broke once: menu navigation
# stands down while a text field has the focus, and reading that as "the
# focus exists" turns the keyboard off everywhere, because the UI stack
# gives its own root the focus as it pushes it.
#
#   1. On the first screen, Down moves the selection.
#   2. On "Connect to server", which opens with the address field focused,
#      Down moves nothing: the field owns the keys that are text.
#
# The pictures are compared by how many pixels differ, because a focused
# field blinks its caret and that is not the selection moving.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$here/Build"
{ echo "delay 6000"; echo "screenshot $tmp/a.png"; echo "delay 500"
	echo "keypress DOWN"; echo "delay 800"; echo "screenshot $tmp/b.png"
	# Into the second screen, which is the one that focuses a field
	echo "delay 500"; echo "keypress RETURN"; echo "delay 1500"
	echo "screenshot $tmp/c.png"; echo "delay 500"
	echo "keypress DOWN"; echo "delay 800"; echo "screenshot $tmp/d.png"
	echo "delay 500"; echo "quit"; } > "$tmp/cmds.txt"
bin/buildat -w 1280x720 -l 3 -c @"$tmp/cmds.txt" > "$tmp/cli.log" 2>&1
python3 - "$tmp" <<'PY'
import os, sys
from PIL import Image, ImageChops
d = sys.argv[1]

def differing(one, two):
	a = os.path.join(d, one + ".png")
	b = os.path.join(d, two + ".png")
	for p in (a, b):
		if not os.path.exists(p):
			print("no picture at " + p)
			sys.exit(1)
	diff = ImageChops.difference(Image.open(a).convert("RGB"),
			Image.open(b).convert("RGB"))
	return sum(1 for p in diff.getdata() if p != (0, 0, 0))

# A caret blinking is tens of pixels; a selection moving is thousands
CARET = 400
moved = differing("a", "b")
still = differing("c", "d")
status = 0
if moved <= CARET:
	print("FAIL: Down moved nothing on the first screen (%d pixels)" % moved)
	status = 1
else:
	print("ok: Down moves the selection (%d pixels)" % moved)
if still > CARET:
	print("FAIL: Down moved the selection while the address field had the "
			"focus (%d pixels)" % still)
	status = 1
else:
	print("ok: the focused field keeps the arrows (%d pixels)" % still)
sys.exit(status)
PY
