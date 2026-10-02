#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 13s (local, 2026-10-02)
# [STARPORT] end to end, on ports of its own in a directory of its own: a
# Starport, and a floorplanner server listed on it by starport.json.
#   1. The announce gets a listing; the challenge verifies it.
#   2. Unclaimed, it is not served; a scripted client (the admin, by the
#      setup code) claims it with the claim code, and then it is.
#   3. A report by a key gets a receipt; the moderator rejects it; the
#      reporter's key asks and gets the outcome.
#   4. The admin makes a fleet; a second server with the fleet's line in
#      its starport.json is served in it without anyone claiming it.
#
#   KEEP_TMP=1 apps/starport/check.sh
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_starport.XXXXXX")
SP=29641
AN=29642
AN2=29643
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
api() { curl -s -m 10 "$@"; }

mkdir -p "$tmp/sp" "$tmp/an/apps/floorplanner" "$tmp/an2/apps/floorplanner" \
	"$tmp/cl"
cat > "$tmp/an/apps/floorplanner/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], "name": "Check house",
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
EOF
cd "$here"
Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -P $SP -l 3 \
	> "$tmp/sp.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do
	grep -q "setup code" "$tmp/sp.log" && break
	sleep 1
done
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start (sp.log)"

Build/bin/buildat_server -m apps/floorplanner -D "$tmp/an" -P $AN -l 3 \
	> "$tmp/an.log" 2>&1 &
pids+=($!)
claim="$tmp/an/apps/floorplanner/starport_claim.txt"
for _ in $(seq 120); do
	grep -q "verified ok" "$tmp/sp.log" && break
	sleep 1
done
grep -q "verified ok" "$tmp/sp.log" || fail "no verified listing (sp.log, an.log)"
read -r _ _ id _ _ ccode < <(grep -v "^#" "$claim")
echo "ok: listed as $id and verified"

api "localhost:$SP/api/list" | grep -q "\"$id\"" &&
	fail "an unclaimed listing was served"
echo "ok: unclaimed, not served"

key=$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
receipt=$(api -d "{\"listing\":\"$id\",\"reason\":\"spam\",\"key\":\"$key\"}" \
	"localhost:$SP/api/report" | python3 -c \
	"import json,sys; print(json.load(sys.stdin)['receipt'])") ||
	fail "no receipt for a report"
echo "ok: report receipt $receipt"

# The admin's client: claim, then reject the report
printf 'delay 8000\nquit\n' > "$tmp/cmds.txt"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}
{\"cmd\":\"decide\",\"group\":\"$id|spam\",\"decision\":\"dismiss\"}
{\"cmd\":\"fleet_create\",\"name\":\"Check fleet\"}" \
	timeout 90 Build/bin/buildat -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/cl.log" 2>&1
n=$(grep -c 'sp: {"id":[0-9]*,"ok":true' "$tmp/cl.log")
[ "$n" -ge 5 ] || fail "$n of 5 commands went through (cl.log)"

api "localhost:$SP/api/list" | grep -q "\"$id\"" ||
	fail "the claimed listing is not served"
echo "ok: claimed and served"

api -d "{\"key\":\"$key\",\"receipts\":[\"$receipt\"]}" \
	"localhost:$SP/api/report_status" | grep -q '"state":"rejected"' ||
	fail "the reporter does not see the outcome"
echo "ok: the reporter sees the report rejected"

fleet=$(grep -o '"code":"[0-9a-f]*","description":"","id":"[0-9a-f]*"' \
	"$tmp/cl.log" | head -1 | sed 's/"code":"\([0-9a-f]*\)".*"id":"\([0-9a-f]*\)"/\2:\1/')
[ -n "$fleet" ] || fail "no fleet made (cl.log)"
sed "s/\"Check house\"/\"Check main\", \"fleet\": \"$fleet\", \"pool\": \"main\"/" \
	"$tmp/an/apps/floorplanner/starport.json" \
	> "$tmp/an2/apps/floorplanner/starport.json"
Build/bin/buildat_server -m apps/floorplanner -D "$tmp/an2" -P $AN2 -l 3 \
	> "$tmp/an2.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do
	[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge 2 ] && break
	sleep 1
done
api "localhost:$SP/api/list" | python3 -c "
import json, sys
s = [x for x in json.load(sys.stdin)['servers'] if x['name'] == 'Check main']
assert s and s[0]['fleet']['name'] == 'Check fleet' and s[0]['pool'] == 'main', s
" || fail "the fleet's server is not served in the fleet (sp.log, an2.log)"
echo "ok: a server joined the fleet by its config line"
echo PASS
