#!/bin/bash
# tier: full
# cost: 40s (2026-10-04)
# covers: client/extensions/network/init.lua apps/uitest/**
# [CONSENT_PER_SERVER]: a script's network consent is the asking server's.
# Two uitest servers; the client's store holds an accepted row for
# tcp://localhost:9 given to the first.
#   1. Connected to the first: its script's connect takes the row, no
#      dialog.
#   2. Connected to the second: the same connect asks the user, and the
#      dialog names that server.
#
#   util/consent_check.sh    (SHOT=x.png keeps the second's dialog)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"
A=29811; B=29812
for p in $A $B; do
	bin/buildat_server -m ../apps/uitest -D "$t/srv$p" -P $p -l 3 \
		> "$t/srv$p.log" 2>&1 &
	pids="$pids $!"
done
for p in $A $B; do
	for _ in $(seq 120); do
		grep -q "STATUS Listening" "$t/srv$p.log" && break
		sleep 1
	done
	grep -q "STATUS Listening" "$t/srv$p.log" || fail "server $p did not start"
done
mkdir -p "$t/u"
now=$(date +%s)
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","tcp://localhost:9","","%s","%s","","","localhost:%s"\n' \
	$now $now $A > "$t/u/network_addresses.csv"
client(){   # port, sequence -> $t/c$port.log
	printf "$2" > "$t/seq$1"
	timeout 60 bin/buildat -o launch_ui=launch_menu -s localhost:$1 -D "$t/u" -w 800x600 -l 3 \
		-o sound_mute=1 -c @"$t/seq$1" > "$t/c$1.log" 2>&1
}
# 1
client $A 'wait_log 30000 uitest: tcp_connect\nquit\n'
grep -q "uitest: tcp_connect" "$t/c$A.log" ||
	fail "the first server's script did not connect ($(tail -3 "$t/c$A.log"))"
grep -q "Asking the user about tcp://localhost:9" "$t/c$A.log" &&
	fail "asked again for the server the row was given to"
# 2
client $B "wait_log 30000 Asking the user about\ndelay 1000\nscreenshot $t/b.png\nquit\n"
grep -q "Asking the user about tcp://localhost:9 for \"localhost:$B\"" "$t/c$B.log" ||
	fail "the second server's script was not asked about ($(grep -a 'Asking\|tcp_connect' "$t/c$B.log" | tail -3))"
[ -n "${SHOT:-}" ] && cp "$t/b.png" "$SHOT"
echo "PASS: the row given to one server's scripts was not the other's"
