#!/bin/bash
# tier: full
# cost: 3 min (2026-10-07)
# covers: apps/floorplanner/main/main.cpp apps/floorplanner/main/client_lua/init.lua
# [FP_GROUPS]: groups, invites, shares and the storage limit, as the plan
# says it is done. Clients a, b, c and d, one after another or two at
# once; read from their logs and the server's.
#   apps/floorplanner/groups_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_fpgroups.XXXXXX")
port=29875
export BUILDAT_CONNECT_PORTS=$port
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

server() {
	local from=$(($(cat "$tmp/fp.log" 2>/dev/null | wc -l) + 1))
	Build/bin/buildat_server -m apps/floorplanner -D "$tmp/fp" -P $port -l 3 \
		>> "$tmp/fp.log" 2>&1 &
	spid=$!
	pids+=($spid)
	for _ in $(seq 120); do
		tail -n +$from "$tmp/fp.log" | grep -q "groups$" && break
		sleep 1
	done
}
# name log seconds [env...]: a client of `name` that quits after `seconds`,
# or runs the command file $CMDS
client() {
	local n=$1 log=$2 secs=$3; shift 3
	local cmds=${CMDS:-}
	if [ -z "$cmds" ]; then
		cmds="$tmp/c_$(basename "$log" .log)"
		printf 'delay %s\nquit\n' "${secs}000" > "$cmds"
	fi
	env BUILDAT_FP_NAME=$n BUILDAT_FP_PASSWORD=${n}pass1234 "$@" \
		timeout 120 Build/bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$port \
		-D "$tmp/cl_$n" -w 640x400 -l 3 -o sound_mute=1 -c @"$cmds" \
		> "$tmp/$log" 2>&1
}
last() { grep -a "$2" "$tmp/$1" | tail -1; }

server
code=$(grep -ao "setup code [A-Z0-9]*" "$tmp/fp.log" | tail -1 | awk '{print $3}')
client adm adm.log 7 BUILDAT_FP_CODE=$code BUILDAT_FP_CREATE=1 BUILDAT_FP_PASSWORD=adminpass12 \
	BUILDAT_FP_NAME=adm "BUILDAT_FP_ADMIN=$(printf 'add a apass1234\nadd b bpass1234\nadd c cpass1234\nadd d dpass1234')"

# a makes a plan and a group
client a a1.log 7 BUILDAT_FP_PLAN=pa "BUILDAT_FP_GROUP=create 0 friends"
grep -q "a made the group 1 (friends)" "$tmp/fp.log" || fail "no group ($tmp/a1.log)"
# A new account sees no plans
client d d1.log 6
last d1.log "Plans:" | grep -q "Plans: $" || fail "d sees plans: $(last d1.log Plans:)"
echo "ok: a new account sees no plans"

# b online: the invite's dialog at once, accepted; c offline
printf 'wait_log 30000 Invited to the group friends\ndelay 500\nmouse_pos 283 154\nmouse_click left\ndelay 2000\nquit\n' > "$tmp/cb"
CMDS="$tmp/cb" client b b1.log 0 &
cb=$!
sleep 6
client a a2.log 5 "BUILDAT_FP_GROUP=$(printf 'invite 1 b\ninvite 1 c\nshare 1 pa viewer')"
wait $cb
grep -q "b accepted the invite to the group 1" "$tmp/fp.log" || fail "b did not accept ($tmp/b1.log)"
echo "ok: b, online, accepted at once"
printf 'wait_log 30000 Invited to the group friends\ndelay 500\nmouse_pos 356 154\nmouse_click left\ndelay 2000\nquit\n' > "$tmp/cc"
CMDS="$tmp/cc" client c c1.log 0
grep -q "c declined the invite to the group 1" "$tmp/fp.log" || fail "c did not decline ($tmp/c1.log)"
echo "ok: c, at the next join, declined"

# b reads pa and cannot edit it; b's copy is b's alone
client b b2.log 8 BUILDAT_FP_PLAN=pa BUILDAT_FP_COPY=pb
grep -a "Entered the plan pa" -A3 "$tmp/b2.log" | grep -a "Privileges:" | head -1 |
	grep -q "can_edit" && fail "b can edit a read-only share"
grep -q "b copied the plan pa as pb" "$tmp/fp.log" || fail "no copy ($tmp/b2.log)"
client a a3.log 5
last a3.log "Plans:" | grep -q "pb" && fail "a sees b's copy: $(last a3.log Plans:)"
echo "ok: b reads a's plan, cannot edit it, and b's copy is b's alone"

# Editable: b edits; then removed, b is out of the plan and the group
printf 'wait_log 40000 Privileges: can_edit\ndelay 1000\nmouse_pos 254 9\nmouse_click left\nwait_log 40000 no longer let into\ndelay 1000\nquit\n' > "$tmp/cb3"
CMDS="$tmp/cb3" client b b3.log 0 BUILDAT_FP_PLAN=pa &
cb=$!
sleep 10
client a a4.log 4 "BUILDAT_FP_GROUP=share 1 pa editor"
sleep 6
client a a5.log 4 "BUILDAT_FP_GROUP=remove 1 b"
wait $cb
grep -q "b ([0-9]*) is editing pa" "$tmp/fp.log" || fail "b did not edit ($tmp/b3.log)"
echo "ok: an editable share, and b edits"
grep -q "no longer let into" "$tmp/b3.log" || fail "b stayed in pa ($tmp/b3.log)"
client b b4.log 5
last b4.log "Plans:" | grep -q "pa" && fail "b still sees pa"
last b4.log "Groups:" | grep -q "Groups: 0" || fail "b still in the group"
echo "ok: removed, b sees neither a's plan nor the group"

# Past 5 MB: d's plan with 6 MB of pictures, counted from its files
client d d2.log 5 BUILDAT_FP_PLAN=pd
kill -INT $spid; wait $spid 2>/dev/null
dir=$(find "$tmp/fp" -type d -name pd | head -1)
[ -n "$dir" ] || fail "no directory of pd"
head -c 6000000 /dev/zero > "$dir/images/big.png"
server
client d d3.log 5 BUILDAT_FP_PLAN=pe
grep -a "Plan refused: Your plans use" "$tmp/d3.log" ||
	fail "d was not refused ($tmp/d3.log)"
echo "PASS"
