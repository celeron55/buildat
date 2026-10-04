#!/bin/bash
# tier: full
# cost: 60s (2026-10-04)
# covers: builtin/starport_announce/** builtin/accounts/accounts.cpp apps/starport/main/main.cpp
# [STARPORT_DEFAULT_URL]: a fresh Hearth whose IDs stay off announces
# nothing; its admin turning IDs on ("anyone", with the https address the
# admin reached it by, as the users page sends it) announces it, unlisted,
# to the default Starport (BUILDAT_STARPORT_DEFAULT: a local one here) at
# that address, with no name, kind or audience set and the listing never
# claimed; it is verified over TLS, is not in the list, and an ID joins.
#   util/starport_default_url_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_spdef.XXXXXX")
SP=29761
AN=29762
ANTLS=29765
export BUILDAT_CONNECT_PORTS="$SP,$AN,$ANTLS"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
	-addext subjectAltName=IP:127.0.0.1 -keyout "$tmp/key.pem" \
	-out "$tmp/cert.pem" 2> /dev/null || fail "openssl"
python3 util/tls_proxy.py "$tmp/cert.pem" "$tmp/key.pem" \
	"$ANTLS:127.0.0.1:$AN" > "$tmp/proxy.log" 2>&1 &
pids+=($!)
mkdir -p "$tmp/sp/shared"
cp "$tmp/cert.pem" "$tmp/sp/shared/check_ca.pem"
BUILDAT_CA_FILE=$tmp/sp/shared/check_ca.pem Build/bin/buildat_server \
	-m apps/starport -D "$tmp/sp" -P $SP -l 3 > "$tmp/sp.log" 2>&1 &
pids+=($!)
BUILDAT_STARPORT_DEFAULT=http://127.0.0.1:$SP Build/bin/buildat_server \
	-m apps/hearth -D "$tmp/an" -P $AN -l 3 > "$tmp/hearth.log" 2>&1 &
pids+=($!)
for _ in $(seq 180); do grep -q "setup code" "$tmp/hearth.log" && break; sleep 1; done
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/hearth.log" | tail -1 | cut -d' ' -f3)
[ -n "$setup" ] || fail "Hearth did not start ($tmp/hearth.log)"
sleep 3
json=$tmp/an/apps/hearth/starport.json
[ -e "$json" ] && fail "a starport.json with nobody asking for one"
grep -q "Announcing to" "$tmp/hearth.log" && fail "announced with IDs off"
echo "ok: IDs off and the page never opened, nothing announced"

printf 'delay 6000\nquit\n' > "$tmp/cmds.txt"
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$setup \
	BUILDAT_HEARTH_ADMIN="setting starport_ids anyone https://127.0.0.1:$ANTLS" \
	timeout 90 Build/bin/buildat -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$AN -c @"$tmp/cmds.txt" > "$tmp/admin.log" 2>&1
grep -q "Joined as admin" "$tmp/admin.log" || fail "the admin's join ($tmp/admin.log)"
python3 - "$json" "$SP" "$ANTLS" <<'PY' || fail "starport.json ($json)"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["starports"] == ["http://127.0.0.1:" + sys.argv[2]], c
assert c["unlisted"] is True and c["ids"] == "anyone", c
assert c["address"] == "https://127.0.0.1:" + sys.argv[3], c
assert "name" not in c and "kind" not in c and "audience" not in c, c
PY
for _ in $(seq 120); do grep -q "verified ok" "$tmp/sp.log" && break; sleep 1; done
grep -q "verified ok" "$tmp/sp.log" || fail "no verified listing ($tmp/sp.log)"
read -r _ _ id _ < <(grep -v "^#" "$tmp/an/apps/hearth/starport_claim.txt")
[ -n "$id" ] || fail "no listing id"
curl -s -m 10 "localhost:$SP/api/list" | grep -q "\"$id\"" &&
	fail "the unlisted listing is in the list"
echo "ok: announced unlisted to the default Starport at the admin's https address"

token=$(python3 - "$SP" "$id" <<'PY'
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
r = call("id/register", name="defid", password="secret1",
        birth_year=time.gmtime().tm_year - 40)
assert r["ok"], r
r = call("id/token", session=r["result"]["session"], listing=sys.argv[2],
        name="fromid")
assert r["ok"], r
print(r["result"]["token"])
PY
) || fail "the ID API ($tmp/sp.log)"
BUILDAT_HEARTH_STARPORT=$token timeout 90 Build/bin/buildat -D "$tmp/cl" \
	-w 800x600 -l 3 -s 127.0.0.1:$AN -c @"$tmp/cmds.txt" > "$tmp/id.log" 2>&1
grep -q "Joined as fromid" "$tmp/id.log" ||
	fail "the ID did not join ($tmp/id.log, $tmp/hearth.log)"
echo "PASS: IDs turned on announce to the default Starport, unlisted and unclaimed, and an ID joins"
