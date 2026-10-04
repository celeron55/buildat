#!/bin/bash
# tier: full
# cost: 40s (a first run compiles digger, 2026-10-03)
# covers: builtin/client_file/client_file.cpp src/client/app.cpp client/extensions/network/init.lua extensions/launch_world/world.lua
# [LAUNCH_WORLD] (4): **a native server's icon, kept from one connect**.
# A digger server with an admin's server_icon.png; a client connects once
# and quits; the client is started again into the room, connecting to
# nothing, and the server's sphere on the floor wears the stored icon.
#
#   extensions/launch_world/server_icon.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29881
mkdir -p "$t/srv/apps/digger" "$t/cl"
cp "$here/apps/vanilla/launcher/luanti.png" "$t/srv/apps/digger/server_icon.png"
sha=$(sha256sum "$t/srv/apps/digger/server_icon.png" | cut -d' ' -f1)
cd "$here/Build"
bin/buildat_server -m ../apps/digger -D "$t/srv" -P $P -l 3 > "$t/srv.log" 2>&1 &
srv=$!
for _ in $(seq 180); do
	grep -aq "Listening at" "$t/srv.log" && break
	sleep 1
done
grep -aq "The server's icon: .*server_icon.png" "$t/srv.log" ||
	fail "the server did not take its icon ($(tail -2 "$t/srv.log"))"
printf 'delay 8000\nquit\n' > "$t/cmds"
timeout 90 bin/buildat -D "$t/cl" -C "$t/cache" -s localhost:$P -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/cmds" > "$t/cl1.log" 2>&1
grep -aq "server icon from localhost:$P kept" "$t/cl1.log" ||
	fail "the client did not keep the icon"
[ -f "$t/cache/server_icons/$sha.png" ] || fail "no $sha.png in the cache"
grep -q "\"tcp://localhost:$P\".*\"$sha\"" "$t/cl/network_addresses.csv" ||
	fail "the address's row has no icon: $(cat "$t/cl/network_addresses.csv")"
kill $srv; srv=
# The room, connecting to nothing
timeout 90 bin/buildat -D "$t/cl" -C "$t/cache" -m launch_world -w 640x360 \
	-l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl2.log" 2>&1
grep -aq "marks: server tcp://localhost:$P wears its stored icon" "$t/cl2.log" ||
	fail "the room's sphere does not wear it"
echo "PASS: the server's icon came at one connect and the room wears it after a restart"
