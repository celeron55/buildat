#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4, the client's side: client_fuzz.py as a hostile
# server and the client (Build/asan's, BUILD= for another) connecting to it
# again and again, each run watched for a crash in its log. The logs and
# the seed go to local/security/fuzz/client/.
#
#   util/fuzz/client_fuzz.sh [seconds] [seed]
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/security/fuzz/client"
secs=${1:-120}
seed=${2:-$RANDOM}
mkdir -p "$out"
rm -rf "$out/user"; mkdir -p "$out/user"
port=$(( 29800 + (RANDOM % 90) ))
cd "$here/Build/${BUILD-asan}"
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}
make -s -j8 > "$out/make.log" 2>&1 ||
	{ echo "the build failed: $out/make.log"; exit 2; }
python3 "$here/util/fuzz/client_fuzz.py" "$port" 8 "$seed" > "$out/server.log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
sleep 1
# A scripted client: the window manager puts it out of the user's way,
# and it leaves on its own after the server has closed on it
{ echo "delay 12000"; echo "quit"; } > "$out/cmds.txt"
echo "seed $seed, port $port"
end=$(( $(date +%s) + secs )); runs=0; bad=""
while [ "$(date +%s)" -lt "$end" ]; do
	runs=$((runs + 1))
	timeout -s KILL 30 bin/buildat -s "127.0.0.1:$port" -D "$out/user" \
		-w 640x360 -l 3 -o sound_mute=1 -U "$here/3rdparty/Urho3D" -P "$here" \
		-C "$out/cache" -c @"$out/cmds.txt" \
		> "$out/cli.log" 2>&1
	st=$?
	if grep -aq "Crash: SIG\|AddressSanitizer\|runtime error" "$out/cli.log"; then
		bad="a crash in the client's log"; break
	fi
	# A client that the server's garbage keeps from ever leaving
	[ $st = 137 ] && { bad="the client hung (30 s)"; break; }
done
kill $srv 2>/dev/null
tail -1 "$out/server.log"
if [ -n "$bad" ]; then
	cp "$out/cli.log" "$out/fail_$seed.log"
	echo "FAIL: $bad (seed $seed, run $runs); $out/fail_$seed.log"
	grep -a -A12 "Crash: SIG\|AddressSanitizer\|runtime error" "$out/cli.log" | head -30
	exit 1
fi
echo "PASS: $runs client runs against a hostile server"
