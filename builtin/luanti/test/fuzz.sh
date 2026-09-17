#!/bin/bash
# [AUTO_PLAYTEST] part 1: a fuzz run. A fresh world, a client that walks at
# random for MINUTES from a seeded RNG, and fuzz.lua asserting invariants on
# the server once a second. The runner reads both logs afterwards.
#
#   SEED=7 MINUTES=5 GAME=mineclone2 builtin/luanti/test/fuzz.sh
#
# The same SEED replays the same walk: it seeds both the world and the
# command file. What is written per run lands under local/fuzz/<seed>/:
# the command file, both logs, and a screenshot every thirty seconds for a
# person to look through when the run fails.
#
# Never beside another buildat_server: the save's sqlite and the desktop
# are one each.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
SEED="${SEED:-1}"
MINUTES="${MINUTES:-3}"
GAME="${GAME:-mineclone2}"
out="$here/local/fuzz/$SEED"
mkdir -p "$out"
save="buildat_test_fuzz_$SEED"

# The walk. Every step is one of a dozen actions with a random duration,
# each a discrete thing the invariants can see: turn, walk, jump, dig what
# is in front, place it, punch what is near, cycle the hotbar, open and
# close the inventory. awk's rand() is seeded, so the file is the seed's.
# A screenshot every thirty seconds of walk, and the mouse is never moved
# in absolute terms -- look sets the aim, which is all the fixture reads.
# The first forty seconds are the world loading around the player.
awk -v seed="$SEED" -v secs="$((MINUTES * 60))" -v out="$out" 'BEGIN {
	srand(seed)
	print "delay 40000"
	t = 0; shot = 0; yaw = 0
	while (t < secs) {
		r = rand()
		if (r < 0.25) {
			# turn, a little or a lot, mostly level
			yaw = (yaw + int(rand() * 120) - 60 + 360) % 360
			pitch = int(rand() * 60) - 30
			print "look " yaw " " pitch
			d = 0.2
		} else if (r < 0.50) {
			# A walk of 2-8 s that jumps every 1-5 s while W is held: a
			# voxel world is nothing but one-node steps, and a walk that
			# does not jump stands at the first rise for the rest of the
			# run with the invariants happy (user, 2026-09-17)
			d = 2 + rand() * 6
			print "keydown W"
			left = d
			while (left > 0) {
				gap = 1 + rand() * 4
				if (gap > left) gap = left
				print "delay " int(gap * 1000)
				left -= gap
				if (left > 0) print "keypress Space"
			}
			print "keyup W"
			waited = 1
		} else if (r < 0.58) {
			d = 1 + rand() * 2
			print "keydown W"; print "keypress Space"; print "delay " int(d * 1000)
			print "keyup W"
		} else if (r < 0.72) {
			# dig what is in front: a hold on the left button, looking a
			# little down so the ground is within reach
			print "look " yaw " " (-35 + int(rand() * 30))
			d = 1 + rand() * 2.5
			print "mouse_down left"; print "delay " int(d * 1000); print "mouse_up left"
		} else if (r < 0.80) {
			print "look " yaw " " (-50 + int(rand() * 20))
			print "mouse_click right"; d = 0.3
		} else if (r < 0.86) {
			# punch what is near: a click, not a hold
			print "look " yaw " " (int(rand() * 20) - 10)
			print "mouse_click left"; d = 0.3
		} else if (r < 0.94) {
			print "keypress " (1 + int(rand() * 9)); d = 0.2
		} else {
			print "keypress I"; print "delay 800"; print "keypress Escape"; d = 1
		}
		# The walk has spent its time already; everything else waits here
		if (!waited) print "delay " int(d * 1000)
		waited = 0
		t += d
		if (t - shot >= 30) {
			shot = t
			printf "screenshot %s/t%04d.png\n", out, int(t)
		}
	}
	print "quit"
}' > "$out/cmds.txt"

cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/luanti_launcher/saves/$save"
port=$(( 29800 + (SEED % 90) ))
srv=""; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
{ echo "rawset(_G, \"FUZZ_SEED\", $SEED)"; cat "$me/fuzz.lua"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -m ../games/luanti_launcher -D ../user -P "$port" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	grep -q "Shutdown:" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; tail -3 "$out/srv.log" >&2; exit 1; }

bin/buildat -s "localhost:$port" -w 1280x720 -l 3 -c @"$out/cmds.txt" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log" &
cli=$!
wait "$cli"
cli_status=$?
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done

# The verdict, out of the logs. Each line names the fault the plan lists it
# for; the fixture's own FAILED line carries its reason.
status=0
say() { echo "FAIL: $*" >&2; status=1; }
grep -a "fuzz: FAILED" "$out/srv.log" | sed 's/^.*fuzz: //' | while read -r l; do echo "FAIL: $l" >&2; done
grep -aq "fuzz: FAILED" "$out/srv.log" && status=1
grep -a " E " "$out/srv.log" | grep -av "fuzz:" | head -5 | sed 's/^/FAIL: server error: /' >&2
grep -aq " E " "$out/srv.log" && status=1
grep -aq "not held" "$out/srv.log" "$out/cli.log" && say "a held key read as not held ([HELD_KEY_FLAKE])"
grep -aq "input focus lost" "$out/cli.log" && say "the client lost input focus ([MOUSE_FOCUS_LOST])"
grep -aq "Lua runtime error\|Crash:" "$out/cli.log" && say "the client crashed or hit a Lua error"
[ "$cli_status" -eq 0 ] || say "the client exited $cli_status"
last=$(grep -a "fuzz: t=" "$out/srv.log" | tail -1 | sed 's/^.*fuzz: //')
[ -n "$last" ] || say "the fixture never ticked"
echo "seed $SEED, $MINUTES min: ${last:-no ticks}"
echo "logs and pictures in $out"
exit $status
