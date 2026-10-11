#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-10)
# covers: builtin/accounts/accounts.cpp builtin/voxelworld/voxelworld.cpp src/server/main.cpp
# [SERVER_CAPS]:
#   1. vanilla on the minimal game, a client: the save over 1 MB at
#      shutdown, the range asked for over 40.
#   2. Again with --max-view-range 40 --max-world-mb 1: the
#      client is sent 40 voxels; generation stops, said once.
#   3. An Aitta with --max-players 1: a second account is refused, the
#      server is full.
#
#   util/server_caps_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp server_caps; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
client(){ # <name> <ms> [env...]
	local n=$1 ms=$2; shift 2
	printf 'delay %s\nquit\n' "$ms" > "$t/$n.cmds"
	env "$@" timeout 120 bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$P -D "$t/$n" \
		-w 640x360 -l 3 -o sound_mute=1 -c @"$t/$n.cmds" > "$t/$n.log" 2>&1
}
stop(){ kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; }

# 1.
mkdir -p "$t/d/apps/vanilla/saves/w/luanti"
echo "enable_damage = false" > "$t/d/apps/vanilla/saves/w/luanti/world.mt"
start_server "$t/d1.log" "Listening at" 120 auto \
	env BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$t/d" -l 4 || fail "vanilla did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
client a 25000
stop
size=$(du -sb "$t/d/apps" | cut -f1)
[ "$size" -gt 1000000 ] || fail "the save is only $size bytes"
grep -a "wants [0-9]* voxels of world" "$t/d1.log" | grep -vq "wants \(0\|40\) voxels" ||
	fail "the client asked for no more than 40 ($t/d1.log)"

# 2.
start_server "$t/d2.log" "Listening at" 120 auto \
	env BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$t/d" -l 4 \
	--max-view-range 40 --max-world-mb 1 || fail "vanilla did not start again"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
client b 15000
stop
grep -aq "wants 40 voxels of world" "$t/d2.log" &&
	! grep -a "wants [0-9]* voxels of world" "$t/d2.log" | grep -vq "wants \(0\|40\) voxels" ||
	fail "the range ($(grep -a "voxels of world" "$t/d2.log" | head -3))"
echo "ok: the range capped at 40 voxels"
[ "$(grep -ac "is at max_disk_mb: nothing new is generated" "$t/d2.log")" = 1 ] ||
	fail "the world cap ($t/d2.log)"
echo "ok: generation stopped at 1 MB of save"

# 3. An admin, who adds the players
mkdir -p "$t/srv"
echo "name admin checkpass0" > "$t/srv/first_admin"
start_server "$t/a.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 --max-players 1 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
client adm 6000 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass0 \
	BUILDAT_AITTA_ADMIN="$(printf 'add player1 checkpass1\nadd player2 checkpass2')"
sleep 2
client p1 25000 BUILDAT_AITTA_NAME=player1 BUILDAT_AITTA_PASSWORD=checkpass1 &
p1=$!
sleep 12
client p2 8000 BUILDAT_AITTA_NAME=player2 BUILDAT_AITTA_PASSWORD=checkpass2
wait $p1
grep -aq "player1 joined" "$t/a.log" || fail "the first player did not join ($t/a.log)"
grep -aq "Login of player2 refused: the server is full" "$t/a.log" ||
	fail "the second player let in ($t/a.log)"
echo "ok: the second player refused"
echo "PASS"
