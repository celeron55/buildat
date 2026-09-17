#!/bin/bash
# devtest's /bench_* commands through bench.lua, with a client connected;
# prints the bench lines. See [LUAJIT] in doc/plan/performance_plan.md.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
cd "$here/Build"
rm -rf ../user/games/luanti_launcher/saves/buildat_test_bench
srv=""; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
port=$(( 29500 + (RANDOM % 90) ))
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_bench \
	BUILDAT_LUANTI_LUA="$me/bench.lua" \
	bin/buildat_server -m ../games/luanti_launcher -D ../user -P "$port" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$tmp/srv.log" &
for i in $(seq 1 200); do
	grep -q "Mods loaded" "$tmp/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 3
srv=$(pgrep -x buildat_server | head -1)
{ echo "delay 600000"; echo "quit"; } > "$tmp/cmds.txt"
bin/buildat -s "localhost:$port" -w 640x360 -l 2 -c @"$tmp/cmds.txt" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
for i in $(seq 1 300); do
	grep -aq "bench: done" "$tmp/srv.log" && break
	kill -0 "$cli" 2>/dev/null || break
	sleep 2
done
grep -a "bench: " "$tmp/srv.log" | sed 's/^.*bench: //'
