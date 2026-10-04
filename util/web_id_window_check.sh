#!/bin/bash
# tier: full
# cost: 120s (2026-10-04)
# covers: apps/starport/main/main.cpp client/extensions/starport/init.lua builtin/starport_announce/** src/client/app.cpp
# [WEB_ID_TRUST] (a): a web client signs in with a Starport ID in the
# Starport's own window. A Starport, Hearth listed on it with IDs on and
# serving the web client, and an ID made by the API; headless Firefox
# (the window step is Firefox's) opens Hearth's page, clicks "Sign in with
# your Starport ID", Open, and in the Starport's /authorize window logs in,
# allows, names itself and allows; the token comes back to Hearth's page
# by postMessage and the join is by it. Also by the API: /authorize is
# never framed, the API answers any origin, a token for an origin that is
# neither the listing's nor in web_clients is refused, and so is a password
# login from any page but the Starport's own (an Origin header not its
# Host).
# Needs web/ from util/build_web.sh.
#   util/web_id_window_check.sh [steps.json]   (default: the check's own)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_webid.XXXXXX")
SP=29671
AN=29672
export BUILDAT_CONNECT_PORTS="$SP,$AN"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -P $SP -l 3 \
	> "$tmp/sp.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do grep -q "setup code" "$tmp/sp.log" && break; sleep 1; done
grep -q "setup code" "$tmp/sp.log" || fail "the Starport did not start"
mkdir -p "$tmp/h/apps/hearth"
cat > "$tmp/h/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Web hearth", "login": "both",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/hearth -D "$tmp/h" -P $AN -W "$here/web" -l 3 \
	> "$tmp/h.log" 2>&1 &
pids+=($!)
for _ in $(seq 180); do grep -q "verified ok" "$tmp/sp.log" && break; sleep 1; done
grep -q "verified ok" "$tmp/sp.log" || fail "no verified listing ($tmp/h.log)"
read -r _ _ id _ < <(grep -v "^#" "$tmp/h/apps/hearth/starport_claim.txt")

curl -si "localhost:$SP/authorize?listing=$id" | grep -qi "^X-Frame-Options: DENY" ||
	fail "/authorize may be framed"
curl -si -X POST -d '{}' "localhost:$SP/api/list" |
	grep -qi "^Access-Control-Allow-Origin: \*" || fail "no CORS on the API"
python3 - "$SP" "$id" "$AN" <<'PY' || fail "the ID API"
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/id/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
own = "http://127.0.0.1:" + sys.argv[3]
r = call("authorize_info", listing=sys.argv[2], web=True)
assert r["ok"] and r["result"]["origin"] == own, r
r = call("register", name="webid", password="secret1",
        birth_year=time.gmtime().tm_year - 40)
assert r["ok"], r
s = r["result"]["session"]
r = call("token", session=s, listing=sys.argv[2], web=True,
        origin="https://evil.example", name="x")
assert not r["ok"] and "sends no tokens" in r["error"], r
print("ok: a token for another origin is refused")
def from_page(origin, w, **k):
    q = urllib.request.Request(B + w, json.dumps(k).encode(),
            {"Origin": origin})
    return json.loads(urllib.request.urlopen(q).read())
r = from_page(own, "login", name="webid", password="secret1")
assert not r["ok"] and "own page" in r["error"], r
r = from_page("http://127.0.0.1:" + sys.argv[1], "login", name="webid",
        password="secret1")
assert r["ok"], r
print("ok: a password login from a game server's page is refused")
PY

# The first admin, natively, so the web join is an ID's ordinary one
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/h.log" | tail -1 | cut -d' ' -f3)
printf 'delay 6000\nquit\n' > "$tmp/cmds.txt"
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$setup timeout 90 \
	Build/bin/buildat -D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN \
	-c @"$tmp/cmds.txt" > "$tmp/admin.log" 2>&1
grep -q "Joined as admin" "$tmp/admin.log" || fail "the admin's join ($tmp/admin.log)"

WEB_DRIVE_URL="http://127.0.0.1:$AN/" "$here/util/web_drive.sh" firefox hearth \
	"${1:-$here/util/web_id_window.json}" "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt, $tmp/drive)"
grep -aq "Joined as webname" "$tmp/drive/page.log" ||
	fail "the web client did not join by the ID ($tmp/drive/page.log)"
echo "PASS: a web client signs in by the Starport's window"
