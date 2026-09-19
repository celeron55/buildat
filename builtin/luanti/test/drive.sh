#!/bin/bash
# [SCAN_DRIVE]: a driven run. The same server and fixture as fuzz.sh, the
# client on its stdin (a fifo), and drive.py choosing every act from what
# `event scan` shows. The verdict is the fuzz run's, verbatim (verdict.sh),
# plus drive.py's own FAILED lines (a rule's expectation failed twice, a
# form that would not close, three unstickings in a row).
#
#   SEED=3 MINUTES=5 GAME=mineclone2 builtin/luanti/test/drive.sh
#
# Lands under local/drive/<seed>/: both logs, drive.log (a line per turn
# naming the rule that fired), a screenshot every tenth turn beside the
# scan block of the same stem in cli.log. Never beside another
# buildat_server. LOG_LEVEL and CLIENT_LOG_LEVEL as in fuzz.sh.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
SEED="${SEED:-1}"
MINUTES="${MINUTES:-3}"
GAME="${GAME:-mineclone2}"
out="$here/local/drive/$SEED"
mkdir -p "$out"
save="buildat_test_drive_$SEED"

cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/luanti_launcher/saves/$save"
port=$(( 29800 + (SEED % 90) ))
srv=""; cli=""; drv=""
trap 'kill "$drv" 2>/dev/null; kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
{ echo "rawset(_G, \"FUZZ_SEED\", $SEED)"; cat "${FUZZ_LUA:-$me/fuzz.lua}"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -m ../games/luanti_launcher -D ../user -P "$port" \
	-l "${LOG_LEVEL:-4}" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	grep -q "Shutdown:" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; tail -3 "$out/srv.log" >&2; exit 1; }

# The client reads the fifo, and its run ends at the fifo's end: this
# shell holds a writing end open for the whole run, drive.py opens its
# own and writes quit last
fifo="$out/cmds.fifo"
rm -f "$fifo"; mkfifo "$fifo"
: > "$out/cli.log"
bin/buildat -s "localhost:$port" -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c - < "$fifo" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log" &
cli=$!
exec 3> "$fifo"
# The first forty seconds are the world loading around the player, as in
# the fuzz walk
echo "delay 40000" >&3
sleep 40
python3 "$me/drive.py" "$out/cli.log" "$fifo" "$MINUTES" "$out" "$SEED" \
	> "$out/drive.log" 2>&1 &
drv=$!

limit=$((MINUTES * 60 + 300))
for i in $(seq 1 "$limit"); do
	kill -0 "$cli" 2>/dev/null || break
	sleep 1
done
hung=0
if kill -0 "$cli" 2>/dev/null; then
	hung=1
	kill -KILL "$cli" 2>/dev/null
fi
wait "$cli"
cli_status=$?
wait "$drv" 2>/dev/null
exec 3>&-
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done

. "$me/verdict.sh"
grep "^drive: FAILED" "$out/drive.log" | sed 's/^drive: /FAIL: drive: /' >&2
grep -q "^drive: FAILED" "$out/drive.log" && status=1
echo "turns: $(grep -c "^drive: turn .* rule" "$out/drive.log"), rules: $(
	grep -o "rule [a-z_]*" "$out/drive.log" | sort | uniq -c | sort -rn |
	awk '{printf "%s %s, ", $3, $1}' | sed 's/, $//')"
exit $status
