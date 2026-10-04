#!/bin/bash
# tier: quick
# cost: 40s (a floorplanner server and a client, 2026-10-02)
# covers: extensions/ui_utils/** builtin/accounts/client_lua/** apps/floorplanner/main/client_lua/init.lua
# [MENU_KEYS]: **every menu by the keyboard**. A client joins a local
# floorplanner and goes through its pages with no mouse: the plan picker,
# its menu, My account and Two-step login -- by letters, by Tab and by
# the arrows, Enter pressing. What it reads is the log ui_utils keeps at
# -l 4: each page's letters, and where each letter went.
#
#   extensions/ui_utils/check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/menu_keys"
rm -rf "$out"; mkdir -p "$out"
cd "$here/Build"
port=29881
bin/buildat_server -m ../apps/floorplanner -D "$out/srv" -P $port -l 3 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 120); do
	grep -q "setup code" "$out/srv.log" 2>/dev/null && break; sleep 1
done
srv=$(pgrep -f "buildat_server .*-D $out/srv" | head -1)
trap 'kill -INT "$srv" 2>/dev/null' EXIT
code=$(grep -ao "setup code [A-Z0-9]*" "$out/srv.log" | tail -1 | awk '{print $3}')
# Down leaves the picker's name field, whose letters are text
cat > "$out/cmds.txt" <<CMDS
delay 7000
keypress down
keypress m
keypress return
delay 1500
keypress m
keypress return
delay 1500
keypress t
keypress return
delay 1500
keypress b
keypress return
delay 1500
keypress tab
keypress return
delay 1500
keypress down
keypress return
delay 1500
quit
CMDS
BUILDAT_FP_NAME=op BUILDAT_FP_PASSWORD=pw123456 BUILDAT_FP_CODE=$code \
	timeout 120 bin/buildat -s localhost:$port -D "$out/cli" -w 800x500 -l 4 \
	-c @"$out/cmds.txt" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
grep -a "ui_utils: keyboard" "$out/cli.log" | sed 's/.*ui_utils: //' > "$out/keys.txt"
cat "$out/keys.txt"
fail=0
expect() {
	if ! grep -q "$1" "$out/keys.txt"; then
		echo "FAIL: no \"$1\" ($2)"; fail=1
	fi
}
expect "letters nitm" "the picker's buttons have their letters"
expect "keyboard: m to Menu..." "a letter focuses its button"
expect "letters bcamrlq" "Enter opened the picker's menu"
expect "keyboard: m to My account..." "the menu by its letters"
expect "keyboard: t to Two-step login..." "an Accounts page by its letters"
expect "keyboard: b to Back" "Back by its letter"
# After Back: My account, then Two-step login by Tab and Enter, then My
# account again by Down and Enter -- in that order, each page once
after=$(sed -n '/keyboard: b to Back/,$p' "$out/keys.txt" | grep "letters" |
	sed 's/.*letters //' | uniq | tr '\n' ' ')
if [ "$after" != "ctlb tb ctlb " ]; then
	echo "FAIL: after Back the pages were \"$after\", not My account," \
			"Two-step login by Tab and Enter, My account by Down and Enter"
	fail=1
fi
if grep -aq "Crash: SIG\|a button outside its menu" "$out/cli.log"; then
	echo "FAIL: $(grep -a "Crash: SIG\|a button outside" "$out/cli.log" | head -1)"
	fail=1
fi
[ $fail = 0 ] && echo "PASS: the pages are reached and pressed by the keyboard alone"
exit $fail
# vim: set noet ts=4 sw=4:
