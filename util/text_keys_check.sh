#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-10)
# covers: 3rdparty/Urho3D/Source/Urho3D/UI/LineEdit.cpp src/client/web/index.html
# [TEXT_KEYS], the text field's keys and clicks, by the ui scan's text,
# cursor and selection after each step:
#   1. Single-line, launch_menu's "Join a Buildat server" Address: Ctrl+A
#      selects all; typing replaces it; Ctrl+Left by word, Shift+Ctrl+Right
#      selects a word (foo_bar is one, wörld is one); Alt+Backspace and
#      Ctrl+Backspace delete back a word, Ctrl+Delete forward; a double-click
#      selects the word, a third click everything.
#   2. Multi-line, Hearth's reply field: Ctrl+A there is the field's (the
#      text selected, nothing sent); a triple-click selects the line; Home and
#      Alt+Backspace at a line's start join it to the one above, past its
#      trailing spaces.
#   3. The web page's Alt+Backspace is there, by the same word rule (the
#      handler read, not run: the web smoke drives the page).
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/text_keys_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp text_keys; t=$CHECK_TMP
cd "$here/Build"

# The field at x,y in scan $2 of log $1: its text, cursor and selection
field(){ # log label x,y
	grep -a "scan $2: " "$1" | grep -a -A1 "ui  *LineEdit at $3 " | grep -av "^--" |
		sed 's/.* size [0-9x]* //' | tr '\n' ' ' | sed 's/ *$//'
}
want(){ # log label x,y expected
	local got
	got=$(field "$1" "$2" "$3")
	[ "$got" = "$4" ] || fail "$2: '$got', not '$4'"
}
ctrl(){ echo "keydown ctrl\nkeypress $1\nkeyup ctrl\ndelay 200\n"; }

# 1. Single-line
s='wait_log_any 20000 launch_menu: \ndelay 1500\ntext join a buildat\ndelay 500\nkeypress Return\ndelay 1500\n'
s+="$(ctrl A)event scan s1\ntext hello wörld foo_bar, baz\ndelay 200\n$(ctrl Left)event scan s2\n"
s+="$(ctrl Left)keydown shift\n$(ctrl Right)keyup shift\nevent scan s3\n"
s+='keypress End\nkeydown alt\nkeypress Backspace\nkeyup alt\ndelay 200\nevent scan s4\n'
s+="$(ctrl Backspace)event scan s5\nkeypress Home\n$(ctrl Delete)event scan s6\n"
s+='mouse_pos 772 285\ndelay 300\nmouse_click left\nmouse_click left\ndelay 200\nevent scan s7\n'
s+="delay 1000\nmouse_click left\nmouse_click left\nmouse_click left\ndelay 200\nevent scan s8\nscreenshot $t/single.png\nquit\n"
printf "$s" > "$t/single.cmds"
timeout 60 bin/buildat -m launch_menu -D "$t/cl" -w 1280x720 -l 3 \
	-o sound_mute=1 -c @"$t/single.cmds" > "$t/single.log" 2>&1
grep -aq "Command sequence complete" "$t/single.log" || fail "the single-line drive"
grep -aq "Lua runtime error" "$t/single.log" && fail "a Lua error in the single-line drive"
L=$t/single.log; A=749,277
want $L s1 $A 'text "localhost" cursor 9 text "localhost" selection 0+9'
want $L s2 $A 'text "hello wörld foo_bar, baz" cursor 21 text "hello wörld foo_bar, baz"'
want $L s3 $A 'text "hello wörld foo_bar, baz" cursor 19 text "hello wörld foo_bar, baz" selection 12+7'
want $L s4 $A 'text "hello wörld foo_bar, " cursor 21 text "hello wörld foo_bar, "'
want $L s5 $A 'text "hello wörld " cursor 12 text "hello wörld "'
want $L s6 $A 'text " wörld " cursor 0 text " wörld "'
want $L s7 $A 'text " wörld " cursor 6 text " wörld " selection 1+5'
want $L s8 $A 'text " wörld " cursor 7 text " wörld " selection 0+7'
echo "ok: single-line: Ctrl+A, by word, the word deletes, the double and triple click"

# 2. Multi-line, Hearth's reply field
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
hearth(){ # log requests commands [env...]
	local log=$1 reqs=$2
	printf "$3" > "$t/hearth.cmds"
	shift 3
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$SERVER_PORT \
		-c @"$t/hearth.cmds" > "$log" 2>&1
}
hearth "$t/setup.log" '{"cmd":"new_topic","name":"Keys"}
{"cmd":"new_thread","topic":1,"title":"Keys","body":"first"}' 'delay 6000\nquit\n'
grep -aq '"id":1001,.*"ok":true' "$t/setup.log" || fail "the thread: $(grep -a 'hr: ' "$t/setup.log" | head -2)"
m='delay 6000\ntext one two  x\nkeypress Backspace\nkeypress Return\ntext three four\ndelay 300\nevent scan m1\n'
m+="$(ctrl A)event scan m2\nmouse_pos 290 201\ndelay 300\nmouse_click left\nmouse_click left\nmouse_click left\ndelay 200\nevent scan m3\n"
m+='keypress Home\nkeydown alt\nkeypress Backspace\nkeyup alt\ndelay 200\nevent scan m4\n'
m+="screenshot $t/multi.png\nquit\n"
hearth "$t/multi.log" "" "$m" BUILDAT_HEARTH_OPEN=1
grep -aq "Lua runtime error" "$t/multi.log" && fail "a Lua error in the multi-line drive"
# The text's line break is a line break in the log too
focus(){ grep -a -A1 "scan $1: focus" "$t/multi.log" | grep -av "^--" | tr '\n' '|' | sed 's/.* size [0-9x]* //; s/|loka.*//; s/|$//'; }
wantm(){ [ "$(focus $1)" = "$2" ] || fail "$1: '$(focus $1)', not '$2'"; }
wantm m1 'text "one two  |three four" cursor 20 selection 0+0'
wantm m2 'text "one two  |three four" cursor 20 selection 0+20'
wantm m3 'text "one two  |three four" cursor 20 selection 10+10'
wantm m4 'text "one twothree four" cursor 7 selection 0+0'
curl -s "http://127.0.0.1:$SERVER_PORT/t/1" | grep -q "three" && fail "Ctrl+A in the reply field sent it"
echo "ok: multi-line: Ctrl+A the field's, the triple-click a line, Alt+Backspace at a line's start joins it"

# 3. The web page's word rule, its own function run by node
if command -v node > /dev/null; then
	sed -n '/^\tfunction wordLeft(v, a){$/,/^\t}$/p' "$here/src/client/web/index.html" > "$t/wl.js"
	[ -s "$t/wl.js" ] || fail "no wordLeft in index.html"
	cat >> "$t/wl.js" <<'JS'
const eq = (v, a, want) => { const got = wordLeft(v, a); if(got !== want) { console.log(`FAIL: web wordLeft(${JSON.stringify(v)}, ${a}) = ${got}, not ${want}`); process.exit(1); } };
const s = "hello wörld foo_bar, ";
eq(s, s.length, 12);
eq(s, 12, 6);
eq("one two  \nthree", 10, 7);
eq("", 0, 0);
JS
	node "$t/wl.js" || exit 1
	echo "ok: the web page's Alt+Backspace word rule"
else
	echo "skip: no node for the web page's word rule"
fi
echo "PASS: Ctrl+A, the word moves and deletes and the clicks, single- and multi-line; the web page's Alt+Backspace (see $t/*.png)"
