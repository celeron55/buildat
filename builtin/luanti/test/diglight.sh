#!/bin/bash
# [DIG_LIGHT]: diglight.lua's server beside a client that reads its own
# light at t=15 (the pit), t=70 (the stair) and t=115 (its third step, the player put there) -- the scan's eye light
# line and a scan_volume with light rows. Prints the two readings side
# by side; the log is under local/diglight/.
#
#   SEED=5 builtin/luanti/test/diglight.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
SEED="${SEED:-5}"
GAME="${GAME:-mineclone2}"
# The client's render mode: pbr, shadows or unlit ([STAIR_DARK]'s
# discriminator is the same stair in shadows against pbr)
MODE="${MODE:-pbr}"
out="$here/local/diglight"
mkdir -p "$out"
save="buildat_test_diglight"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/luanti_launcher/saves/$save"
{ echo "rawset(_G, \"FUZZ_SEED\", $SEED)"; cat "$me/diglight.lua"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -m ../games/luanti_launcher -D ../user -P 29777 \
	-l "${LOG_LEVEL:-4}" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
delay 23000
event scan
event scan_volume 4 t15 light
delay 55000
event scan
event scan_volume 4 t70 light
look_dir 1 -0.5 0
delay 1500
screenshot $out/stair_${MODE}_t70.png
delay 43000
event scan
event scan_volume 4 t115 light
delay 20000
event scan
event scan_volume 4 t135 light
look_dir -1 0.3 0
delay 1500
screenshot $out/stair_${MODE}_step3_up.png
look_dir 1 -0.3 0
delay 1500
screenshot $out/stair_${MODE}_step3_down.png
delay 20000
event scan
event scan_volume 4 t155 light
look_dir 1 -0.5 0
delay 1500
screenshot $out/stair_${MODE}_t155.png
look_dir 1 -1.5 0
delay 1500
screenshot $out/stair_${MODE}_t155_pit.png
delay 2000
quit
CMDS
BUILDAT_LUANTI_PBR="$MODE" bin/buildat -s localhost:29777 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "diglight:" "$out/srv.log" | sed 's/.*diglight: //' | grep -v "t=[0-9]*[1-46-9] " 
grep "light sky\|voxel names\|light y=" "$out/cli.log" | sed 's/.*scan /scan /'
