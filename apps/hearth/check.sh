#!/bin/bash
# tier: full
# cost: 1 min (a first run compiles the app, 2026-10-04)
# covers: apps/hearth/** builtin/network/** 3rdparty/sqlite/CMakeLists.txt
# [HEARTH_MVP] step 1, **the groundwork**:
#   1. the admin (the setup code) adds a topic, starts a thread whose title
#      and message carry markup, replies and edits the reply; adds bob;
#   2. bob replies, and may neither add a topic nor edit the admin's
#      message, nor post a control character, nor say what answered it;
#   3. the admin marks bob's reply the answer and mentions him: bob has
#      both notifications, the admin one for bob's reply;
#   4. a chat: bob has the thread open, the admin writes, and bob's client
#      has the line within two seconds;
#   5. the HTML face: the portal, the topic, the thread (every message,
#      the markup escaped, the edit shown), a message's own page, search
#      (with a hostile query), a 404 for what is not there -- and the web
#      client's page still the web client's.
#
#   apps/hearth/check.sh
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29881
U=http://127.0.0.1:$P

cd "$here/Build"
bin/buildat_server -m ../apps/hearth -D "$t/srv" -P $P -l 3 > "$t/srv.log" 2>&1 &
pid=$!
for _ in $(seq 120); do
	grep -q "setup code" "$t/srv.log" && break
	sleep 1
done
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "Hearth did not start (srv.log: $(tail -3 "$t/srv.log"))"

client(){ # name password log requests [env...]
	local n=$1 pw=$2 log=$3 reqs=$4 ms=${MS:-8000}
	shift 4
	printf 'delay %s\nquit\n' $ms > "$t/cmds_$n"
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw \
		BUILDAT_HEARTH_CODE=$code BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -D "$t/cl_$n" -w 800x600 -l 3 -o sound_mute=1 \
		-s 127.0.0.1:$P -c @"$t/cmds_$n" > "$log" 2>&1
}
answer(){ # log id
	grep -ao "hr: {.*\"id\":$2,.*" "$1" | head -1
}

# 1. The admin
client admin checkpass12 "$t/admin.log" '{"cmd":"new_topic","name":"Help","about":"Questions & answers"}
{"cmd":"new_thread","topic":1,"title":"Lights <b>out</b>","body":"My <script>alert(1)</script> lamp\n\nsecond paragraph about shadows"}
{"cmd":"reply","thread":1,"body":"Try pbr"}
{"cmd":"edit","message":2,"body":"Try the pbr render mode"}
{"cmd":"new_thread","topic":9,"title":"x","body":"y"}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234"
for i in 1001 1002 1003 1004; do
	answer "$t/admin.log" $i | grep -q '"ok":true' ||
		fail "the admin's request $i: $(answer "$t/admin.log" $i)"
done
answer "$t/admin.log" 1005 | grep -q "no such topic" ||
	fail "a thread in no topic: $(answer "$t/admin.log" 1005)"

# 2. bob
client bob bobpass1234 "$t/bob.log" '{"cmd":"reply","thread":1,"body":"bob was here"}
{"cmd":"new_topic","name":"Mine"}
{"cmd":"edit","message":1,"body":"bob wrote this"}
{"cmd":"reply","thread":1,"body":"a\u0007bell"}
{"cmd":"answered","thread":1,"message":3}'
answer "$t/bob.log" 1001 | grep -q '"ok":true' ||
	fail "bob's reply: $(answer "$t/bob.log" 1001) ($(grep -a "accounts" "$t/bob.log" | tail -2))"
answer "$t/bob.log" 1002 | grep -q "only the admin" || fail "bob added a topic"
answer "$t/bob.log" 1003 | grep -q "only its author" || fail "bob edited the admin's"
answer "$t/bob.log" 1004 | grep -q "control character" || fail "a control character went in"
answer "$t/bob.log" 1005 | grep -q "only whoever started" || fail "bob marked the answer"

