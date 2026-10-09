#!/bin/bash
# tier: quick
# cost: ~25 s (2026-10-09)
# covers: extensions/ui_utils/init.lua extensions/launch_menu/init.lua
# [UI_DROPDOWN]: ui_utils.dropdown, on launch_menu's Servers filter.
# The mouse opens it, Down twice and Enter pick LAN; Enter opens it again,
# Down and Escape close it with LAN kept, and the screen stays up (its
# Escape not seen). The Luanti server list's consent is declined ahead.
#
#   extensions/ui_utils/dropdown_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
check_tmp dropdown; t=$CHECK_TMP
mkdir -p "$t/cl"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"false","https://servers.luanti.org","the server list","1791497098","1791497098","","",""\n' \
	> "$t/cl/network_addresses.csv"
# Home's Servers row, then the filter at the list's top left
cat > "$t/cmds" <<CMDS
delay 5000
mouse_pos 360 316
delay 300
mouse_click left
delay 1500
mouse_pos 280 276
delay 300
mouse_click left
delay 600
mouse_pos 900 600
delay 300
keypress Down
delay 300
keypress Down
delay 300
keypress Return
delay 1500
keypress Return
delay 600
keypress Down
delay 300
keypress Escape
delay 800
event scan
delay 500
quit
CMDS
cd "$(dirname "$0")/../../Build"
timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" \
	-w 1024x640 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl.log" 2>&1
lists=$(grep -ao "launch_menu: server, [0-9]* rows, by recent, .*" "$t/cl.log" |
	sed 's/.*, //')
[ "$lists" = "All
LAN" ] || fail "the filter went: $(echo $lists) ($t/cl.log)"
grep -aq 'scan: ui .*text "Servers   (type' "$t/cl.log" ||
	fail "Escape closed the screen with the list"
echo "PASS: dropdown: opened by the mouse, picked by the keys, Escape kept the pick and the screen"
