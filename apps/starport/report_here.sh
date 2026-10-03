#!/bin/bash
# tier: full
# cost: 60s a run, seven runs (2026-10-02)
# covers: client/extensions/starport/** apps/starport/main/** builtin/starport_announce/**
# [REPORT_HERE]: "Report this server..." finds the listing of the server
# a native client is on. A local Starport, a floorplanner listed and
# claimed on it, and a player's client with only that Starport, which
# opens the report from the plan picker's menu by the keyboard. Each run is
# one combination of the public address in starport.json (with the port,
# without it, none) and the address the client joined by (with the port,
# without it); and one where the listing is under another name for the
# same host, which must offer the listing to pick.
#
#   apps/starport/report_here.sh            all of them
#   apps/starport/report_here.sh ADDR JOIN  one: the public address
#                                           ("" for none) and -s
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
if [ $# -lt 2 ]; then
	fail=0
	for combo in "127.0.0.1:29500|127.0.0.1:29500" "127.0.0.1:29500|127.0.0.1" \
			"127.0.0.1|127.0.0.1:29500" "127.0.0.1|127.0.0.1" \
			"|127.0.0.1:29500" "|127.0.0.1"; do
		a=${combo%%|*} c=${combo##*|}
		r=$("$0" "$a" "$c" | grep "report here: connected")
		echo "public '$a', joined '$c': ${r##*; }"
		echo "$r" | grep -q "; found$" || fail=1
	done
	r=$("$0" "localhost:29500" "127.0.0.1:29500" | grep "report here:")
	echo "listed as localhost, joined as 127.0.0.1: $(echo "$r" | tail -1 | sed 's/.*report here: //')"
	echo "$r" | grep -q "NOT FOUND" && echo "$r" | grep -q " 1 listings offered" || fail=1
	[ $fail = 0 ] && echo "PASS: the report finds the listing however the address was written" ||
		echo "FAIL: a listing was not found, or not offered (local/report_here/)"
	exit $fail
fi
tmp=$here/local/report_here; rm -rf $tmp; mkdir -p $tmp/sp $tmp/an/apps/floorplanner $tmp/cl $tmp/fc
SP=29641; AN=29500
pids=()
stop() { for p in "${pids[@]}"; do kill -INT $p 2>/dev/null; done
	for _ in $(seq 30); do ss -ltn | grep -qE ":(29500|29641) " || break; sleep 1; done; }
trap stop EXIT
addr=""
[ -n "$1" ] && addr="\"address\": \"$1\","
cat > $tmp/an/apps/floorplanner/starport.json <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Check house", $addr
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
cd "$here"
Build/bin/buildat_server -m apps/starport -D $tmp/sp -P $SP -l 3 > $tmp/sp.log 2>&1 & pids+=($!)
for _ in $(seq 120); do grep -q "setup code" $tmp/sp.log && break; sleep 1; done
code=$(grep -o "setup code [A-Z0-9]*" $tmp/sp.log | cut -d' ' -f3)
Build/bin/buildat_server -m apps/floorplanner -D $tmp/an -P $AN -l 3 > $tmp/an.log 2>&1 & pids+=($!)
for _ in $(seq 120); do grep -q "verified ok" $tmp/sp.log && break; sleep 1; done
read -r _ _ id _ _ ccode < <(grep -v "^#" $tmp/an/apps/floorplanner/starport_claim.txt)
printf 'delay 6000\nquit\n' > $tmp/cmds.txt
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 Build/bin/buildat -D $tmp/cl -w 800x600 -l 3 -s 127.0.0.1:$SP -c @$tmp/cmds.txt > $tmp/cl.log 2>&1
curl -s 127.0.0.1:$SP/api/list | python3 -c "import json,sys; print('listed:', [(s['host'],s['port'],s.get('tls')) for s in json.load(sys.stdin)['servers']])"
# The player's client: this Starport only, accepted
now=$(date +%s)
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > $tmp/fc/starport.json
printf 'accepted,address,description,created,last_attempt,name\n"true","http://127.0.0.1","","%s","%s",""\n' $now $now > $tmp/fc/network_addresses.csv
fpcode=$(grep -ao "setup code [A-Z0-9]*" $tmp/an.log | tail -1 | awk '{print $3}')
cat > $tmp/fcmds.txt <<C
delay 7000
keypress down
keypress m
keypress return
delay 1500
keypress r
keypress return
delay 4000
screenshot $tmp/report.png
quit
C
BUILDAT_FP_NAME=op BUILDAT_FP_PASSWORD=pw123456 BUILDAT_FP_CODE=$fpcode \
	timeout 90 Build/bin/buildat -D $tmp/fc -w 800x500 -l 3 -s "$2" -c @$tmp/fcmds.txt 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > $tmp/fc.log
grep -a "report here" $tmp/fc.log | sed 's/.*extensio: //'
