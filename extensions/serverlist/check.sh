#!/bin/bash
# extensions/serverlist: the fetched serverlist, end to end without the
# network ([LAUNCH_WORLD] step 5, [SERVER_LIST]).
#
#   extensions/serverlist/check.sh
#
# tier: quick
# cost: 31s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
#
# A list of this check's own is served on a port of its own, so nothing
# here asks content or servers.luanti.org for anything. What is asserted
# is the whole path: the extension fetches and caches, the launcher file
# offers the cached rows as launch actions with the player count as
# their significance, and a launch UI draws them -- the room, which
# makes a server a mirror by category and stands its invented padding
# down when real ones are there.
#
# It keeps builtin/luanti/test/lib.sh's contract ([CI_RUNS] (1)): exit 0
# passed, 1 failed, 2 could not run, and a last line saying which.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/serverlist_check"; mkdir -p "$out"
rm -rf "$out/user" "$out/list" "$out/quietuser"
mkdir -p "$out/user" "$out/list" "$out/quietuser"
port=30778
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
cat > "$out/list/list" <<'JSON'
{"list": [
 {"address": "one.example.org", "port": 30000, "name": "the first server", "clients": 7},
 {"address": "two.example.net", "port": 30001, "name": "the second", "clients": 2}
]}
JSON
# **The host is accepted before the run, not during it**: the fetch goes
# through the same permission the sockets do and asks the user about a
# host it has not seen, which is the behaviour worth keeping -- a
# launcher that reached the network quietly would be the wrong kind of
# quiet. The store is the client's own file.
# Now, since an answer lasts a week
now=$(date +%s)
printf 'accepted,address,description,created,last_attempt,name\n"true","http://localhost","a check'"'"'s own server list","%s","%s",""\n' \
	"$now" "$now" \
	> "$out/user/network_addresses.csv"
# **And a client that has not said yes fetches nothing at boot**: a
# launcher that put a permission dialog in front of a first-time user
# before they asked for anything would be answering a question nobody
# posed. The list's own launch action is where the asking happens.
{ echo "delay 6000"; echo "quit"; } > "$out/cmds_quiet.txt"
BUILDAT_SERVERLIST_URL=http://localhost:$port \
	timeout 90 bin/buildat -m launch_world -D "$out/quietuser" -w 640x360 \
	-l 3 -L "$out/quiet.log" -c @"$out/cmds_quiet.txt" > /dev/null 2>&1
quiet=$(grep -ac "serverli.*not fetching .* until asked to" "$out/quiet.log")
asked=$(grep -ac "Asking the user about" "$out/quiet.log")
echo "a client with no answer on file: $quiet held off, $asked dialogs"
if [ "$quiet" -lt 1 ] || [ "$asked" -gt 0 ]; then
	echo "FAIL: the serverlist asks a first-time user about the network" \
			"before anyone asked it for a list"
	exit 1
fi
pkill -f "http.server $port" 2>/dev/null || true
(cd "$out/list" && exec python3 -m http.server $port > "$out/http.log" 2>&1) &
mirror=$!
sleep 1
{ echo "delay 8000"; echo "quit"; } > "$out/cmds.txt"
# The first run fetches and caches; the grid it drew had nothing in it,
# which is the design: a launcher file cannot wait for the network
BUILDAT_SERVERLIST_URL=http://localhost:$port \
	timeout 120 bin/buildat -m launch_world -D "$out/user" -w 640x360 -l 3 \
	-L "$out/first.log" -c @"$out/cmds.txt" > /dev/null 2>&1
# Rows, not newlines: the file's last row has none
cached=$(grep -ac "|" "$out/user/serverlist/serverlist.csv" 2>/dev/null || echo 0)
echo "the first run cached $cached servers"
if [ "${cached:-0}" -lt 1 ]; then
	kill "$mirror" 2>/dev/null
	echo "FAIL: the list was not fetched or not cached"
	grep -a "serverli" "$out/first.log" | tail -3
	echo "FAIL: the serverlist fetches nothing"
	exit 1
fi
# The second run draws them: one orb a row, a mirror because the action
# says it is a server, and the room's invented padding stood down
BUILDAT_SERVERLIST_URL=http://localhost:$port \
	timeout 120 bin/buildat -m launch_world -D "$out/user" -w 640x360 -l 3 \
	-L "$out/second.log" -c @"$out/cmds.txt" > /dev/null 2>&1
kill "$mirror" 2>/dev/null; wait "$mirror" 2>/dev/null
line=$(grep -a "launch_w.*: servers: .* off a fetched list" "$out/second.log" |
	head -1 | sed 's/.*servers: //')
echo "the room says: ${line:-(nothing)}"
fetched=$(echo "$line" | sed -n 's/.*, \([0-9]*\) off a fetched list.*/\1/p')
examples=$(echo "$line" | sed -n 's/.*floor, \([0-9]*\) of them .*/\1/p')
named=$(grep -ac "launch_w.*: mark: the first server" "$out/second.log")
ranked=$(grep -ac "launch_w.*: orb sizes: .*ranked within .*server" "$out/second.log")
if [ "${fetched:-0}" -lt 2 ] || [ "$named" -lt 1 ]; then
	echo "FAIL: the fetched servers do not reach the room"
	exit 1
fi
if [ "${ranked:-0}" -lt 1 ]; then
	echo "FAIL: a fetched server says nothing about how much it matters"
	exit 1
fi
# The padding is nine when the floor has none of its own; two real ones
# take two of those places
if [ "${examples:-99}" -ge 9 ]; then
	echo "FAIL: the room pads its floor with invented servers although" \
			"it has real ones"
	exit 1
fi
echo "PASS: a fetched serverlist reaches a launch UI as ranked actions"
exit 0
