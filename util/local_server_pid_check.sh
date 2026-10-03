#!/bin/bash
# tier: full
# cost: 40s (2026-10-04)
# covers: src/client/app.cpp src/client/main.cpp
# [SERVER_ADOPTED]: a client stops only a local server it started, or one
# whose client is gone; a scripted client keeps out of the default cache.
#   1. Client A plays digger (-a app/digger/play) on a local server, with a cache given by -C
#      as a person's launcher has; client B, on the same cache, starts and
#      quits beside it: A's server is still running.
#   2. A scripted client with no -C leaves the default cache's
#      buildat.log as it was.
#
#   util/local_server_pid_check.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
a=
trap '[ -n "$a" ] && kill $a 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"

# 1
printf 'delay 30000\nquit\n' > "$t/long"
printf 'delay 3000\nquit\n' > "$t/short"
timeout 90 bin/buildat -C "$t/cache" -D "$t/ua" -a app/digger/play -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/long" > "$t/a.log" 2>&1 &
a=$!
for _ in $(seq 60); do
	[ -s "$t/cache/local_server.pid" ] && break
	sleep 1
done
read -r server client < "$t/cache/local_server.pid" ||
	fail "A wrote no pidfile ($(tail -3 "$t/a.log"))"
# $a is timeout's; the client is its child
[ "$(ps -o ppid= -p "$client" | tr -d ' ')" = "$a" ] ||
	fail "the pidfile names client $client, not A"
kill -0 "$server" || fail "A's server is not running"
timeout 60 bin/buildat -C "$t/cache" -D "$t/ub" -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/short" > "$t/b.log" 2>&1
grep -q "Adopted leftover" "$t/b.log" && fail "B adopted A's server"
kill -0 "$server" || fail "B's quit stopped A's server"

# 2
log=$(ls -d "$here"/Build/cache 2>/dev/null || echo "${XDG_CACHE_HOME:-$HOME/.cache}/buildat")/buildat.log
before=$(stat -c %Y "$log" 2>/dev/null)
timeout 60 bin/buildat -D "$t/uc" -w 640x360 -l 3 -o sound_mute=1 \
	-c @"$t/short" > "$t/c.log" 2>&1
[ "$(stat -c %Y "$log" 2>/dev/null)" = "$before" ] ||
	fail "a scripted client wrote $log"
echo "PASS: B left A's server running; a scripted client kept out of the default cache"
