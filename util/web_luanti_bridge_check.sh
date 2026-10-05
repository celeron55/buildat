#!/bin/bash
# tier: full
# cost: 120s (2026-10-04)
# covers: apps/play/** builtin/network/network.cpp client/extensions/network/init.lua
# [PLAY_PAGE] (c): the web client on apps/play's page reaches a Luanti
# server through the bridge. A Luanti server (~/projects/luanti, devtest)
# on a served Luanti list (BUILDAT_LUANTI_LIST), apps/play serving web/;
# headless Firefox opens the page, picks "Play on a Luanti server",
# connects and logs in, and is refused an address that is not on the
# list.
# Needs web/ from util/build_web.sh.
#   util/web_luanti_bridge_check.sh [steps.json]   (default: the check's own)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_bridge.XXXXXX")
PLAY=29711
LIST=29713
LUANTI=30041
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti}
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

mkdir -p "$tmp/world"
printf 'gameid = devtest\nbackend = sqlite3\nserver_announce = false\n' \
	> "$tmp/world/world.mt"
printf 'mute_sound = true\n' > "$tmp/luanti.conf"
"$bin" --server --world "$tmp/world" --port $LUANTI --config "$tmp/luanti.conf" \
	> "$tmp/luanti.log" 2>&1 &
pids+=($!)
mkdir -p "$tmp/list"
printf '{"list": [{"address": "127.0.0.1", "port": %d, "name": "Bridged"}]}' \
	$LUANTI > "$tmp/list/list"
python3 -m http.server -b 127.0.0.1 -d "$tmp/list" $LIST > "$tmp/list.log" 2>&1 &
pids+=($!)
BUILDAT_CONNECT_PORTS=$LIST BUILDAT_LUANTI_LIST=http://127.0.0.1:$LIST \
	Build/bin/buildat_server -m apps/play -D "$tmp/playsrv" -P $PLAY \
	-l 3 > "$tmp/play.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do grep -q "Luanti's list: 1" "$tmp/play.log" && break; sleep 1; done
grep -q "Luanti's list: 1" "$tmp/play.log" || fail "the list ($tmp/play.log)"
grep -q "Server for gameid" "$tmp/luanti.log" || fail "the Luanti server ($tmp/luanti.log)"

WEB_DRIVE_URL="http://127.0.0.1:$PLAY/" "$here/util/web_drive.sh" firefox play \
	"${1:-$here/util/web_luanti_bridge.json}" "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt, $tmp/drive)"
grep -aq "Logged in" "$tmp/drive/page.log" ||
	fail "no login through the bridge ($tmp/drive/page.log, $tmp/play.log)"
# An address off the list, asked for as the page would
python3 -c '
import socket, sys
c = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
c.sendall(("GET /luanti?to=127.0.0.1:%s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\n"
    "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    "Origin: http://127.0.0.1:%s\r\n\r\n" % (sys.argv[2], sys.argv[1],
    sys.argv[1])).encode())
c.settimeout(5)
c.recv(4096)
' $PLAY $((LUANTI + 1))
sleep 1
grep -q "not on Luanti's list (127.0.0.1:$((LUANTI + 1)))" "$tmp/play.log" ||
	fail "an address off the list was not refused ($tmp/play.log)"
echo "PASS: the play page reaches a listed Luanti server through the bridge, and no other"
