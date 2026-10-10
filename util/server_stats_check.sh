#!/bin/bash
# tier: full
# cost: ~70 s (2026-10-10)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua
# [SERVER_STATS]: an Aitta (its admin by first_admin) with a moderator and
# a helper.
#   1. The admin's stats: the hour in progress has max 1, the admin's
#      seen has made and last joined; the Statistics page drawn
#      (stats.png).
#   2. The moderator's stats answered, the helper's not.
#
#   util/server_stats_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp server_stats; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
mkdir -p "$t/srv"
echo "name admin checkpass0" > "$t/srv/first_admin"
start_server "$t/srv.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 || fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
client(){ # <name> <password> <admin lines> <cmds...>
	local n=$1 pw=$2 adm=$3; shift 3
	printf '%s\n' "$@" quit > "$t/$n.cmds"
	BUILDAT_AITTA_NAME=$n BUILDAT_AITTA_PASSWORD=$pw BUILDAT_AITTA_ADMIN="$adm" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" -w 1000x700 -l 3 \
		-o sound_mute=1 -s 127.0.0.1:$P -c @"$t/$n.cmds" > "$t/$n.log" 2>&1
}

# 1.
client admin checkpass0 "$(printf 'add mod modpass1234\nadd helper helppass12\nlevel mod 30\nlevel helper 20\nstats')" \
	"wait_log 20000 stats: " "delay 4000" "click Button \"Statistics\"" "delay 2000" \
	"mouse_pos 650 210" "delay 500" "mouse_pos 745 210" "delay 1000" "screenshot $t/stats.png"
line=$(grep -a "stats: " "$t/admin.log" | tail -1)
echo "$line" | grep -q "the hour in progress max 1; top admin made [1-9][0-9]* last [1-9]" ||
	fail "the admin's stats: ${line:-none} ($t/admin.log)"
[ -s "$t/stats.png" ] || fail "no screenshot"
echo "ok: the hour has its player, the admin's seen is set ($t/stats.png)"

# 2.
client mod modpass1234 stats "wait_log 20000 stats: "
grep -aq "stats: " "$t/mod.log" || fail "the moderator's stats ($t/mod.log)"
client helper helppass12 stats "wait_log 20000 admin request: stats" "delay 4000"
grep -aq "admin request: stats" "$t/helper.log" && ! grep -aq "stats: " "$t/helper.log" ||
	fail "the helper's stats ($t/helper.log)"
echo "ok: a moderator's answered, a helper's refused"
echo "PASS"
