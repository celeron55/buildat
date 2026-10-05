#!/bin/bash
# tier: full
# cost: 90s (2026-10-04)
# covers: builtin/network/network.cpp src/impl/tcpsocket.cpp src/client/app.cpp
# [LAN_DISCOVERY]: a server announces itself on the LAN's group only when
# told to, and a client's list holds a flood of false ones to 32.
#   1. digger with --lan-announce: an announcement with its name and port
#      is heard on 239.255.29.50:29599 within 5 s.
#   2. digger without it: nothing from its port in 5 s.
#   3. 100 false announcements (other ports, control characters in the
#      name) while a client shows the connect screen: the client says its
#      list is full, and the screenshot shows 32 at most.
#
#   util/lan_check.sh    (SHOT=x.png keeps the screenshot)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
s=
trap '[ -n "$s" ] && kill $s 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"

# hear <port> <seconds>: the first announcement for that port, or nothing
hear(){
	python3 - "$1" "$2" <<'EOF'
import socket, struct, sys, time, json
port, secs = int(sys.argv[1]), float(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind(("", 29599))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
        struct.pack("4s4s", socket.inet_aton("239.255.29.50"),
        socket.inet_aton("0.0.0.0")))
end = time.time() + secs
while time.time() < end:
    s.settimeout(max(0.01, end - time.time()))
    try:
        d, _ = s.recvfrom(1500)
    except socket.timeout:
        break
    try:
        v = json.loads(d)
    except ValueError:
        continue
    if v.get("port") == port:
        print(d.decode())
        break
EOF
}

# start <port> [args]: digger, until it listens
start(){
	local port=$1; shift
	bin/buildat_server -m ../apps/digger -D "$t/srv$port" -P "$port" -l 3 \
		"$@" > "$t/srv$port.log" 2>&1 &
	s=$!
	for _ in $(seq 120); do
		grep -q "STATUS Listening" "$t/srv$port.log" && return
		sleep 1
	done
	fail "digger did not start ($(tail -3 "$t/srv$port.log"))"
}

# 1
start 29581 --lan-announce "LAN check"
a=$(hear 29581 5)
echo "$a" | grep -q '"name":"LAN check"' || fail "no announcement heard: '$a'"
echo "$a" | grep -q '"app":"digger"' || fail "the app is missing: $a"
kill $s; wait $s 2>/dev/null; s=

# 2
start 29582
a=$(hear 29582 5)
[ -z "$a" ] || fail "announced without --lan-announce: $a"
kill $s; wait $s 2>/dev/null; s=

# 3
printf 'wait_log 10000 LAN list full\ndelay 1500\nscreenshot %s/flood.png\nquit\n' \
	"$t" > "$t/seq"
timeout 60 bin/buildat -D "$t/u" -w 1280x720 -u 1 -l 3 -o sound_mute=1 \
	-a extension/launch_menu/connect -c @"$t/seq" > "$t/c.log" 2>&1 &
c=$!
sleep 3
python3 - <<'EOF'
import socket, json, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
for r in range(4):
    for p in range(20000, 20100):
        s.sendto(json.dumps({"buildat_lan": 1, "name": "fake\x01\n%d" % p +
                "x" * 200, "app": "../evil", "version": "1", "port": p,
                "players": -5}).encode(), ("239.255.29.50", 29599))
    time.sleep(1)
EOF
wait $c
grep -q "LAN list full (32)" "$t/c.log" || fail "the list was not capped ($(grep -i lan "$t/c.log" | tail -3))"
grep -q "Wrote screenshot" "$t/c.log" || fail "no screenshot"
[ -n "${SHOT:-}" ] && cp "$t/flood.png" "$SHOT"
echo "PASS: announced only with --lan-announce; a flood capped at 32"
