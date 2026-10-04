#!/bin/bash
# tier: full
# cost: 150s (2026-10-04)
# covers: src/client/web/index.html util/web_play_dir.sh util/tls_proxy.py
# [WEB_ID_TRUST] (d): the web client from a fixed origin with no game of
# its own joins a server it is told and signs in there by the Starport's
# window. A Starport with the fixed page's origin in web_clients, Hearth
# listed on it, and a TLS front (util/tls_proxy.py, a self-signed
# certificate) serving util/web_play_dir.sh's directory on one port and
# Hearth on another; headless Firefox opens the page, which starts on the
# launch menu, connects to Hearth's https address, and signs in.
# Needs web/ from util/build_web.sh.
#   util/web_play_check.sh [steps.json]   (default: the check's own)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_webplay.XXXXXX")
SP=29691
AN=29692
PLAY=29694
ANTLS=29695
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
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start"
# simplified: the listing is Hearth's plain address, verified directly; the
# Starport's verifier trusts the system's CAs only, not this check's
mkdir -p "$tmp/h/apps/hearth"
cat > "$tmp/h/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Play hearth", "login": "both",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/hearth -D "$tmp/h" -P $AN -l 3 \
	> "$tmp/h.log" 2>&1 &
pids+=($!)
for _ in $(seq 180); do grep -q "verified ok" "$tmp/sp.log" && break; sleep 1; done
grep -q "verified ok" "$tmp/sp.log" || fail "no verified listing ($tmp/h.log)"

printf 'delay 6000\nquit\n' > "$tmp/cmds.txt"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"web_clients\":[\"https://127.0.0.1:$PLAY\"]}}" \
	timeout 90 Build/bin/buildat -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/sp_admin.log" 2>&1
grep -q "set web_clients" "$tmp/sp.log" ||
	grep -rq "127.0.0.1:$PLAY" "$tmp/sp" || fail "web_clients ($tmp/sp_admin.log)"
python3 - "$SP" <<'PY' || fail "the ID API"
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/id/" % sys.argv[1]
r = json.loads(urllib.request.urlopen(B + "register", json.dumps(dict(
        name="playid", password="secret1",
        birth_year=time.gmtime().tm_year - 40)).encode()).read())
assert r["ok"], r
PY
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/h.log" | tail -1 | cut -d' ' -f3)
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$setup timeout 90 \
	Build/bin/buildat -D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN \
	-c @"$tmp/cmds.txt" > "$tmp/admin.log" 2>&1
grep -q "Joined as admin" "$tmp/admin.log" || fail "the admin's join ($tmp/admin.log)"

util/web_play_dir.sh "$tmp/play" || fail "the play directory"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
	-addext subjectAltName=IP:127.0.0.1 -keyout "$tmp/key.pem" \
	-out "$tmp/cert.pem" 2> /dev/null || fail "openssl"
python3 util/tls_proxy.py "$tmp/cert.pem" "$tmp/key.pem" \
	"$PLAY:$tmp/play" "$ANTLS:127.0.0.1:$AN" > "$tmp/proxy.log" 2>&1 &
pids+=($!)
sleep 1

WEB_DRIVE_INSECURE=1 WEB_DRIVE_URL="https://127.0.0.1:$PLAY/" \
	"$here/util/web_drive.sh" firefox hearth \
	"${1:-$here/util/web_play.json}" "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt, $tmp/drive)"
grep -q "Client .* connected (WebSocket) through" "$tmp/h.log" ||
	fail "no join through the TLS front ($tmp/h.log)"
grep -aq "Joined as playname" "$tmp/drive/page.log" ||
	fail "the web client did not join by the ID ($tmp/drive/page.log)"
echo "PASS: the fixed-origin page joins a server it is told, by the Starport's window"
