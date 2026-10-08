#!/bin/bash
# tier: quick
# cost: ~60 s (2026-10-08)
# covers: apps/hearth/main/main.cpp
# [HEARTH_DISCUSSED_API]: GET /api/discussed. Empty first ({}). Then bob, a
# member, writes two days ago and today; carol, a new account, twice today;
# eve, a helper, today, and that one hidden. Neither carol's nor eve's
# counts, so today has one and the week two: span "this week", a message of
# bob's, its excerpt plain (no markup, the link as its text), its URL
# opening the message, and the CORS header there.
#
#   apps/hearth/discussed_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29887
API=http://127.0.0.1:$P/api/discussed

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
	bin/buildat_server --sim-clock -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
pid=$SERVER_PID
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # name password requests [env...]
	local n=$1 pw=$2 reqs=$3
	shift 3
	printf 'delay 4000\nquit\n' > "$t/cmds_$n"
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds_$n" >> "$t/$n.log" 2>&1
}
T=0
advance(){
	T=$((T + $1))
	echo $T > "$t/srv/sim_clock"
	for _i in $(seq 100); do
		grep -aq "sim clock: ${T}s ahead" "$t/srv.log" && return
		sleep 0.1
	done
	fail "the server did not take the clock to $T"
}

[ "$(curl -s "$API")" = "{}" ] || fail "not {} with nothing written"

client admin checkpass12 '{"cmd":"new_topic","name":"Main","about":"x"}
{"cmd":"trust","name":"bob","on":true}
{"cmd":"level","name":"eve","level":20}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234
add carol carolpass1234
add eve evepass12345"
grep -aq 'hr: {"id":1003,"ok":true' "$t/admin.log" || fail "the setup"
MD='First **one** with [the site](https://example.com/x) and <b>raw</b> `code` here'
client bob bobpass1234 "{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Week\",\"body\":\"$MD\"}"
advance $((2 * 86400))
client bob bobpass1234 "{\"cmd\":\"reply\",\"thread\":1,\"body\":\"$MD\"}"
client carol carolpass1234 '{"cmd":"new_thread","topic":1,"title":"C1","body":"carol one"}
{"cmd":"new_thread","topic":1,"title":"C2","body":"carol two"}'
client eve evepass12345 '{"cmd":"new_thread","topic":1,"title":"E","body":"eve hidden"}'
# Eve's message, 5, reported and hidden by the admin
client admin checkpass12 '{"cmd":"report","message":5,"reason":"x"}
{"cmd":"moderate","report":1,"action":"hide","statement":"x"}'
grep -aq 'hr: {"id":1002,"ok":true' "$t/admin.log" || fail "the hide"
for f in bob carol eve; do
	grep -aq '"ok":false' "$t/$f.log" &&
		fail "$f: $(grep -ao '"error":"[^"]*"' "$t/$f.log" | head -1)"
done
# The last pick was {} at T 0; ten minutes on, a new one
advance 600

curl -s -D "$t/headers" "$API" > "$t/api.json" || fail "the request"
cat "$t/api.json"; echo
grep -qi '^access-control-allow-origin: \*' "$t/headers" || fail "no CORS header"
python3 - "$t/api.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
def fail(s):
    print("FAIL: " + s); sys.exit(1)
if d.get("span") != "this week":
    fail("span %r, not this week" % d.get("span"))
m = d["message"]
if m["author"] != "bob" or m["id"] not in (1, 2):
    fail("picked %s's %s" % (m["author"], m["id"]))
e = m["excerpt"]
want = "First one with the site and <b>raw</b> code here"
if e != want:
    fail("excerpt %r, not %r" % (e, want))
if not m["url"].endswith("/m/%d" % m["id"]) or "/t/1" not in m["thread"]["url"] \
        or "/topic/1" not in m["topic"]["url"]:
    fail("the links")
PY
url=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["message"]["url"])' "$t/api.json")
curl -s "$url" | grep -q 'the site' || fail "$url does not open the message"
[ "$(curl -s "$API")" = "$(cat "$t/api.json")" ] || fail "the pick changed within ten minutes"
echo "PASS: /api/discussed: this week's pick, a member's, plain, its links open, CORS"
