#!/bin/bash
# tier: quick
# cost: ~40 s (2026-10-09)
# covers: src/client/app.cpp client/extensions/network/init.lua extensions/launch_menu/init.lua
# [JOINED_TLS_SERVERS]: a server joined is on launch_menu's start
# screen whether or not it sends an icon, and one behind TLS by its https
# address. A digger server with no icon is joined once; its row is
# written, with no icon. The store then gets an https row joined later,
# as a TLS join writes it (the join itself needs a certificate the
# client trusts, so it is tried against a real server by hand); the
# menu's first row is it, and a search for "tls" finds it.
#
#   extensions/launch_menu/joined_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
check_tmp joined; t=$CHECK_TMP
P=29887
cd "$(dirname "$0")/../../Build"
start_server "$t/srv.log" "Listening at" 180 $P \
	bin/buildat_server -m ../apps/digger -D "$t/srv" -l 3 ||
	fail "digger did not start"
CHECK_PIDS+=($SERVER_PID)
grep -aq "The server's icon:" "$t/srv.log" && fail "the server has an icon"
printf 'delay 6000\nquit\n' > "$t/cmds"
timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" \
	-s localhost:$P -w 640x360 -l 3 -o sound_mute=1 -c @"$t/cmds" \
	> "$t/cl1.log" 2>&1
grep -q "\"tcp://localhost:$P\",\"\",\"[0-9]*\",\"[0-9]*\",\"\",\"\",\"\"" \
	"$t/cl/network_addresses.csv" ||
	fail "no row for the server joined: $(cat "$t/cl/network_addresses.csv")"
echo "\"true\",\"https://tls.example.org:443\",\"\",\"0\",\"$(($(date +%s) + 60))\",\"\",\"\",\"\"" \
	>> "$t/cl/network_addresses.csv"
printf 'delay 5000\ntext tls\ndelay 1500\nquit\n' > "$t/cmds"
timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" \
	-w 1024x640 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl2.log" 2>&1
grep -aq "launch_menu: [0-9]* rows in [0-9]* ms, first https://tls.example.org:443" \
	"$t/cl2.log" || fail "the TLS row is not first: $(grep -a "rows in" "$t/cl2.log")"
grep -aq "rows for \"tls\" in [0-9]* ms, first https://tls.example.org:443" \
	"$t/cl2.log" || fail "the search does not find it: $(grep -a "rows for" "$t/cl2.log")"
echo "PASS: joined: a server with no icon has its row, an https row is the start screen's first and found"
