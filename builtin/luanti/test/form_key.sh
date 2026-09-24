#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [BOX_PLAYTEST_2] (8): the key that opens a form must not type into the
# field the form focuses. VoxeLibre's creative inventory (I) focuses its
# search field; after the press the field must be empty. A real key is a
# KeyDown and a TextInput in one frame and the sequencer's keypress is
# only the first, so the text is injected beside it. Prints PASS or FAIL;
# the log is under local/form_key/.
#
#   builtin/luanti/test/form_key.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/form_key"
mkdir -p "$out"
save="buildat_test_form_key"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
cat > "$out/fixture.lua" <<'LUA'
core.settings:set("creative_mode", "true")
core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
LUA
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29785 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
wait_log 60000 the server put the player
wait_log 60000 0 undrawn within 2
delay 2000
keypress I
text i
delay 1500
event scan
delay 500
quit
CMDS
bin/buildat -s localhost:29785 -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
edits=$(grep -a "scan scan: ui.*LineEdit" "$out/cli.log" | sed 's/.*text //')
echo "fields: $edits"
if [ -z "$edits" ]; then echo "FAIL: no form field on the screen"; exit 1; fi
if echo "$edits" | grep -q '"[^"]'; then echo "FAIL: the key typed into the field"; exit 1; fi
echo "PASS: the form's field is empty after the key that opened it"
