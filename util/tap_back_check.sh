#!/bin/bash
# tier: fast
# cost: ~15 s, ~40 s with the web part (2026-10-06)
# covers: client/extensions/uistack/init.lua src/client/app.cpp
# [TAP_BACK]: a click on nothing is Back. launch_menu_v2's Settings stays up
# for a click in its window, goes for a click beside it, and Home, the
# first screen, stays as it is for one (no Quit dialog). Escape's Quit
# dialog then goes by the arrows: Left, Right, Enter is Cancel, and Down,
# Down, Up, Enter is Quit (a playtest found only Tab there). A screen
# left by Escape gives its parent back the selection it was opened from:
# Down after it goes on from there, not from the top. A row the mouse
# selected is let go when the mouse leaves it, and Down brings it back; one
# the keys selected stays wherever the mouse goes. In the Servers list a
# clicked row is locked: the panel stays its while the mouse is over
# another row, and an arrow key lets go. Then in Firefox
# (with web/ from util/build_web.sh, skipped without), apps/play's page,
# by touch: the browser's Back and a tap on nothing each close Settings,
# and Back on Home leaves the page.
#   util/tap_back_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; cp "$t/log" /tmp/tap_back_check.log; echo "log in /tmp/tap_back_check.log"; exit 1; }
# Positions at 800x600: Home's Settings row, Settings' heading, and the
# left edge, where nothing is
cat > "$t/cmds" <<C
wait_log_any 20000 launch_menu_v2: home
delay 1000
mouse_pos 260 350
mouse_click left
delay 800
mouse_pos 300 210
mouse_click left
delay 800
event scan
mouse_pos 5 300
mouse_click left
delay 800
event scan
mouse_pos 5 300
mouse_click left
delay 800
event scan
mouse_pos 260 353
delay 300
event scan
mouse_pos 700 345
delay 300
event scan
keypress Down
delay 300
event scan
keypress Up
delay 200
mouse_pos 5 100
delay 300
event scan
keypress Down
keypress Down
keypress Down
delay 300
event scan
keypress Up
keypress Return
delay 1000
keypress Escape
delay 800
keypress Down
delay 300
event scan
keypress Escape
delay 500
keypress Left
keypress Right
keypress Return
delay 600
keypress Escape
delay 500
keypress Down
keypress Down
keypress Up
keypress Return
delay 3000
quit
C
timeout 60 Build/bin/buildat -o launch_ui=launch_menu_v2 -D "$t/u" -w 800x600 -l 4 \
	-o sound_mute=1 -c @"$t/cmds" > "$t/log" 2>&1
# Each scan's "Display and sound" header says Settings is up
scans=$(grep -a "^scan scan: ui\|UIStack:p\|click on nothing" "$t/log")
n=$(grep -c "push(): .*launch_menu_v2 settings" <<< "$scans")
[ "$n" = 1 ] || fail "Settings opened $n times"
grep -c "click on nothing" <<< "$scans" | grep -qx 1 ||
	fail "not exactly one Back: $(grep "click on nothing" <<< "$scans")"
# The first scan (after the click inside) still has Settings' header
awk '/UIStack:pop/{exit} /text "Display and sound"/{f=1} END{exit !f}' <<< "$scans" ||
	fail "a click in Settings' window closed it"
grep -q 'pop(): .*launch_menu_v2 settings' <<< "$scans" || fail "Settings did not go"
# Each scan's focus, by its number: 4 a hovered row, 5 none (the mouse
# left), 6 that row again (Down), 7 the row above (Up, the mouse gone
# away), 8 and 9 the third row, before and after the second's screen came
# and went
f(){ awk -v n="$1" '/command: event scan/{i++} i == n && /^scan scan: focus/{
	print $4, $6; exit}' "$t/log"; }
[ "$(f 4 | cut -d' ' -f1)" = Button ] || fail "hovering a row: $(f 4)"
[ "$(f 5 | cut -d' ' -f1)" != Button ] || fail "the mouse left the row and it stayed: $(f 5)"
[ "$(f 6)" = "$(f 4)" ] || fail "Down after the mouse left: $(f 6), not $(f 4)"
[ "$(f 7 | cut -d' ' -f1)" = Button ] && [ "$(f 7)" != "$(f 6)" ] ||
	fail "a row the keys chose went with the mouse: $(f 7)"
[ -n "$(f 8)" ] && [ "$(f 9)" = "$(f 8)" ] ||
	fail "the selection was not given back: $(f 8) then $(f 9)"
n=$(grep -ac 'push(): .*show_confirm_dialog' "$t/log")
[ "$n" = 2 ] || fail "$n Quit dialogs, not 2 (a click on nothing on Home asks to quit?)"
grep -aq "command: quit" "$t/log" && fail "the arrows' Quit did not quit"
[ "$(grep -ac 'pop(): .*show_confirm_dialog' "$t/log")" = 2 ] || fail "the arrows' Cancel"

# Home's Browse > Servers, its rows at 800x600: a click on the second, the
# mouse on the third, then Down
cat > "$t/cmds2" <<C
wait_log_any 20000 launch_menu_v2: home
delay 800
keypress Down
keypress Return
delay 1000
mouse_pos 200 298
mouse_click left
delay 300
mouse_pos 200 318
delay 400
event scan
keypress Down
delay 400
event scan
quit
C
timeout 60 Build/bin/buildat -o launch_ui=launch_menu_v2 -D "$t/u2" -w 800x600 -l 4 \
	-o sound_mute=1 -c @"$t/cmds2" > "$t/log2" 2>&1
cp "$t/log2" "$t/log"
grep -aq "launch_menu_v2: locked Join a Buildat server" "$t/log2" || fail "the click locked nothing"
# The panel's heading, and the focus, in each scan
p(){ awk -v n="$1" '/command: event scan/{i++} i == n && /size 166x20 text/{
	sub(/.*text /, ""); print; exit}' "$t/log2"; }
[ "$(p 1)" = '"Join a Buildat server"' ] || fail "the panel left the locked row for the hovered one: $(p 1)"
grep -aq "launch_menu_v2: unlocked" "$t/log2" || fail "Down did not let go"
[ "$(p 2)" != '"Join a Buildat server"' ] || fail "the panel stayed locked after Down"
echo "ok: a click on nothing is Back above the first screen, and nothing on it; a click locks a row"

[ -f web/buildat.wasm ] || { echo "PASS (web part skipped: no web/)"; exit 0; }
timeout 300 util/web_drive.sh firefox play util/tap_back_web.json "$t/web" \
	> "$t/web.out" 2>&1 || { cp "$t/web.out" "$t/log"; fail "web_drive"; }
for want in "settings: depth 2" "after Back: depth 1 http" "after tap: depth 1" \
		"left: about:blank"; do
	grep -q "eval: \"$want" "$t/web.out" || { cp "$t/web.out" "$t/log"; fail "web: no \"$want\""; }
done
echo "PASS: a click or tap on nothing is Back, the browser's Back is too, and leaves on Home"
