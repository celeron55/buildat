#!/bin/bash
# tier: full
# cost: 160s (2026-10-04)
# covers: builtin/network/network.cpp src/client/state.cpp
# [PEER_TIMEOUT]: a peer the server has not heard from in 60 s is dropped,
# and a client with nothing to say keeps its slot by its keepalive.
#   1. A raw TCP peer that sends nothing: the server closes it at 60 s.
#   2. Beside it, a native client on digger, idle for 150 s: still on at
#      the end, and the server dropped nobody else.
#   3. With WEB=firefox or WEB=chrome: the web client (web/, from
#      util/build_web.sh) idle for 150 s on digger, through
#      util/web_drive.sh: the server dropped nobody.
#
#   util/peer_timeout_check.sh    [WEB=firefox]
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
s=
trap '[ -n "$s" ] && kill $s 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"
P=29583
bin/buildat_server -m ../apps/digger -D "$t/srv" -P $P -l 3 > "$t/srv.log" 2>&1 &
s=$!
for _ in $(seq 120); do
	grep -q "STATUS Listening" "$t/srv.log" && break
	sleep 1
done
grep -q "STATUS Listening" "$t/srv.log" || fail "digger did not start"
printf 'delay 150000\nquit\n' > "$t/seq"
timeout 240 bin/buildat -s localhost:$P -D "$t/u" -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/seq" > "$t/c.log" 2>&1 &
c=$!
# 1
raw=$(python3 - $P <<'PY'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
t0 = time.time()
s.settimeout(120)
try:
    while s.recv(65536):
        pass
except OSError:
    pass
print("%.0f" % (time.time() - t0))
PY
)
[ "$raw" -ge 58 ] && [ "$raw" -le 66 ] || fail "the raw peer went after ${raw} s, not 60"
# 2
wait $c
grep -q "Disconnected from server" "$t/c.log" &&
	fail "the idle client was cut: $(grep 'Disconnected from server' "$t/c.log")"
grep -q "Connect succeeded" "$t/c.log" || fail "the client never connected"
n=$(grep -c "nothing in 60 s; dropping it" "$t/srv.log")
[ "$n" = 1 ] || fail "the server dropped $n peers for silence, not 1: $(grep 'nothing in 60 s; dropping it' "$t/srv.log")"
web=""
if [ -n "${WEB:-}" ]; then
	cat > "$t/steps.json" <<'J'
[["nav", "${URL}"], ["waitlog", "Connect succeeded", 120],
 ["wait", 150000], ["shot", "${OUT}/idle.png"]]
J
	"$here/util/web_drive.sh" "$WEB" digger "$t/steps.json" "$t/web" \
		> "$t/web.log" 2>&1 || fail "the web drive failed: $(tail -3 "$t/web.log")"
	grep -q "nothing in 60 s; dropping it" "$t/web/server.log" &&
		fail "the idle web client was dropped: $(grep 'nothing in 60 s; dropping it' "$t/web/server.log")"
	web="; the $WEB client too"
fi
echo "PASS: a silent peer dropped at ${raw} s; a client idle for 150 s kept$web"
