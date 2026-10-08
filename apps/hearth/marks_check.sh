#!/bin/bash
# tier: quick
# cost: ~90 s (2026-10-08)
# covers: apps/hearth/main/** extensions/ui_utils/init.lua
# [HEARTH_NEW_MARKS]: bob is a member before the admin writes in a
# subtopic. Bob's Home then has amber marks on the sidebar's parent topic
# and the subtopic, on both topics' rows and on the thread's (Waiting and
# Latest). Read, the thread is cyan; a day on, small; eight days on,
# nothing. carol, new then, sees it unmarked. A message while bob is on Home
# marks his rows live, and the topic's Mark all read clears it.
# The marks are read from the scripted client's "hearth: mark" lines.
#
#   apps/hearth/marks_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hearth_marks; t=$CHECK_TMP
P=29885

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
	bin/buildat_server --sim-clock -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # name password log requests [env...]
	# A request makes the client scripted, which logs its marks
	local n=$1 pw=$2 log=$3 reqs=$4
	[ -n "$reqs" ] || reqs='{"cmd":"me"}'
	shift 4
	printf 'delay %s\n%bquit\n' "${MS:-6000}" "${SHOT:+screenshot $SHOT\n}" \
		> "$t/cmds_$n"
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds_$n" > "$log" 2>&1
}
# has log "where key mark"...: each a "hearth: mark" line of that log
has(){
	local log=$1 m
	shift
	for m in "$@"; do
		grep -aq "hearth: mark $m\$" "$log" ||
			fail "$(basename "$log"): no \"$m\" in: $(grep -ao 'hearth: mark .*' "$log" | sort -u | tr '\n' ';')"
	done
}
T=0
advance(){
	T=$((T + $1))
	echo $T > "$t/srv/sim_clock"
	for _i in $(seq 100); do
		grep -aq "sim clock: ${T}s ahead" "$t/srv.log" && return
		sleep 0.1
	done
	fail "the server did not take the clock to $T"
}

client admin checkpass12 "$t/a1.log" '{"cmd":"new_topic","name":"Main","about":"x"}
{"cmd":"new_topic","name":"Sub","parent":1}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234
add carol carolpass1234"
grep -aq 'hr: {"id":1002,"ok":true' "$t/a1.log" || fail "the topics"
# bob a member, then the admin's thread a second later at least
client bob bobpass1234 "$t/b0.log" ''
sleep 1
client admin checkpass12 "$t/a2.log" \
	'{"cmd":"new_thread","topic":2,"title":"In sub","body":"hello"}'
grep -aq 'hr: {"id":1001,"ok":true' "$t/a2.log" || fail "the thread"

# The marks to see: $t/home.png with KEEP_TMP=1
SHOT=$t/home.png client bob bobpass1234 "$t/b1.log" ''
has "$t/b1.log" "side c1 medium main" "side c2 medium main" \
	"page c1 medium main" "page c2 medium main" "page t1 medium main"
[ "$(grep -ac 'hearth: mark page t1 medium main$' "$t/b1.log")" = 2 ] ||
	fail "the thread is not in both Waiting and Latest"

client bob bobpass1234 "$t/b2.log" '' BUILDAT_HEARTH_OPEN=1
has "$t/b2.log" "side c1 medium focus" "side c2 medium focus"
client bob bobpass1234 "$t/b3.log" ''
has "$t/b3.log" "page t1 medium focus" "page c1 medium focus"

advance $((86400 + 600))
client bob bobpass1234 "$t/b4.log" ''
has "$t/b4.log" "page t1 small focus" "side c2 small focus"
advance $((7 * 86400))
client bob bobpass1234 "$t/b5.log" ''
has "$t/b5.log" "page t1 none focus" "side c1 none focus"
client carol carolpass1234 "$t/c1.log" ''
has "$t/c1.log" "page t1 none focus"

# Live: bob on Home while the admin writes in Main
MS=12000 client bob bobpass1234 "$t/b6.log" '' &
bpid=$!
for _i in $(seq 100); do
	grep -aq 'hearth: mark page c1' "$t/b6.log" 2>/dev/null && break
	sleep 0.1
done
client admin checkpass12 "$t/a3.log" \
	'{"cmd":"new_thread","topic":1,"title":"In main","body":"again"}'
wait $bpid
has "$t/b6.log" "page c1 medium main live" "side c1 medium main live"

# Mark all read on Main: its thread and Sub's are read
client bob bobpass1234 "$t/b7.log" '{"cmd":"mark_read","topic":1}'
client bob bobpass1234 "$t/b8.log" ''
has "$t/b8.log" "page t2 medium focus" "side c1 medium focus"
grep -aq 'hearth: mark page t2 medium main$' "$t/b8.log" &&
	fail "Main's thread still unread after Mark all read"
echo "PASS: new posts marked amber on the topics, the subtopic and the thread; cyan when read, small a day on, gone after a week; a new account's start; live; Mark all read"
