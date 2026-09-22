#!/bin/bash
# [DARK_INVARIANT]'s two probe pairs. The fixture carves a sealed room deep
# inside stone -- no opening, no ray from any surface in it reaches the sky
# -- and a second room of the same shape with a corridor and a shaft out to
# daylight, and shoots both at 02:00 and at 13:00.
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
#   builtin/luanti/test/dark_invariant.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/dark_invariant${ABLATE:+_$ABLATE}${BUILDAT_SKY_REACH:+_reach$BUILDAT_SKY_REACH}"
mkdir -p "$out"
save=buildat_test_dark
ABLATE="${ABLATE:-}"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla/saves/$save"
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
{ for shot in sealed_0200 sealed_1300 mouth_0200 mouth_1300; do
		spot=${shot%%_*}; hour=${shot##*_}
		echo "wait_log 240000 chat: dark: $spot hour $hour"
		echo "delay 6000"
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
grep -a "chat: dark: hour" "$out/cli.log" | sed 's/.*chat: //'
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]

def read(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("RGB")
	w, h = im.size
	# The world, not the HUD: the middle of the frame, away from the
	# hotbar and the status rows
	box = (w // 4, h // 6, 3 * w // 4, 2 * h // 3)
	return list(im.crop(box).getdata())

def compare(spot):
	a, b = read(spot + "_0200"), read(spot + "_1300")
	ma = sum(sum(p) for p in a) / (3.0 * len(a))
	mb = sum(sum(p) for p in b) / (3.0 * len(b))
	worst = max(max(abs(p[i] - q[i]) for i in range(3)) for p, q in zip(a, b))
	mean = sum(sum(abs(p[i] - q[i]) for i in range(3)) for p, q in
			zip(a, b)) / (3.0 * len(a))
	print("%-6s reads %6.2f at 02:00 and %6.2f at 13:00, apart by %6.2f "
			"of a level on average, %d at the worst pixel" %
			(spot, ma, mb, mean, worst))
	return mean, worst

sealed_mean, sealed_worst = compare("sealed")
mouth_mean, mouth_worst = compare("mouth")
# The sealed pair has to be one picture; the mouthed one has to be two,
# or a fix that passes the first by killing the ray term passes everything
# A settled run reads 0.00 of a level and no pixel apart at all. The
# tolerance is for a run whose relight had not quite finished when the
# first picture was asked for, which reads up to about one level; without
# the sky-reach term the pair is 24 to 101 levels apart, so nothing near
# the threshold is ambiguous.
sealed_ok = sealed_mean < 1.0 and sealed_worst <= 8
mouth_ok = mouth_mean > 2.0
if not sealed_ok:
	print("FAIL: the sky reaches a sealed room")
if not mouth_ok:
	print("FAIL: a wall whose rays reach a mouth no longer follows the hour")
if sealed_ok and mouth_ok:
	print("PASS: the hour stops at the sealed room and not before it")
sys.exit(0 if (sealed_ok and mouth_ok) else 1)
PY
