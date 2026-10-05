#!/bin/bash
# tier: full
# cost: 1 min (a first run compiles the app, 2026-10-04)
# covers: apps/hearth/** src/interface/web_brand.h builtin/network/** 3rdparty/sqlite/CMakeLists.txt
# [HEARTH_MVP] step 1, **the groundwork**:
#   1. the admin (the setup code) adds a topic and a subtopic (not a
#      subtopic's subtopic), starts a thread whose title
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
#      client's page still the web client's;
#   6. a new account's limits (no links, two threads a day, edits count
#      as messages) and a report's handling: carol reports bob's thread,
#      the admin hides it with a statement (gone from the portal and search,
#      the notice on its page, bob notified with the statement), bob
#      appeals (and may not edit it while hidden), carol sees neither
#      its title nor its messages by packet or /m/, the admin restores; then the search limit per
#      address and per account.
#   7. files: a new account uploads none; a JPEG comes back within 1080p
#      and without its EXIF; over the budget an unused one is crushed again,
#      and past its time deleted.
#
#   apps/hearth/check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"' EXIT
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
	printf "${CMDS:-delay %s\\nquit\\n}" $ms > "$t/cmds_$n"
	# CREATE: an unknown name is made rather than refused; a known one logs in
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw BUILDAT_HEARTH_CREATE=1 \
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
{"cmd":"new_thread","topic":9,"title":"x","body":"y"}
{"cmd":"new_topic","name":"Lamps","parent":1}
{"cmd":"new_topic","name":"Deeper","parent":2}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234"
for i in 1001 1002 1003 1004; do
	answer "$t/admin.log" $i | grep -q '"ok":true' ||
		fail "the admin's request $i: $(answer "$t/admin.log" $i)"
done
answer "$t/admin.log" 1005 | grep -q "no such topic" ||
	fail "a thread in no topic: $(answer "$t/admin.log" 1005)"
answer "$t/admin.log" 1006 | grep -q '"ok":true' ||
	fail "a subtopic: $(answer "$t/admin.log" 1006)"
answer "$t/admin.log" 1007 | grep -q "cannot have subtopics" ||
	fail "a subtopic's subtopic: $(answer "$t/admin.log" 1007)"

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
{"cmd":"notifications"}
{"cmd":"answered","thread":1,"message":0}
{"cmd":"answered","thread":1,"message":3}'
answer "$t/admin2.log" 1001 | grep -q '"ok":true' || fail "the answer: $(answer "$t/admin2.log" 1001)"
answer "$t/admin2.log" 1002 | grep -q "not a reply" || fail "the question as its own answer"
answer "$t/admin2.log" 1004 | grep -q '"by":"bob","id":[0-9]*,"kind":"reply"' ||
	fail "the admin's notification of bob's reply: $(answer "$t/admin2.log" 1004)"
client bob bobpass1234 "$t/bob2.log" '{"cmd":"notifications"}'
n=$(answer "$t/bob2.log" 1001)
echo "$n" | grep -q '"kind":"mention"' && echo "$n" | grep -q '"kind":"answer"' ||
	fail "bob's notifications: $n"
[ "$(echo "$n" | grep -o '"kind"' | wc -l)" = 2 ] ||
	fail "bob has other than the mention and the answer (given twice, told once): $n"

# 4. A chat: bob has thread 1 open, the admin writes in it
MS=14000 client bob bobpass1234 "$t/watch.log" '' BUILDAT_HEARTH_OPEN=1 &
w=$!
sleep 7
client admin checkpass12 "$t/admin3.log" '{"cmd":"reply","thread":1,"body":"a live line"}' \
	"BUILDAT_HEARTH_ADMIN=add carol carolpass1234"
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
# [HTML_BRAND]: the font and the logo from the page's own origin
[ "$(get /brand/overpass.ttf)" = 200 ] && [ "$(get /brand/logo.png)" = 200 ] ||
	fail "the brand's files"
[ "$(get /)" = 200 ] && grep -Eq '(src=|url\()"?(https?:)?//' "$t/page" &&
	fail "the portal loads from another origin"

# 6. A new account's limits, a report, a hide, an appeal
client bob bobpass1234 "$t/bob6.log" '{"cmd":"new_thread","topic":1,"title":"Lamps","body":"see www.lamps.example"}
{"cmd":"new_thread","topic":1,"title":"Cheap lamps","body":"Cheap lamps for everyone"}
{"cmd":"new_thread","topic":1,"title":"More","body":"one more"}
{"cmd":"new_thread","topic":1,"title":"Again","body":"and again"}
{"cmd":"report","message":3,"reason":"mine"}
{"cmd":"reply","thread":1,"body":"[lamps](//lamps.example)"}'"$(
	for i in $(seq 10); do printf '\n{"cmd":"edit","message":3,"body":"b%s"}' $i; done)"
grep -aq 'hr: {.*"level":0' "$t/bob6.log" || fail "bob is not a new account"
answer "$t/bob6.log" 1001 | grep -q "no links yet (a new account" || fail "a new account's link"
answer "$t/bob6.log" 1002 | grep -q '"result":2' || fail "bob's thread: $(answer "$t/bob6.log" 1002)"
answer "$t/bob6.log" 1003 | grep -q '"ok":true' || fail "bob's second thread"
answer "$t/bob6.log" 1004 | grep -q "2 new threads a day" || fail "a third thread in a day"
answer "$t/bob6.log" 1005 | grep -q "one's own" || fail "bob reported his own"
answer "$t/bob6.log" 1006 | grep -q "no links yet" || fail "a link the markup makes"
answer "$t/bob6.log" 1016 | grep -q "messages an hour" || fail "edits without a limit"
client carol carolpass1234 "$t/carol.log" '{"cmd":"report","message":6,"reason":"spam"}
{"cmd":"report","message":6,"reason":"spam!"}
{"cmd":"report","message":2,"reason":"rude"}'
answer "$t/carol.log" 1001 | grep -q '"result":1' || fail "carol's report: $(answer "$t/carol.log" 1001)"
answer "$t/carol.log" 1002 | grep -q "waiting already" || fail "a report twice"
answer "$t/carol.log" 1003 | grep -q '"result":2' || fail "carol's second report"
client admin checkpass12 "$t/admin6.log" '{"cmd":"queue"}
{"cmd":"moderate","report":1,"action":"hide"}
{"cmd":"moderate","report":1,"action":"hide","statement":"Advertising"}
{"cmd":"moderate","report":2,"action":"dismiss"}
{"cmd":"queue"}'
answer "$t/admin6.log" 1001 | grep -q '"body":"Cheap lamps for everyone".*"reason":"rude"' ||
	fail "the queue: $(answer "$t/admin6.log" 1001)"
answer "$t/admin6.log" 1002 | grep -q "the statement" || fail "a hide without a statement"
answer "$t/admin6.log" 1003 | grep -q '"ok":true' || fail "the hide: $(answer "$t/admin6.log" 1003)"
answer "$t/admin6.log" 1004 | grep -q '"ok":true' || fail "the dismissal"
answer "$t/admin6.log" 1005 | grep -q '"result":\[\]' || fail "the queue after"
get / > /dev/null; grep -q 'href="/t/2"' "$t/page" && fail "a hidden thread on the portal"
[ "$(get /t/2)" = 200 ] && grep -q "Hidden by a moderator: Advertising" "$t/page" ||
	fail "the hidden thread's page"
grep -q "Cheap lamps" "$t/page" && fail "a hidden message's text on its page"
get "/search?q=cheap" > /dev/null; grep -q '/t/2#' "$t/page" && fail "search finds a hidden message"
[ "$(get /m/6)" = 200 ] && fail "a hidden thread's message has a page"
client carol carolpass1234 "$t/carol3.log" '{"cmd":"thread","thread":2}'
answer "$t/carol3.log" 1001 | grep -q '"title":"A hidden thread"' &&
	! answer "$t/carol3.log" 1001 | grep -q "Cheap lamps" ||
	fail "a hidden thread by packet: $(answer "$t/carol3.log" 1001)"
client bob bobpass1234 "$t/bob7.log" '{"cmd":"notifications"}
{"cmd":"thread","thread":2}
{"cmd":"appeal","message":6,"text":"It is a real offer"}
{"cmd":"appeal","message":6,"text":"really"}
{"cmd":"edit","message":6,"body":"An honest offer"}' BUILDAT_HEARTH_OPEN=2
grep -a "attempt to\|stack traceback" "$t/bob7.log" && fail "the hidden thread's page"
answer "$t/bob7.log" 1001 | grep -q '"kind":"hidden".*"note":"Advertising"' ||
	fail "bob's notification of the hide: $(answer "$t/bob7.log" 1001)"
answer "$t/bob7.log" 1002 | grep -q '"body":"Cheap lamps for everyone"' ||
	fail "the author does not see his hidden message"
answer "$t/bob7.log" 1003 | grep -q '"result":3' || fail "the appeal: $(answer "$t/bob7.log" 1003)"
answer "$t/bob7.log" 1004 | grep -q "waiting already" || fail "an appeal twice"
answer "$t/bob7.log" 1005 | grep -q "a hidden message is not edited" ||
	fail "a hidden message edited: $(answer "$t/bob7.log" 1005)"
client admin checkpass12 "$t/admin7.log" '{"cmd":"moderate","report":3,"action":"hide","statement":"x"}
{"cmd":"moderate","report":3,"action":"restore"}'
answer "$t/admin7.log" 1001 | grep -q "restored or dismissed" || fail "an appeal hidden"
answer "$t/admin7.log" 1002 | grep -q '"ok":true' || fail "the restore: $(answer "$t/admin7.log" 1002)"
get /t/2 > /dev/null; grep -q "Cheap lamps for everyone" "$t/page" &&
	! grep -q "Hidden by a moderator" "$t/page" || fail "the restored thread"
get "/search?q=cheap" > /dev/null; grep -q '/t/2#m6' "$t/page" || fail "search after the restore"
n429=0
for _ in $(seq 40); do
	[ "$(get "/search?q=x")" = 429 ] && n429=$((n429 + 1))
done
[ $n429 -gt 0 ] || fail "no search limit per address"
client carol carolpass1234 "$t/carol2.log" "$(
	for i in $(seq 31); do echo '{"cmd":"search","q":"lamps"}'; done)"
answer "$t/carol2.log" 1030 | grep -q '"ok":true' || fail "carol's search"
answer "$t/carol2.log" 1031 | grep -q "too many searches" ||
	fail "no search limit per account"

# 7. The markup: CommonMark with GitHub's additions, raw HTML as text, no
# link or image to anything but http, https, mailto or a relative path
client admin checkpass12 "$t/admin8.log" '{"cmd":"reply","thread":1,"body":"**bold** _em_ ~~del~~ `code`\n\n<script>x()</script> <img src=x onerror=y()>\n\n[js](javascript:alert(1)) [tab](<java\tscript:alert(2)>) [up](JAVASCRIPT:alert(4)) [ent](java&#115;cript:alert(3)) [ok](https://buildat.org/a?b=1&c=2) ![pic](https://img.example/p.png \"t\")\n\n| a | b |\n|---|--:|\n| 1 | 2 |\n\n- [x] done\n- [ ] not\n\n> quoted ||secret||\n\n```\n<b>raw</b>\n```\n\nsee www.lamps.example\n\n#1 and not a#2, #3x or `#4`"}'
answer "$t/admin8.log" 1001 | grep -q '"ok":true' || fail "the markup reply: $(answer "$t/admin8.log" 1001)"
get /t/1 > /dev/null
for want in "<strong>bold</strong> <em>em</em> <del>del</del> <code>code</code>" \
		"<p>&lt;script&gt;x()&lt;/script&gt; &lt;img src=x onerror=y()&gt;</p>" \
		'<a href="https://buildat.org/a?b=1&amp;c=2" rel="nofollow ugc">ok</a>' \
		'<a href="https://img.example/p.png" title="t" rel="nofollow ugc">[image: pic]</a>' \
		'<th>a</th><th style="text-align:right">b</th>' \
		'<li><input type="checkbox" disabled checked> done</li>' \
		'<span class="spoiler" tabindex="0">secret</span>' \
		'<pre><code>&lt;b&gt;raw&lt;/b&gt;' \
		'<a href="http://www.lamps.example" rel="nofollow ugc">www.lamps.example</a>' \
		'<p><a class="ref" href="/t/1">#1</a> and not a#2, #3x or <code>#4</code></p>'; do
	grep -qF "$want" "$t/page" || fail "the markup: no $want ($(grep -a -A3 'bold' "$t/page" | head -12))"
done
# (the header's logo is the page's own)
sed -i 's|<img src="/brand/logo.png" alt="">||' "$t/page"
grep -qi 'href="[^"]*script\|<script\|<img' "$t/page" &&
	fail "the markup let through: $(grep -aio 'href="[^"]*script[^"]*"\|<script\|<img' "$t/page")"

# 8. The reply field is multi-line: Enter breaks the line, Up moves a row
# (the field's, not the buttons' -- ui_utils' keyboard page), Ctrl+Enter
# sends
CMDS='delay 5000\ntext one two\ndelay 200\nkeypress Return\ndelay 200\ntext three\ndelay 200\nkeypress Return\ndelay 200\nkeypress Return\ndelay 200\ntext four\ndelay 200\nkeypress Up\ndelay 200\nkeypress Up\ndelay 200\ntext X\ndelay 200\nkeydown ctrl\ndelay 100\nkeypress Return\ndelay 100\nkeyup ctrl\ndelay 1500\nquit\n' \
	client admin checkpass12 "$t/admin9.log" '' BUILDAT_HEARTH_OPEN=1
get /t/1 > /dev/null
grep -qPz '<p>one two\nXthree</p>\n<p>four</p>' "$t/page" ||
	fail "the multi-line reply: $(grep -a -B1 -A2 'Xthree\|one two' "$t/page" | head -6)"

# 9. Files ([FORUM] step 5): a new account uploads none; the admin's JPEG
# comes back within 1080p without its EXIF, a PNG as a PNG, another file
# as it came, a fake PNG refused; robots.txt keeps crawlers off /f/; over
# the budget an unused image is crushed again and another file deleted,
# and past delete_after the rest go
python3 - "$t" <<'PY' || fail "the test files"
import io, sys
from PIL import Image
d = sys.argv[1]
exif = Image.Exif()
exif[0x010e] = "SECRETPLACE"
b = io.BytesIO()
Image.linear_gradient("L").resize((2400, 600)).convert("RGB").save(
        b, "JPEG", quality=30, exif=exif.tobytes())
assert b"SECRETPLACE" in b.getvalue()
open(d + "/up_jpg", "w").write(b.getvalue().hex())
b = io.BytesIO()
Image.new("RGBA", (3, 2), (10, 20, 30, 128)).save(b, "PNG")
open(d + "/up_png", "w").write(b.getvalue().hex())
PY
client bob bobpass1234 "$t/bob_files.log" '{"cmd":"upload","name":"a.txt","data":"68690a"}
{"cmd":"file_settings","budget":0}'
answer "$t/bob_files.log" 1001 | grep -q "no files yet" ||
	fail "a new account's upload: $(answer "$t/bob_files.log" 1001)"
answer "$t/bob_files.log" 1002 | grep -q "only the admin" ||
	fail "bob set the budget: $(answer "$t/bob_files.log" 1002)"
client admin checkpass12 "$t/admin_files.log" "{\"cmd\":\"upload\",\"name\":\"far.jpg\",\"data\":\"$(cat "$t/up_jpg")\"}
{\"cmd\":\"upload\",\"name\":\"dot.png\",\"data\":\"$(cat "$t/up_png")\"}
{\"cmd\":\"upload\",\"name\":\"notes.txt\",\"data\":\"68656c6c6f\"}
{\"cmd\":\"upload\",\"name\":\"fake.png\",\"data\":\"89504e470d0a1a0a6e6f\"}"
for i in 1001 1002 1003; do
	answer "$t/admin_files.log" $i | grep -q '"ok":true' ||
		fail "the admin's upload $i: $(answer "$t/admin_files.log" $i)"
done
answer "$t/admin_files.log" 1004 | grep -q "not an image Hearth can read" ||
	fail "a fake PNG: $(answer "$t/admin_files.log" 1004)"
image(){ # path -> "format WxH", or why not
	python3 -c 'import sys; from PIL import Image; d = open(sys.argv[1], "rb").read()
im = Image.open(sys.argv[1]); print(im.format, "%dx%d" % im.size, "EXIF" if b"SECRETPLACE" in d else "")' "$t/page" 2>&1
}
[ "$(get /f/1/far.jpg)" = 200 ] && [ "$(image)" = "JPEG 1920x480 " ] ||
	fail "the JPEG as served: $(image)"
[ "$(get /f/2)" = 200 ] && [ "$(image)" = "PNG 3x2 " ] || fail "the PNG: $(image)"
[ "$(get /f/3)" = 200 ] && [ "$(cat "$t/page")" = hello ] || fail "the other file"
[ "$(get /robots.txt)" = 200 ] && grep -q "Disallow: /f/" "$t/page" ||
	fail "robots.txt: $(cat "$t/page")"
MS=4000 client admin checkpass12 "$t/admin_files2.log" '{"cmd":"file_settings","budget":0,"lod2_after":0}'
answer "$t/admin_files2.log" 1001 | grep -q '"ok":true' ||
	fail "the budget: $(answer "$t/admin_files2.log" 1001)"
[ "$(get /f/1)" = 200 ] && [ "$(image)" = "JPEG 960x240 " ] ||
	fail "the JPEG over the budget: $(image)"
[ "$(get /f/3)" = 404 ] || fail "the other file over the budget was kept"
MS=4000 client admin checkpass12 "$t/admin_files3.log" '{"cmd":"file_settings","delete_after":0}'
[ "$(get /f/1)" = 404 ] && [ "$(get /f/2)" = 404 ] ||
	fail "past delete_after an image was kept"

# 10. A long thread is read a part at a time: the page links on to the
# rest, the client reads on by itself; and pages are limited per address.
# 20 messages of 20 kB, put in the file (the API's limits make them slow).
kill $pid; wait $pid 2>/dev/null
python3 - "$t/srv/apps/hearth/hearth.sqlite" <<'PY' || fail "the long thread"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executemany("INSERT INTO messages(thread, author, body, created) "
        "VALUES(1, 'admin', ?, 1)", [("x" * 19990 + " END%d" % i,) for i in range(1, 21)])
c.commit()
PY
bin/buildat_server -m ../apps/hearth -D "$t/srv" -P $P -l 3 > "$t/srv2.log" 2>&1 &
pid=$!
for _ in $(seq 120); do grep -q "Hearth: " "$t/srv2.log" && break; sleep 1; done
u=/t/1 pages=0
while [ "$(get "$u")" = 200 ] && pages=$((pages + 1)) &&
		u=$(grep -o '/t/1?after=[0-9]*' "$t/page"); do :; done
[ $pages -ge 2 ] && grep -q "END20" "$t/page" && ! grep -q "END1<" "$t/page" ||
	fail "the long thread's pages ($pages, the last: $(grep -o 'END[0-9]*' "$t/page" | tr '\n' ' '))"
client admin checkpass12 "$t/admin10.log" '' BUILDAT_HEARTH_OPEN=1
grep -a '^.*hr: ' "$t/admin10.log" | grep -q '"more":true' &&
	grep -a 'hr: ' "$t/admin10.log" | grep -q 'END20' ||
	fail "the client did not read the long thread on"
n429=0
for _ in $(seq 130); do [ "$(get /)" = 429 ] && n429=$((n429 + 1)); done
[ $n429 -gt 0 ] || fail "no page limit per address"
echo "PASS: posted, replied, edited, refused; answered, mentioned, notified; a chat line live; read as HTML with the markup escaped; CommonMark with no unsafe link; a multi-line reply; found by search; a new account limited; reported, hidden with a statement, appealed, restored; files crushed, served and swept; a long thread read in parts; pages limited"
