#!/bin/bash
# tier: full
# cost: ~70s (2026-10-04)
# covers: builtin/accounts/accounts.cpp on_login's non-local wiring
# [SECURITY_RUN_2]: the login rate limit end-to-end over a real network, the
# residual that accounts.cpp's rate_limit_self_check() leaves (the self-check
# drives note_failure/failure_wait with its own clock; this drives on_login
# itself through a client). A server the launcher did not start is public
# ([VANILLA_PUBLIC]) and loopback is non-local on it, so is_local is false and
# the password is checked.
#   1. a wrong password is refused as "Wrong password" (the fail() path) and
#      the server counts it (note_failure);
#   2. the accumulated failures lock the name/address ("Too many failed
#      logins"), the login rate limit working end-to-end.
# That a correct password is refused while the wait is non-zero (on_login
# checks the wait before the password) is covered by accounts.cpp's
# rate_limit_self_check(); it is not driven here because catching a client
# inside a short wait window across process starts is not deterministic.
#
#   util/login_gating_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/Build"
[ -x bin/buildat_server ] || { echo "FAIL: no bin/buildat_server"; exit 1; }
[ -x bin/buildat ] || { echo "FAIL: no bin/buildat"; exit 1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }

t=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; rm -rf "$t"' EXIT
nolog(){ sed 's/\x1b\[[0-9;]*m//g' "$1"; }
fail(){ echo "FAIL: $*"; exit 1; }

port=29591
# No launcher param: a public server where loopback is non-local.
bin/buildat_server -m ../apps/vanilla -D "$t/srv" -P "$port" -l 3 \
	> "$t/srv.log" 2>&1 &
srv=$!
for _ in $(seq 180); do
	grep -q "STATUS Listening" "$t/srv.log" && break
	kill -0 $srv 2>/dev/null || fail "server died ($(tail -5 "$t/srv.log"))"
	sleep 0.5
done
grep -q "STATUS Listening" "$t/srv.log" || fail "server did not listen"
code=$(nolog "$t/srv.log" | grep -oP 'setup code \K[A-Z0-9]+' | head -1)
[ -n "$code" ] || fail "no setup code in the server log"

# join <userdir> <NAME> <PASSWORD> <CREATE> <CODE>: one scripted client.
join(){
	printf 'delay 1500\nquit\n' > "$t/seq"
	BUILDAT_JOIN_NAME="$2" BUILDAT_JOIN_PASSWORD="$3" \
		BUILDAT_JOIN_CREATE="$4" BUILDAT_JOIN_CODE="$5" \
		timeout 40 bin/buildat -s "127.0.0.1:$port" -D "$t/$1" \
		-w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" \
		> "$t/$1.log" 2>&1
	nolog "$t/$1.log"
}

# The account to attack
c=$(join mk alice rightpass123 1 "$code")
echo "$c" | grep -qF "Joined as alice" ||
	fail "could not create the account to drive
$(echo "$c" | grep -iE 'login|join|refused' | tail -5)"

# 1. a wrong password is refused as such, and the server counts it
c1=$(join w1 alice wrongpass000 0 "")
echo "$c1" | grep -qF 'Login refused: Wrong password' ||
	fail "a wrong password was not refused as Wrong password
$(echo "$c1" | grep -iE 'login|refused' | tail -5)"
nolog "$t/srv.log" | grep -q "failed: Wrong password" ||
	fail "the server did not log the wrong password as a counted failure"

# 2. the accumulated failures lock the name/address
locked=0
for i in $(seq 2 11); do
	ci=$(join "w$i" alice wrongpass000 0 "")
	if echo "$ci" | grep -qF 'Login refused: Too many failed logins'; then
		locked=1
		break
	fi
done
[ "$locked" = 1 ] ||
	fail "repeated wrong logins did not lock the name/address (no 'Too many failed logins')
$(nolog "$t/srv.log" | grep -iE 'failed|refused' | tail -8)"

echo "PASS: a wrong password is refused and counted; accumulated failures lock the login"
