#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4, protocol fuzzing: a vanilla server on a scratch
# user directory with a devtest world running (as the tests start one,
# launcher=1, so the fuzzer is the local peer and every launcher-only door
# is open to it), proto_fuzz.py at it, and the server watched: still
# running, still answering a connect, and its log free of a crash. The
# log and the seed go to local/security/fuzz/proto/.
#
# PUBLIC=1 starts it as a public server (no -u): the fuzzer is then any
# peer on the internet, with no door of the launcher's open. BUILD=asan
# runs Build/asan's server (cmake -DSANITIZE=address there), whose
# runtime-compiled modules are instrumented too.
#
#   util/fuzz/proto_fuzz.sh [seconds] [seed]
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/security/fuzz/proto"
secs=${1:-120}
seed=${2:-$RANDOM}
mkdir -p "$out"
user="$out/user"
rm -rf "$user/apps"
mkdir -p "$user/shared/vanilla/games"
[ -d "$user/shared/vanilla/games/devtest" ] ||
	cp -r "$here/user/shared/vanilla/games/devtest" "$user/shared/vanilla/games/"
grep -rhoE '"network:packet_received/[a-z_]+:[a-z_0-9]+"' \
	"$here/builtin" "$here/apps" --include=*.cpp |
	sed 's/"network:packet_received\///; s/"//' | sort -u > "$out/names.txt"
port=$(( 29700 + (RANDOM % 90) ))
cd "$here/Build${BUILD:+/$BUILD}"
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}
launch=(-u launcher=1)
[ "${PUBLIC:-}" = 1 ] && launch=()
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=proto \
	bin/buildat_server "${launch[@]}" -m "$here/apps/vanilla" -D "$user" \
	-P "$port" > "$out/srv.log" 2>&1 &
srv=$!
trap 'kill -9 $srv 2>/dev/null' EXIT
for i in $(seq 1 180); do
	grep -aq "Mods loaded\|world is running\|STATUS Listening" "$out/srv.log" && break
	sleep 1
done
sleep 5
echo "seed $seed, port $port, $(wc -l < "$out/names.txt") packet names"
python3 "$here/util/fuzz/proto_fuzz.py" "$port" "$secs" "$out/names.txt" \
	"$seed" > "$out/client.log" 2>&1 &
cli=$!
bad=""
while kill -0 $cli 2>/dev/null; do
	sleep 5
	if ! kill -0 $srv 2>/dev/null; then bad="the server exited"; break; fi
	grep -aq "Crash: SIG\|AddressSanitizer\|runtime error" "$out/srv.log" &&
		{ bad="a crash in the log"; break; }
	# Two modules waiting for each other: the server answers a connect
	# and nothing else (accounts and starport_announce, 2026-10-03)
	grep -aq "has been waiting [0-9]* s" "$out/srv.log" &&
		{ bad="modules waiting for each other"; break; }
done
wait $cli 2>/dev/null
cat "$out/client.log"
# Still answering after it
if [ -z "$bad" ] && ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
	bad="the server stopped answering"
fi
# And it stops when asked: a deadlock shows here if nowhere else
if [ -z "$bad" ]; then
	kill $srv 2>/dev/null
	for i in $(seq 1 30); do kill -0 $srv 2>/dev/null || break; sleep 1; done
	if kill -0 $srv 2>/dev/null; then
		bad="the server did not stop on SIGTERM"
		kill -9 $srv 2>/dev/null
	fi
fi
if [ -n "$bad" ]; then
	echo "FAIL: $bad (seed $seed); $out/srv.log"
	grep -a "Crash: SIG\|AddressSanitizer\|runtime error\|shutdown requested" "$out/srv.log" | head -5
	exit 1
fi
echo "PASS: the server ran through it and answers"
