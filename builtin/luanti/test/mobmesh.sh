#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [OBJECT_MESH] step 0: mobmesh.lua's server beside a client that looks at
# the mobs and shoots them. Prints the mobs' properties from the
# server's log and the model lines from the client's; the shot is
# local/mobmesh/mobs.png.
#
#   builtin/luanti/test/mobmesh.sh
#   FIXTURE=connected builtin/luanti/test/mobmesh.sh   (another fixture with
#                                                       the same stage and shots)
set -u
FIXTURE="${FIXTURE:-mobmesh}"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/$FIXTURE"
mkdir -p "$out"
save="buildat_test_$FIXTURE"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/$FIXTURE.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29778 \
	-l "${LOG_LEVEL:-4}" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
delay 20000
look_dir 1 -0.15 0
delay 2000
screenshot $out/mobs.png
event scan
delay 12000
look_dir 2.5 0.2 1
delay 1500
screenshot $out/zombie_side.png
event scan
delay 1000
quit
CMDS
bin/buildat -s localhost:29778 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "$FIXTURE:" "$out/srv.log" | sed "s/.*$FIXTURE: //"
grep "model \"" "$out/srv.log" | sed 's/.*C1: //'
grep "luanti:model\|scan.*object\|scan.*obj " "$out/cli.log" | sed 's/.*luanti  : //'
