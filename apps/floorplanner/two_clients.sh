#!/bin/bash
# tier: full
# cost: 3 min (two floorplanner rounds and a vanilla one, 2026-10-03)
# covers: builtin/accounts/** apps/floorplanner/main/main.cpp
# [FP_TWO_CLIENTS]: **one user, two clients at once**. An admin makes the
# account "pl"; two clients log in as pl into the same plan.
#   1. A switches to editing, B stays viewing: one connection editing.
#   2. A leaves, B carries on and switches to editing: a second one.
#   3. Both again, and the admin kicks pl: both are kicked.
#   4. Both again, and the admin resets pl's password: both are ended.
#   5. vanilla refuses the second login of a name.
# Read from the server's log ("is editing", "kicked:") and the clients'.
#
#   apps/floorplanner/two_clients.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/two_clients"
rm -rf "$out"; mkdir -p "$out"
cd "$here/Build"
port=29891
fail=0
pids=()
trap 'for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null; done' EXIT

server() { # app user_dir log
	bin/buildat_server -m ../apps/$1 -D "$2" -P $port -l 3 2>&1 |
		sed -u -e 's/\x1b\[[0-9;]*m//g' > "$3" &
	for i in $(seq 1 180); do grep -q "setup code" "$3" 2>/dev/null && break; sleep 1; done
	pids+=($(pgrep -f "buildat_server .*-D $2" | head -1))
}
client() { # env_prefix name password code cmds log [extra env]
	local p=$1 n=$2 pw=$3 c=$4 cmds=$5 log=$6; shift 6
	env "${p}_NAME=$n" "${p}_PASSWORD=$pw" "${p}_CODE=$c" "$@" \
		timeout 150 bin/buildat -o launch_ui=launch_menu -s localhost:$port -D "$out/cli_$(basename "$log" .log)" \
		-w 640x400 -l 3 -c @"$cmds" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$log"
}
cmds() { local n=$1; shift; printf '%s\n' "$@" > "$out/$n.txt"; }

server floorplanner "$out/fp" "$out/fp.log"
code=$(grep -ao "setup code [A-Z0-9]*" "$out/fp.log" | tail -1 | awk '{print $3}')
cmds adm "delay 6000" "quit"
client BUILDAT_FP adm adminpass12 "$code" "$out/adm.txt" "$out/adm.log" \
	"BUILDAT_FP_ADMIN=add pl plpass1234"
grep -a "admin result" "$out/adm.log" | sed 's/.*accounts: /admin: /'

# 1 and 2. "Start editing" is the toolbar's last button
edit="mouse_pos 230 12"
cmds a "delay 9000" "$edit" "mouse_click left" "delay 6000" "quit"
cmds b "delay 22000" "$edit" "mouse_click left" "delay 4000" "quit"
client BUILDAT_FP pl plpass1234 "" "$out/a.txt" "$out/a.log" BUILDAT_FP_PLAN=p1 &
ca=$!
sleep 3
client BUILDAT_FP pl plpass1234 "" "$out/b.txt" "$out/b.log" BUILDAT_FP_PLAN=p1
wait $ca
grep -a "is editing" "$out/fp.log" | sed 's/.*main *: //'
ids=$(grep -a "pl (.*) is editing p1" "$out/fp.log" | sed 's/.*(\([0-9]*\)).*/\1/' | sort -u | wc -l)
if ! grep -aq "Joined as pl" "$out/b.log"; then
	echo "FAIL: the second client of pl was refused: $(grep -a "Login refused" "$out/b.log" | head -1)"; fail=1
elif [ "$ids" -ne 2 ]; then
	echo "FAIL: $ids connections editing, not one and then the other"; fail=1
else
	echo "ok: one client edits while the other views; the other carries on and edits"
fi

# 3 and 4: the admin acts on both
for act in "kick pl|kicked by adm" "password pl newpass1234|the password was reset by adm"; do
	req=${act%%|*} why=${act##*|}
	cmds a "delay 25000" "quit"
	client BUILDAT_FP pl plpass1234 "" "$out/a.txt" "$out/a2.log" BUILDAT_FP_PLAN=p1 &
	ca=$!
	client BUILDAT_FP pl plpass1234 "" "$out/a.txt" "$out/b2.log" BUILDAT_FP_PLAN=p1 &
	cb=$!
	sleep 12
	client BUILDAT_FP adm adminpass12 "" "$out/adm.txt" "$out/adm2.log" \
		"BUILDAT_FP_ADMIN=$req"
	wait $ca $cb
	n=$(grep -ac "pl kicked: $why" "$out/fp.log")
	[ "$n" -ge 2 ] && echo "ok: '$req' reached both connections" ||
		{ echo "FAIL: '$req' reached $n of 2"; fail=1; }
done
kill -INT "${pids[@]}" 2>/dev/null
for i in $(seq 1 30); do ss -ltn | grep -q ":$port " || break; sleep 1; done

# 5. vanilla: one name, one connection
server vanilla "$out/va" "$out/va.log"
vcode=$(grep -ao "setup code [A-Z0-9]*" "$out/va.log" | tail -1 | awk '{print $3}')
cmds v "delay 15000" "quit"
client BUILDAT_JOIN op adminpass12 "$vcode" "$out/v.txt" "$out/v1.log" &
cv=$!
sleep 8
client BUILDAT_JOIN op adminpass12 "" "$out/v.txt" "$out/v2.log"
wait $cv
if grep -aq "Login refused: op is already here" "$out/v2.log"; then
	echo "ok: vanilla refuses a second login of a name"
else
	echo "FAIL: vanilla let op in twice"; fail=1
fi
[ $fail = 0 ] && echo "PASS: one user from two clients, both live, and the admin reaches both"
exit $fail
# vim: set noet ts=4 sw=4:
