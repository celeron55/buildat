#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [DARK_INVARIANT]'s two probe pairs, **one a run**. The fixture carves a
# sealed room deep inside stone -- no opening, no ray from any surface in
# it reaches the sky -- and a second room of the same shape with a
# corridor and a shaft out to daylight, and shoots the one SPOT names at
# 02:00 and at 13:00:
#
#   builtin/luanti/test/dark_invariant.sh          # the sealed room
#   SPOT=mouth builtin/luanti/test/dark_invariant.sh
#
# A run visits one room because the player is *spawned* there. A server
# that moves the player between stops is applied by the client, but the
# command sequence taking the pictures runs minutes behind the server's
# schedule while the mesher is saturated, so the picture lands against
# the wrong stop -- every frame of 2026-09-25's four-stop runs carried
# the sealed room's coordinates, the mouthed pair included.
#
# The sealed pair has to be one picture. The mouthed pair has to be two:
# the wall the camera reads there has no sky in sight and both nibbles
# nought, but its rays find the mouth around a corner, and that is the
# light Luanti's four bits throw away. A fix that passes the sealed pair by
# killing the ray term fails the mouthed one.
#
# BUILDAT_SKY_REACH=<n> on the client is the term under test; unset, the
# sealed half fails, which is what it is for.
#
# The mode is the one to judge it in: pbr by default, since that is what a
# player sees. MODE=unlit or shadows reads the parity paths.
#
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
SPOT="${SPOT:-sealed}"
out="$here/local/dark_invariant_$SPOT${ABLATE:+_$ABLATE}${BUILDAT_SKY_REACH:+_reach$BUILDAT_SKY_REACH}"
mkdir -p "$out"
save=buildat_test_dark
ABLATE="${ABLATE:-}"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
BUILDAT_DARK_SPOT="$SPOT" \
	BUILDAT_LUANTI_GAME="${GAME:-mineclone2}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_PBR="${MODE:-pbr}" \
	BUILDAT_LUANTI_LUA="$me/dark_invariant.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P 29789 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
# Two pictures of every stop, twenty seconds apart, and the pair has to
# agree before either is read. The chat line says the server has set the
# hour and placed the player; it says nothing about the client having the
# room. With a mapgen backlog of five thousand chunks behind it the first
# stop was drawn some runs and still black in others six seconds later,
# and a black frame reads 0.51 of a level against a drawn dark room's
# 1.43 -- which came out as the sky reaching a sealed room.
{ echo "wait_log 240000 chat: dark: $SPOT hour warm"
	for hour in 0200 1300; do
		shot=${SPOT}_$hour
		echo "wait_log 240000 chat: dark: $SPOT hour $hour"
		echo "delay 10000"
		echo "screenshot $out/${shot}_early.png"
		echo "delay 20000"
		echo "screenshot $out/$shot.png"
	done
	echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
# ABLATE=bounce|amb|ground|lamp turns a term off in the client, which is
# how the source of a leak is found ([DARK_INVARIANT] 2).
#
# BUILDAT_LUANTI_KEY pins the metered exposure key. Without it the pbr
# path's meter is what the four frames read: a dark room at 02:00 opens
# the meter right up and the same room at 13:00 closes it, so a wall that
# cannot see the sun came out *brighter* at night (150 against 86,
# 2026-09-22). Pinned, a level in one frame is a level in the next.
env ${ABLATE:+BUILDAT_LUANTI_ABLATE=$ABLATE} \
	BUILDAT_LUANTI_KEY="${KEY:-0.15}" \
	bin/buildat -s localhost:29789 -w 640x480 -l 3 -c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
# Both probes read a wall with no daylight of its own: the sky nibble
# nought. That is the condition for the term under test to be asked
# there at all -- where the flood has already put daylight on the
# surface, the picture says nothing about rays. The other nibble is the
# artificial one and it is allowed to be anything: it does not follow
# the hour, and the mapgen's lava reaches the sealed room at 6.
lit=$(grep -a "chat: dark: .* light " "$out/cli.log" | sed 's/.*chat: //' |
	grep -v "light 0/")
if [ -n "$lit" ]; then
	echo "$lit"
	echo "FAIL: a probe reads a wall the sky floods directly"
	exit 1
fi
grep -a "chat: dark: .* light " "$out/cli.log" | sed 's/.*chat: //'
python3 - "$out" "$SPOT" <<'PY'
import sys
from PIL import Image
out, spot = sys.argv[1], sys.argv[2]

def read(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("RGB")
	w, h = im.size
	# The world, not the HUD: the middle of the frame, away from the
	# hotbar and the status rows
	box = (w // 4, h // 6, 3 * w // 4, 2 * h // 3)
	return list(im.crop(box).getdata())

def apart(a, b):
	mean = sum(sum(abs(p[i] - q[i]) for i in range(3)) for p, q in
			zip(a, b)) / (3.0 * len(a))
	worst = max(max(abs(p[i] - q[i]) for i in range(3)) for p, q in zip(a, b))
	return mean, worst

still = []
for hour in ("0200", "1300"):
	# The same stop twenty seconds apart. A stop whose chunks were still
	# arriving reads one frame of a room and one of the dark before it,
	# which is about a level of difference -- the size of the reading.
	mean, _ = apart(read("%s_%s" % (spot, hour)),
			read("%s_%s_early" % (spot, hour)))
	if mean >= 0.2:
		print("%s at %s was still arriving: its two frames are %.2f of a "
				"level apart" % (spot, hour, mean))
		still.append(hour)

a, b = read(spot + "_0200"), read(spot + "_1300")
ma = sum(sum(p) for p in a) / (3.0 * len(a))
mb = sum(sum(p) for p in b) / (3.0 * len(b))
mean, worst = apart(a, b)
print("%-6s reads %6.2f at 02:00 and %6.2f at 13:00, apart by %6.2f "
		"of a level on average, %d at the worst pixel" %
		(spot, ma, mb, mean, worst))
if still:
	print("FAIL: the room was not drawn when it was read (%s)" %
			", ".join(still))
	sys.exit(1)
# The sealed pair has to be one picture; the mouthed one has to be two,
# or a fix that passes the first by killing the ray term passes
# everything. A settled run reads 0.00 of a level and no pixel apart at
# all; the tolerance is for a relight that had not quite finished.
if spot == "sealed":
	ok = mean < 1.0 and worst <= 8
	print("PASS: the hour stops at the sealed room" if ok else
			"FAIL: the sky reaches a sealed room")
else:
	ok = mean > 2.0
	print("PASS: a wall whose rays reach a mouth follows the hour" if ok
			else "FAIL: a wall whose rays reach a mouth no longer follows "
			"the hour")
sys.exit(0 if ok else 1)
PY