# 3. The answer, a mention, the notifications
client admin checkpass12 "$t/admin2.log" '{"cmd":"answered","thread":1,"message":3}
{"cmd":"answered","thread":1,"message":1}
{"cmd":"reply","thread":1,"body":"thanks @bob, and mail@bob.example is no one"}
{"cmd":"notifications"}'
answer "$t/admin2.log" 1001 | grep -q '"ok":true' || fail "the answer: $(answer "$t/admin2.log" 1001)"
answer "$t/admin2.log" 1002 | grep -q "not a reply" || fail "the question as its own answer"
answer "$t/admin2.log" 1004 | grep -q '"by":"bob","id":[0-9]*,"kind":"reply"' ||
	fail "the admin's notification of bob's reply: $(answer "$t/admin2.log" 1004)"
client bob bobpass1234 "$t/bob2.log" '{"cmd":"notifications"}'
n=$(answer "$t/bob2.log" 1001)
echo "$n" | grep -q '"kind":"mention"' && echo "$n" | grep -q '"kind":"answer"' ||
	fail "bob's notifications: $n"
[ "$(echo "$n" | grep -o '"kind"' | wc -l)" = 2 ] ||
	fail "bob has other than the mention and the answer: $n"

# 4. A chat: bob has thread 1 open, the admin writes in it
MS=14000 client bob bobpass1234 "$t/watch.log" '' BUILDAT_HEARTH_OPEN=1 &
w=$!
sleep 7
client admin checkpass12 "$t/admin3.log" '{"cmd":"reply","thread":1,"body":"a live line"}'
wait $w
ms(){ # the first log line matching, as milliseconds of the day
	grep -a "$2" "$1" | head -1 | grep -o "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]*" |
		awk -F'[:.]' '{print (($1*60+$2)*60+$3)*1000+$4}'
}
sent=$(ms "$t/admin3.log" '"id":1001,"ok":true')
got=$(ms "$t/watch.log" 'hr: .*a live line')
[ -n "$sent" ] && [ -n "$got" ] || fail "the live line did not reach bob ($sent, $got)"
echo "a chat line reached the other client in $((got - sent)) ms"
[ $((got - sent)) -lt 2000 ] || fail "the line took over two seconds"

# 5. The HTML face
get(){ curl -s -o "$t/page" -w '%{http_code}' "$U$1"; }
[ "$(get /)" = 200 ] && grep -q 'href="/topic/1">Help' "$t/page" &&
	grep -q 'href="/t/1">Lights &lt;b&gt;out' "$t/page" || fail "the portal"
[ "$(get /topic/1)" = 200 ] && grep -q "Questions &amp; answers" "$t/page" &&
	grep -q "answered, admin" "$t/page" || fail "the topic"
[ "$(get /t/1)" = 200 ] || fail "the thread is not served"
grep -q "<script>" "$t/page" && fail "a message's markup reached the page"
grep -q "&lt;script&gt;alert(1)&lt;/script&gt; lamp</p>" "$t/page" ||
	fail "the first message as escaped text"
grep -q "Try the pbr render mode" "$t/page" && grep -q "(edited" "$t/page" ||
	fail "the edit"
grep -q 'id="m3"' "$t/page" && grep -q "bob was here" "$t/page" || fail "bob's reply"
# The answer just after the question
[ "$(grep -o 'id="m[0-9]*"' "$t/page" | head -2 | tr '\n' ' ')" = 'id="m1" id="m3" ' ] &&
	grep -q "This answered it:" "$t/page" || fail "the answer is not under the question"
[ "$(get /m/3)" = 200 ] && grep -q 'href="/t/1#m3"' "$t/page" || fail "a message's page"
[ "$(get "/search?q=shad")" = 200 ] && grep -q "<mark>shadows</mark>" "$t/page" &&
	grep -q 'href="/t/1#m1"' "$t/page" || fail "search: $(grep -a '<li>' "$t/page")"
[ "$(get "/search?q=%22)%20OR%20*%20NEAR(")" = 200 ] || fail "a hostile search"
for p in /t/99 /t/x /topic/ /m/; do
	[ "$(get $p)" = 404 ] || fail "$p is not a 404"
done
grep -q "Hearth" <(curl -s "$U/index.html") && fail "/index.html is Hearth's"
echo "PASS: posted, replied, edited, refused; answered, mentioned, notified; a chat line live; read as HTML with the markup escaped; found by search"
