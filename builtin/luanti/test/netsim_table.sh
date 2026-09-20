#!/bin/bash
# [NET_SIM]'s table, one cell: N driven runs (drive.sh, seed 5, GOAL 3,
# 10 min) with or without the proxy, one line each appended to the table
# under local/options_for_NET_SIM/: whether the goal was met and when, the
# worst wait behind the wire the server logged, and whether the client
# was disconnected.
#
#   builtin/luanti/test/netsim_table.sh none 3
#   builtin/luanti/test/netsim_table.sh "--delay 80 --rate 20000 --loss 2" 3
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
cell="$1"; n="${2:-3}"
out="$here/local/options_for_NET_SIM"
mkdir -p "$out"
table="$out/table_$(date +%F).txt"
for i in $(seq 1 "$n"); do
	t0=$(date +%s)
	if [ "$cell" = none ]; then
		SEED=5 MINUTES=10 GOAL=3 "$here/builtin/luanti/test/drive.sh" >/dev/null 2>&1
	else
		NETSIM="$cell" SEED=5 MINUTES=10 GOAL=3 "$here/builtin/luanti/test/drive.sh" >/dev/null 2>&1
	fi
	wall=$(( $(date +%s) - t0 ))
	log="$here/local/drive/5"
	goal=$(grep -o "GOAL [0-9]* \(met at turn [0-9]*, t=[0-9]*\|not met in [0-9]* turns\)" "$log/drive.log" | tail -1)
	worst=$(grep -o "five seconds [0-9]* ms" "$log/srv.log" | awk '{ if ($3 > w) w = $3 } END { print w + 0 }')
	gone=$(grep -c "FAILED disconnected" "$log/drive.log")
	echo "cell=[$cell] seed=5 run=$i wall=${wall}s ${goal:-no verdict} worst_wait=${worst} ms disconnected=$gone" | tee -a "$table"
done
