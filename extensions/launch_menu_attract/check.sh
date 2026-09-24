#!/bin/bash
# tier: quick
# [TWO_AUDIENCES]' third option: the menu stacked over the room in
# attract mode. What is asserted is that both halves came up, that the
# *menu* has the input while the room is behind it, and that the room
# is standing down rather than merely hidden -- it must take no key.
#
#   extensions/launch_menu_attract/check.sh
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/launch_menu_attract"; mkdir -p "$out"
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
# Escape would quit the menu; Right and Return move and pick, which is
# the menu's own keyboard. "Engine settings" is the first tile and opens
# a screen of the menu's, so picking it proves the input went there.
{ echo "delay 5000"
	echo "keypress Return"
	echo "delay 1200"
	echo "screenshot $out/menu-over-room.png"
	echo "delay 400"
	echo "quit"; } > "$out/cmds.txt"
bin/buildat -m launch_menu_attract -D ../user -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
if grep -aq "Crash: SIG" "$out/cli.log"; then
	echo "FAIL: the client crashed --" \
			"$(grep -a "Crash: SIG" "$out/cli.log" | head -1)"
	exit 1
fi
room=$(grep -ac "launch_w.*: room: a backdrop" "$out/cli.log")
menu=$(grep -ac "launch_m.*: the menu, over the room" "$out/cli.log")
picked=$(grep -ac "Menu entry: " "$out/cli.log")
# The room's own answer to a key: it logs a mode change for Tab and a
# pause for Escape, and a backdrop must do neither
roomkeys=$(grep -acE "launch_w.*: (mode:|pause:)" "$out/cli.log")
echo "the room came up as a backdrop $room, the menu over it $menu," \
		"the menu took $picked pick(s), the room answered $roomkeys keys"
if [ "$room" -lt 1 ] || [ "$menu" -lt 1 ]; then
	echo "FAIL: the composition did not come up"
	exit 1
fi
if [ "$picked" -lt 1 ]; then
	echo "FAIL: the menu over the room does not take the keyboard"
	exit 1
fi
# The room logs one "mode:" line at boot, before it is told it is a
# backdrop; anything past that is the room answering input it should not
# be getting
if [ "$roomkeys" -gt 1 ]; then
	echo "FAIL: the room answered $roomkeys keys while it was a backdrop"
	exit 1
fi
# **And a game launched from the composition can be left** -- which is
# not free, and nearly was not there: the composing extension's own
# module has none of the three the client asks a launcher for (it boots
# two others and that is all), so handing it over as the interface
# would wipe what the menu gave and leave a client with no server and
# no menu. They merge, last function wins, and the menu over the room
# is what a game comes back to (2026-09-24).
{ echo "delay 25000"; echo "event scan 8 a"; echo "delay 1000"
	# The row at the bottom of vanilla's menu panel, at this window size
	echo "mouse_pos 639 608"; echo "delay 300"; echo "mouse_click left"
	echo "delay 6000"; echo "event scan 8 b"
	echo "delay 2000"; echo "quit"; } > "$out/cmds_back.txt"
rm -f "$out/back.log" "$out/back_server.log"
bin/buildat -o launch_ui=launch_menu_attract -a game/vanilla/contentdb \
	-D ../user -w 1280x720 -l 3 -L "$out/back.log" \
	-c @"$out/cmds_back.txt" > /dev/null 2>&1
grid=$(grep -ac "back to the grid" "$out/back.log")
lost=$(grep -ac "leave: no launcher to go back to" "$out/back.log")
alive=$(grep -ac "scan b: ui" "$out/back.log")
echo "a game launched from the composition: back to the grid $grid times," \
		"$alive elements drawn after it"
if [ "$grid" -lt 1 ] || [ "$lost" -gt 0 ] || [ "$alive" -lt 10 ]; then
	echo "FAIL: a game launched from the composition cannot be left"
	grep -a "leave:" "$out/back.log" | head -2
	exit 1
fi

# vim: set noet ts=4 sw=4:
echo "PASS: the menu takes the input, the room is the view behind it," \
		"and a game can be left"
exit 0
