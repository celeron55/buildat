#!/bin/bash
# extensions/launch_world: **the room survives losing the GL context**
# ([BOX_PLAYTEST_3] (1)). A change of screen mode destroys the context
# and Urho3D can only bring back a texture it loaded from a file -- the
# room's voxel atlas, its marks, its ornament and its reflection probe
# are all written rather than loaded, and without the restoring in
# world.lua the world comes back black (measured: the room read 1.55 of
# a level against 47.46 before the reset).
#
#   extensions/launch_world/device_reset.sh
#
# **It does not press F11**, which is what a player does to provoke
# this: F11 takes the whole screen and the keyboard focus away from
# whoever is using the desk (the user, 2026-09-22). Changing
# multisampling goes down the same path -- Graphics::SetMode closes the
# window and the GL context for anything but a vsync-only change -- and
# the room's own desk is where that setting lives. So the reset here is
# the reset F11 makes, taken from a window that stays where it is.
#
# tier: full
# cost: 75s
# covers: extensions/launch_world/world.lua
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/builtin/luanti/test/lib.sh"
out="$here/local/options_for_LAUNCH_WORLD/device_reset"; mkdir -p "$out/user"
rm -f "$out"/*.png
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit "$SKIP"
fi
# The desk's rows in order: render scale, vsync, max fps, multisampling.
# Three downs from the top is the one that recreates the context.
{ echo "wait_log_any 60000 the room hums"
	echo "delay 2500"
	echo "screenshot $out/before.png"
	echo "wait_log 20000 Wrote screenshot $out/before.png"
	echo "keypress Return"
	echo "delay 2500"
	echo "keypress Down"; echo "keypress Down"; echo "keypress Down"
	echo "delay 400"
	echo "keypress Right"
	echo "delay 3000"
	# And back, so the two pictures are of the same mode and the only
	# difference left is what the reset took
	echo "keypress Left"
	echo "delay 3000"
	echo "keypress Escape"
	echo "delay 2500"
	echo "screenshot $out/after.png"
	echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
run_client 40 "$out/cli.log" timeout 180 bin/buildat -m launch_world \
	-D "$out/user" -w 1280x720 -l 3 -c @"$out/cmds.txt" > /dev/null 2>&1
sed -i -e 's/\x1b\[[0-9;]*m//g' "$out/cli.log"
restored=$(grep -ac "screen mode changed" "$out/cli.log")
python3 - "$out" "$restored" <<'PY'
import sys
from PIL import Image
out, restored = sys.argv[1], int(sys.argv[2])

def read(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("RGB")
	w, h = im.size
	# The world, not the HUD: the room fills the frame, but the rows of
	# help text along the bottom survive a reset whatever happens to it
	px = list(im.crop((0, 0, w, int(h * 0.6))).getdata())
	return sum(sum(p) for p in px) / (3.0 * len(px))

a, b = read("before"), read("after")
print("the room reads %.2f before the reset and %.2f after; the room "
		"said it restored itself %d times" % (a, b, restored))
if restored < 1:
	print("FAIL: the screen mode changed and the room never noticed")
	sys.exit(1)
# **The room, not a picture of it**: the two shots are seconds apart and
# the room is never still, so this is "the light is still there" and not
# a comparison. Black is what the fault looks like -- three per cent of
# the level the room had -- and a fifth is far below any drift.
if b < a * 0.8:
	print("FAIL: the room lost its light when the GL context went")
	sys.exit(1)
print("PASS: the room comes back from a device reset with its light")
PY
rc=$?
exit "$rc"
# vim: set noet ts=4 sw=4:
