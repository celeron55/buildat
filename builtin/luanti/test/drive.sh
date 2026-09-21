#!/bin/bash
# [SCAN_DRIVE]: a driven run. The same server and fixture as fuzz.sh, the
# client on its stdin (a fifo), and drive.py choosing every act from what
# `event scan` shows. The verdict is the fuzz run's, verbatim (verdict.sh),
# plus drive.py's own FAILED lines (a rule's expectation failed twice, a
# form that would not close, three unstickings in a row).
#
#   SEED=3 MINUTES=10 GOAL=3 GAME=mineclone2 builtin/luanti/test/drive.sh
#
# GOAL=<rung> is what the run is for and ends it ([DRIVE_GOAL]); MINUTES
# is the ceiling. The goal line is the pass; the minutes running out
# first is the stop to sort.
#
# Lands under local/drive/<seed>/ (the run before's pictures moved to
# previous/): both logs, drive.log (a line per turn
# naming the rule that fired), a screenshot every tenth turn beside the
# scan block of the same stem in cli.log. Never beside another
# buildat_server. LOG_LEVEL and CLIENT_LOG_LEVEL as in fuzz.sh.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
SEED="${SEED:-1}"
MINUTES="${MINUTES:-10}"
GAME="${GAME:-mineclone2}"
GOAL="${GOAL:-}"
out="$here/local/drive/$SEED"
mkdir -p "$out"
# The logs are overwritten per run; the pictures go to previous/ (the
# one run before, for comparison; user), or an earlier run's
# higher-numbered ones sit beside this run's and read as its
if ls "$out"/d[0-9]*.png >/dev/null 2>&1; then
	rm -rf "$out/previous"; mkdir -p "$out/previous"
	mv "$out"/d[0-9]*.png "$out/previous/"
fi
save="buildat_test_drive_$SEED"

cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
# KEEP_SAVE=1 rejoins the run before's world: the player is a returning
# one, placed at join ([PLAYER_POS_RACE])
[ -n "${KEEP_SAVE:-}" ] || rm -rf "../user/games/vanilla/saves/$save"
port=$(( 29800 + (SEED % 90) ))
srv=""; cli=""; drv=""; netsim=""
trap 'kill "$drv" 2>/dev/null; kill "$cli" 2>/dev/null; kill "${netsim:-}" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
{ echo "rawset(_G, \"FUZZ_SEED\", $SEED)"; cat "${FUZZ_LUA:-$me/fuzz.lua}"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P "$port" \
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
# NETSIM="--delay 80 --rate 2000 --loss 2": the client goes through
# util/netsim.py's lossy link to the server ([NET_SIM]); the proxy's port
# is the server's plus a hundred
cport=$port
if [ -n "${NETSIM:-}" ]; then
	cport=$((port + 100))
	python3 "$here/util/netsim.py" --listen "$cport" --to "localhost:$port" \
		$NETSIM > "$out/netsim.log" 2>&1 &
	netsim=$!
	sleep 1
fi
# COLD=1: the client starts with an empty cache of its own, so every file
# the server has is fetched at join ([PLAYER_POS_RACE]: the race is between
# that bulk and the first player_pos)
cold=""
if [ -n "${COLD:-}" ]; then
	rm -rf "$out/cache"; cold="-C $out/cache"
fi
bin/buildat -s "localhost:$cport" -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" $cold \
	-c - < "$fifo" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log" &
cli=$!
exec 3> "$fifo"
# The first forty seconds are the world loading around the player, as in
# the fuzz walk; four minutes over a capped link, where VoxeLibre's
# media and first chunks take that long ([NET_SIM]; simplified: a wait,
# where the driver could read the world's arrival off its first scans)
START_WAIT="${START_WAIT:-$([ -n "${NETSIM:-}" ] && echo 240 || echo 40)}"
echo "delay $((START_WAIT * 1000))" >&3
# A client that leaves during the wait -- disconnected, crashed -- ends
# the run there (user, 2026-09-21): a driver started after it would open
# the fifo for a reader that is gone and wait for nothing
for i in $(seq 1 "$START_WAIT"); do
	kill -0 "$cli" 2>/dev/null || break
	sleep 1
done
drv=
if kill -0 "$cli" 2>/dev/null; then
	python3 "$me/drive.py" "$out/cli.log" "$fifo" "$MINUTES" "$out" "$SEED" $GOAL \
		> "$out/drive.log" 2>&1 &
	drv=$!
else
	echo "drive: FAILED disconnected: the client left during the start wait" > "$out/drive.log"
fi

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
# The driver ends itself on a disconnect it sees; one blocked on the fifo
# with the client gone is ended here
if [ -n "$drv" ] && kill -0 "$drv" 2>/dev/null; then
	sleep 2
	kill "$drv" 2>/dev/null
fi
[ -n "$drv" ] && wait "$drv" 2>/dev/null
exec 3>&-
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done

. "$me/verdict.sh"
grep "^drive: FAILED" "$out/drive.log" | sed 's/^drive: /FAIL: drive: /' >&2
grep -q "^drive: FAILED" "$out/drive.log" && status=1
grep "^drive: GOAL" "$out/drive.log" | sed 's/^drive: //'
grep -q "^drive: GOAL .* not met" "$out/drive.log" && status=1
echo "turns: $(grep -c "^drive: turn .* rule" "$out/drive.log"), rules: $(
	grep -o "rule [a-z_]*" "$out/drive.log" | sort | uniq -c | sort -rn |
	awk '{printf "%s %s, ", $3, $1}' | sed 's/, $//')"
exit $status
