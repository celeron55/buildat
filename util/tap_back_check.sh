#!/bin/bash
# tier: fast
# cost: ~15 s, ~40 s with the web part (2026-10-06)
# covers: client/extensions/uistack/init.lua src/client/app.cpp
# [TAP_BACK]: a click on nothing is Back. launch_menu_v2's Settings stays up
# for a click in its window, goes for a click beside it, and Home, the
# first screen, stays as it is for one (no Quit dialog). Escape's Quit
# dialog then goes by the arrows: Left, Right, Enter is Cancel, and Down,
# Down, Up, Enter is Quit (a playtest found only Tab there). Then in Firefox
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
n=$(grep -ac 'push(): .*show_confirm_dialog' "$t/log")
[ "$n" = 2 ] || fail "$n Quit dialogs, not 2 (a click on nothing on Home asks to quit?)"
grep -aq "command: quit" "$t/log" && fail "the arrows' Quit did not quit"
[ "$(grep -ac 'pop(): .*show_confirm_dialog' "$t/log")" = 2 ] || fail "the arrows' Cancel"
echo "ok: a click on nothing is Back above the first screen, and nothing on it"

[ -f web/buildat.wasm ] || { echo "PASS (web part skipped: no web/)"; exit 0; }
timeout 300 util/web_drive.sh firefox play util/tap_back_web.json "$t/web" \
	> "$t/web.out" 2>&1 || { cp "$t/web.out" "$t/log"; fail "web_drive"; }
for want in "settings: depth 2" "after Back: depth 1 http" "after tap: depth 1" \
		"left: about:blank"; do
	grep -q "eval: \"$want" "$t/web.out" || { cp "$t/web.out" "$t/log"; fail "web: no \"$want\""; }
done
echo "PASS: a click or tap on nothing is Back, the browser's Back is too, and leaves on Home"
