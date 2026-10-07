#!/bin/bash
# tier: full
# cost: 60s (2026-10-07)
# covers: apps/starport/main/main.cpp builtin/starport_announce/starport_announce.cpp builtin/network/network.cpp extensions/launch_menu/screens.lua src/client/app.cpp
# [PLAY_LINKS]: a Starport with a play_url hands it out in /api/list and
# in its answer to an announce; the listed server then lets that page's
# WebSocket in, and no other page's. A client given BUILDAT_JOIN (the
# play page's ?server=) joins a server a Starport lists, not one it does
# not list, and nothing for an address of another shape.
# Not here: the page at / links a TLS server only, and a local one has
# no TLS -- seen on the live Starport.
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_plinks.XXXXXX")
SP=29681
HE=29682
PLAY=http://127.0.0.1:29683
export BUILDAT_CONNECT_PORTS="$SP,$HE"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
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
printf 'delay 8000\nquit\n' > "$tmp/cmds.txt"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"play_url\":\"$PLAY/\",\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/admin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/admin.log" 2>&1
curl -s -m 10 "localhost:$SP/api/list" | grep -q "\"play\":\"$PLAY\"" ||
	fail "/api/list has no play ($tmp/admin.log)"
echo "ok: /api/list carries the play page"

# A Hearth listed there
mkdir -p "$tmp/he/apps/hearth"
cat > "$tmp/he/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Linked hearth", "login": "both",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/hearth -D "$tmp/he" -P $HE -l 3 \
	> "$tmp/he.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do
	grep -q "verified ok" "$tmp/sp.log" && break
	sleep 1
done
grep -q "verified ok" "$tmp/sp.log" || fail "the Hearth was not verified (he.log)"
read -r _ _ id _ _ ccode < <(grep -v "^#" "$tmp/he/apps/hearth/starport_claim.txt")
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass \
BUILDAT_SP_REQS="{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/admin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/admin2.log" 2>&1
curl -s -m 10 "localhost:$SP/api/list" | grep -q "Linked hearth" ||
	fail "the claim ($tmp/admin2.log)"
ws() { # origin -> the status line
	curl -s -i -m 3 -H "Connection: Upgrade" -H "Upgrade: websocket" \
		-H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
		-H "Origin: $1" "http://127.0.0.1:$HE/" | head -1
}
ws "$PLAY" | grep -q " 101 " || fail "the play page's WebSocket refused ($tmp/he.log)"
echo "ok: the play page's WebSocket let in"
ws "http://127.0.0.1:29684" | grep -q " 101 " && fail "another page's WebSocket let in"
echo "ok: another page's WebSocket refused"

mkdir -p "$tmp/cl"
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > "$tmp/cl/starport.json"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP $(date +%s) $(date +%s) > "$tmp/cl/network_addresses.csv"
printf 'delay 12000\nquit\n' > "$tmp/c"
client() { # BUILDAT_JOIN log
	BUILDAT_JOIN=$1 timeout 60 Build/bin/buildat -o launch_ui=launch_menu \
		-D "$tmp/cl" -w 800x600 -l 3 -o sound_mute=1 -c @"$tmp/c" > "$2" 2>&1
}
client "127.0.0.1:$HE" "$tmp/c1.log"
grep -q "Connect succeeded (127.0.0.1:$HE)" "$tmp/c1.log" ||
	fail "a listed server not joined ($tmp/c1.log)"
echo "ok: a listed server joined"
client "127.0.0.1:29685" "$tmp/c2.log"
grep -q "is not listed; not joined" "$tmp/c2.log" ||
	fail "an unlisted one not said ($tmp/c2.log)"
grep -q "Connect succeeded" "$tmp/c2.log" && fail "an unlisted one joined"
echo "ok: an unlisted server not joined"
client "127.0.0.1:1');os.exit(3)--" "$tmp/c3.log"
grep -q "BUILDAT_JOIN is not host:port" "$tmp/c3.log" ||
	fail "a bad one not refused ($tmp/c3.log)"
grep -q "A link asks" "$tmp/c3.log" && fail "a bad one went into the script"
echo "ok: another shape refused"
echo "PASS"
