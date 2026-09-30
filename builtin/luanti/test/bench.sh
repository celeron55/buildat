#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# devtest's /bench_* commands through bench.lua, with a client connected;
# prints the bench lines. See [LUAJIT] in doc/plan/performance_plan.md.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "/tmp/buildat_bench.XXXXXX")
cd "$here/Build"
rm -rf ../user/games/vanilla/saves/buildat_test_bench
srv=""; cli=""
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
port=$(( 29500 + (RANDOM % 90) ))
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_bench \
	BUILDAT_LUANTI_LUA="$me/bench.lua" \
	bin/buildat_server -u launcher=1 -m ../games/vanilla -D ../user -P "$port" 2>&1 \
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
# **The verdict is that the bench ran** ([CI_RUNS]'s contract,
# 2026-09-25): what a number here should be is the reading this exists
# to give -- a threshold invented here would be a number nobody picked,
# and one that fails on llvmpipe is what [CI_RUNS] (3) forbids. What can
# fail unseen is the run: a fixture that never finished, a client that
# died, a table with no rows.
rows=$(grep -ac "bench: " "$tmp/srv.log")
if ! grep -aq "bench: done" "$tmp/srv.log"; then
	echo "FAIL: the bench did not finish; $rows rows in $tmp/srv.log"
	exit 1
fi
if [ "$rows" -lt 2 ]; then
	echo "FAIL: the bench finished with nothing to say ($rows rows)"
	exit 1
fi
echo "PASS: the bench ran and wrote $rows rows"
exit 0
# vim: set noet ts=4 sw=4:
