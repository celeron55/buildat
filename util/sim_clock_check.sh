#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-07)
# covers: src/server/main.cpp src/impl/linux/os.cpp builtin/starport_announce/** builtin/accounts/accounts.cpp apps/starport/main/main.cpp apps/hearth/main/main.cpp apps/aitta/main/main.cpp
# [SIM_CLOCK]: a Starport, a Hearth listed on it and an Aitta, run with
# --sim-clock and moved together through 183 days and then 5 years. What
# runs on the calendar, and a few scripted attacks:
#   0. day 0: Starport IDs (an adult, a teen of 14) and five new listings
#      from one address, the sixth refused; ten wrong logins of alice from
#      elsewhere, and alice's own refused; Hearth's patient spammer, sam,
#      a new account: no links, two threads a day; he reads five threads
#      and posts three replies; the admin's file under a budget of 0;
#      Aitta: a release, not yet on the public page;
#   1. +1 hour: alice logs in again; the release is on the page;
#   2. +1 day: the sixth listing; sam stands, and his link spam goes in;
#      carol reports it, the admin hides it, and sam is a new account again;
#   3. +8 days: alice's login addresses are gone (retention_days 7);
#   4. +31 days: alice's first session ended; the five listings, never
#      announced again, are gone; Hearth's, announced after each jump, is
#      not; sam's hidden message no longer counts against him;
#   5. +183 days: the file, unused, deleted;
#   6. +5 years, the Starport first: the teen is an adult; Hearth's listing
#      gone and Hearth listed again under a new id.
#   util/sim_clock_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d "/tmp/buildat_sim_clock.XXXXXX")
pids=()
cleanup(){
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"
}
trap cleanup EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here/Build"

start_server "$t/sp.log" "setup code" 120 auto \
	bin/buildat_server --sim-clock -m ../apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start"
pids+=($SERVER_PID)
SP=$SERVER_PORT
export BUILDAT_CONNECT_PORTS=$SP
mkdir -p "$t/hearth/apps/hearth"
cat > "$t/hearth/apps/hearth/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], "name": "Sim hearth",
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
EOF
start_server "$t/hearth.log" "setup code" 120 auto \
	bin/buildat_server --sim-clock -m ../apps/hearth -D "$t/hearth" -l 3 ||
	fail "Hearth did not start"
pids+=($SERVER_PID)
HP=$SERVER_PORT
hcode=$(grep -ao "setup code [A-Z0-9]*" "$t/hearth.log" | cut -d' ' -f3)
start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server --sim-clock -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start"
pids+=($SERVER_PID)
AP=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)

# advance <seconds> [servers]: the calendar T seconds further, on each
# server named (all by default), each seen to take it
T=0
advance(){
	T=$((T + $1))
	local s _i
	for s in ${2:-sp hearth aitta}; do
		echo $T > "$t/$s/sim_clock"
		for _i in $(seq 100); do
			grep -aq "sim clock: ${T}s ahead" "$t/$s.log" && break
			sleep 0.1
		done
		grep -aq "sim clock: ${T}s ahead" "$t/$s.log" || fail "$s did not take the clock to $T"
	done
	# The modules' ticks after it
	sleep 1
}
H=3600 D=86400

# Starport: sp <address> <call> <json>
sp(){ curl -s -m 10 -H "X-Forwarded-For: $1" -d "$3" "http://127.0.0.1:$SP/api/$2"; }
# listed <id>: whether the Starport has it (a report without a reason is
# refused, and first for a listing it does not have)
probe=0
listed(){
	probe=$((probe + 1))
	! sp 10.7.$((probe / 250)).$((probe % 250)) report "{\"listing\":\"$1\"}" | grep -q "no such listing"
}
field(){ grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
# Hearth: hc <name> <password> <log> <requests> [env...]
hc(){
	local n=$1 pw=$2 log=$3 reqs=$4
	shift 4
	printf 'delay %s\nquit\n' "${MS:-6000}" > "$t/cmds_$n"
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw BUILDAT_HEARTH_CREATE=1 \
		BUILDAT_HEARTH_CODE=$hcode BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" -w 800x600 -l 3 \
		-o sound_mute=1 -s 127.0.0.1:$HP -c @"$t/cmds_$n" > "$t/$log" 2>&1
}
ans(){ grep -ao "hr: {.*\"id\":$2,.*" "$t/$1" | head -1; }
level(){ ans "$1" "$2" | grep -o '"level":[0-9]' | cut -d: -f2; }

# 0. Day 0
grep -aq "Listed on http://127.0.0.1:$SP as" "$t/hearth.log" || sleep 5
hid=$(grep -ao "Listed on http://127.0.0.1:$SP as [0-9a-f]*" "$t/hearth.log" | tail -1 | cut -d' ' -f5)
[ -n "$hid" ] || fail "Hearth was not listed (hearth.log)"
r=$(sp 10.0.0.1 id/register '{"name":"alice","password":"alicepass1","adult":true}')
sa1=$(echo "$r" | field session)
[ -n "$sa1" ] || fail "alice's ID: $r"
y=$(date -u +%Y)
r=$(sp 10.0.0.2 id/register "{\"name\":\"teen\",\"password\":\"teenpass1\",\"birth_year\":$((y - 15))}")
st=$(echo "$r" | field session)
echo "$r" | grep -q '"band":"13-17"' || fail "the teen's ID: $r"
desc='"descriptors": {"violence": "none", "chat": "moderated", "ugc": "none", "language": "no", "sexual": "no", "drugs": "no", "purchases": "no", "gambling": "no", "personal_data": "no"}'
listing(){ echo "{\"name\":\"Spam $1\",\"kind\":\"app\",\"audience\":\"everyone\",\"access\":\"open\",$desc,\"port\":9,\"address\":\"127.0.0.1\"${2:+,$2}}"; }
lids=() lsecrets=()
for i in 1 2 3 4 5; do
	r=$(sp 10.9.0.1 announce "$(listing $i)")
	lids+=("$(echo "$r" | field id)") lsecrets+=("$(echo "$r" | field secret)")
	[ -n "${lids[-1]}" ] || fail "new listing $i: $r"
done
sp 10.9.0.1 announce "$(listing 6)" | grep -q "too many new listings" ||
	fail "a sixth new listing from one address in a day"
for i in $(seq 10); do
	sp 10.6.0.$i id/login '{"name":"alice","password":"guess'$i'"}' > /dev/null
done
r=$(sp 10.0.0.1 id/login '{"name":"alice","password":"alicepass1"}')
echo "$r" | grep -q "too many logins" && alice_locked=1 || alice_locked=
echo "ok: day 0 on the Starport${alice_locked:+ (alice locked out by ten guesses from elsewhere)}"

hc admin adminpass12 h_admin0.log '{"cmd":"new_topic","name":"Lounge","about":"Talk"}
{"cmd":"new_thread","topic":1,"title":"One","body":"first"}
{"cmd":"new_thread","topic":1,"title":"Two","body":"second"}
{"cmd":"new_thread","topic":1,"title":"Three","body":"third"}
{"cmd":"new_thread","topic":1,"title":"Four","body":"fourth"}
{"cmd":"new_thread","topic":1,"title":"Five","body":"fifth"}
{"cmd":"upload","name":"notes.txt","data":"68656c6c6f"}
{"cmd":"file_settings","budget":0}' "BUILDAT_HEARTH_ADMIN=add sam sampass1234"
for i in 1001 1002 1003 1004 1005 1006 1007 1008; do
	ans h_admin0.log $i | grep -q '"ok":true' || fail "the admin's request $i: $(ans h_admin0.log $i)"
done
hc admin adminpass12 h_admin0b.log '' "BUILDAT_HEARTH_ADMIN=add carol carolpass1234"
hc sam sampass1234 h_sam0.log '{"cmd":"me"}
{"cmd":"new_thread","topic":1,"title":"Deals","body":"see https://spam.example"}
{"cmd":"thread","thread":1}
{"cmd":"thread","thread":2}
{"cmd":"thread","thread":3}
{"cmd":"thread","thread":4}
{"cmd":"thread","thread":5}
{"cmd":"reply","thread":1,"body":"nice"}
{"cmd":"reply","thread":2,"body":"agreed"}
{"cmd":"reply","thread":3,"body":"thanks"}
{"cmd":"new_thread","topic":1,"title":"Hi","body":"hello all"}
{"cmd":"new_thread","topic":1,"title":"Again","body":"hello again"}
{"cmd":"new_thread","topic":1,"title":"Third","body":"and again"}
{"cmd":"me"}'
[ "$(level h_sam0.log 1001)" = 0 ] || fail "sam is not a new account: $(ans h_sam0.log 1001)"
ans h_sam0.log 1002 | grep -q "no links yet" || fail "sam's link on day 0: $(ans h_sam0.log 1002)"
ans h_sam0.log 1012 | grep -q '"ok":true' || fail "sam's second thread: $(ans h_sam0.log 1012)"
ans h_sam0.log 1013 | grep -q "2 new threads a day" || fail "sam's third thread: $(ans h_sam0.log 1013)"
[ "$(level h_sam0.log 1014)" = 0 ] || fail "sam stood on day 0: $(ans h_sam0.log 1014)"
echo "ok: day 0 on Hearth"

b="$here/Build/bin/buildat"
mkdir -p "$t/app/main"
echo 'int x;' > "$t/app/main/main.cpp"
printf '{"author": "tester", "name": "demo", "version": "1.0", "engine_api": 1,
	"license_code": "MIT", "license_media": "CC0-1.0", "description": "sim",
	"audience": "everyone"}\n' > "$t/app/meta.json"
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'delay 6000\nquit\n' > "$t/cmds_ai"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$acode \
BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_ai" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$AP -c @"$t/cmds_ai" > "$t/ai.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/ai.log" || fail "the Aitta bind (ai.log)"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/rel" 2>/dev/null) || fail "pack"
"$b" aitta publish "$zip" 127.0.0.1:$AP 2>&1 | grep -q "listed: tester/demo/1.0" || fail "publish"
curl -s "http://127.0.0.1:$AP/" | grep -q "demo" && fail "the release on the public page at once"
echo "ok: day 0 on Aitta"

# 1. +1 hour
advance $((H + 60))
r=$(sp 10.0.0.1 id/login '{"name":"alice","password":"alicepass1"}')
sa2=$(echo "$r" | field session)
[ -n "$sa2" ] || fail "alice's login an hour later: $r"
curl -s "http://127.0.0.1:$AP/" | grep -q "demo" || fail "the release not on the public page after page_delay"
echo "ok: +1 hour"

# 2. +1 day
advance $D
sp 10.9.0.1 announce "$(listing 6)" | grep -q '"ok":true' || fail "a new listing the next day"
hc sam sampass1234 h_sam1.log '{"cmd":"me"}
{"cmd":"reply","thread":1,"body":"cheap deals at https://spam.example"}'
[ "$(level h_sam1.log 1001)" = 1 ] || fail "sam did not stand after a day: $(ans h_sam1.log 1001)"
spam=$(ans h_sam1.log 1002 | grep -o '"result":[0-9]*' | cut -d: -f2)
[ -n "$spam" ] || fail "sam's link after a day: $(ans h_sam1.log 1002)"
echo "found: a new account stands after a day, five threads read and three replies, and links freely"
hc carol carolpass1234 h_carol1.log "{\"cmd\":\"report\",\"message\":$spam,\"reason\":\"spam\"}"
rep=$(ans h_carol1.log 1001 | grep -o '"result":[0-9]*' | cut -d: -f2)
[ -n "$rep" ] || fail "carol's report: $(ans h_carol1.log 1001)"
hc admin adminpass12 h_admin1.log "{\"cmd\":\"moderate\",\"report\":$rep,\"action\":\"hide\",\"statement\":\"Spam\"}"
ans h_admin1.log 1001 | grep -q '"ok":true' || fail "the hide: $(ans h_admin1.log 1001)"
hc sam sampass1234 h_sam1b.log '{"cmd":"me"}
{"cmd":"reply","thread":2,"body":"more at https://spam.example"}'
[ "$(level h_sam1b.log 1001)" = 0 ] || fail "sam still stands with a message hidden: $(ans h_sam1b.log 1001)"
ans h_sam1b.log 1002 | grep -q "no links yet" || fail "sam's link after the hide: $(ans h_sam1b.log 1002)"
echo "ok: +1 day"

# 3. +8 days: the daily pass after the retention
advance $((7 * D))
r=$(sp 10.0.0.1 id/sessions "{\"session\":\"$sa2\"}")
echo "$r" | grep -q '"ok":true' || fail "alice's sessions: $r"
echo "$r" | grep -q "10.0.0.1" && fail "alice's addresses kept past retention_days: $r"
echo "ok: +8 days"

# 4. +31 days, in jumps the announcer keeps up with
advance $((23 * D))
r=$(sp 10.0.0.1 id/me "{\"session\":\"$sa1\"}")
echo "$r" | grep -q '"ok":true' && fail "alice's first session after 31 days: $r"
r=$(sp 10.9.0.1 announce "$(listing 1 "\"id\":\"${lids[0]}\",\"secret\":\"${lsecrets[0]}\"")")
echo "$r" | grep -q "no such listing" || fail "a listing unannounced for 31 days: $r"
listed "$hid" || fail "Hearth's listing gone at 31 days, though announced after each jump"
hc sam sampass1234 h_sam31.log '{"cmd":"me"}'
[ "$(level h_sam31.log 1001)" = 1 ] || fail "sam after his hidden message's 30 days: $(ans h_sam31.log 1001)"
grep -aq "file [0-9]* deleted" "$t/hearth.log" && fail "the file deleted before lod2_after"
echo "ok: +31 days"

# 5. To +183 days
for _ in 1 2 3 4 5; do advance $((29 * D)); done
advance $((7 * D))
sleep 2
grep -aq "file [0-9]* deleted, unused" "$t/hearth.log" || fail "the unused file not deleted after 183 days (hearth.log)"
listed "$hid" || fail "Hearth's listing gone by 183 days"
echo "ok: +183 days, Hearth listed all along as $hid"

# 6. +5 years, the Starport first: its daily pass drops Hearth's listing
advance $((5 * 365 * D)) sp
T=$((T - 5 * 365 * D))
advance $((5 * 365 * D)) "hearth aitta"
listed "$hid" && fail "Hearth's listing kept 5 years unheard"
r=$(sp 10.0.0.2 id/login '{"name":"teen","password":"teenpass1"}')
echo "$r" | grep -q '"adult":true' || fail "the teen not an adult after 5 years: $r"
for _ in $(seq 60); do
	[ "$(grep -ac "Listed on http://127.0.0.1:$SP as" "$t/hearth.log")" -ge 2 ] && break
	sleep 1
done
[ "$(grep -ac "Listed on http://127.0.0.1:$SP as" "$t/hearth.log")" -ge 2 ] ||
	fail "Hearth not listed again after its listing went: $(grep -a 'Announce to' "$t/hearth.log" | tail -1)"
echo "ok: +5 years"
echo "PASS: a calendar moved by --sim-clock: limits per hour and day, retention, sessions, listings, a release's page delay, a new account's trust, a file's sweep, an age; Hearth listed through it and again after its listing went"
