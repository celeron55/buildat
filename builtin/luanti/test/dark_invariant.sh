#!/bin/bash
# [DARK_INVARIANT]: a place with no sky in sight is as dark at noon as at
# midnight. The fixture carves a sealed room deep inside stone -- no
# opening, no ray from any surface in it reaches the sky -- and the same
# room is shot at 02:00 and at 13:00. The two pictures have to be the same
# one; what is printed is how far apart they are.
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
{ echo "wait_log 240000 chat: dark: hour 0200"
	echo "delay 4000"
	echo "screenshot $out/h0200.png"
	echo "wait_log 60000 chat: dark: hour 1300"
	echo "delay 4000"
	echo "screenshot $out/h1300.png"
	echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
# ABLATE=bounce|amb|ground|lamp turns a term off in the client, which is
# how the source of a leak is found ([DARK_INVARIANT] 2)
env ${ABLATE:+BUILDAT_LUANTI_ABLATE=$ABLATE} \
	bin/buildat -s localhost:29789 -w 640x480 -l 3 -c @"$out/cmds.txt" 2>&1 |
	sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep -a "chat: dark: hour" "$out/cli.log" | sed 's/.*chat: //'
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
a = Image.open("%s/h0200.png" % out).convert("RGB")
b = Image.open("%s/h1300.png" % out).convert("RGB")
w, h = a.size
# The world, not the HUD: the middle of the frame, away from the hotbar and
# the status rows
box = (w // 4, h // 6, 3 * w // 4, 2 * h // 3)
da, db = list(a.crop(box).getdata()), list(b.crop(box).getdata())
ma = sum(sum(p) for p in da) / (3.0 * len(da))
mb = sum(sum(p) for p in db) / (3.0 * len(db))
worst = max(max(abs(p[i] - q[i]) for i in range(3)) for p, q in zip(da, db))
mean = sum(sum(abs(p[i] - q[i]) for i in range(3)) for p, q in
		zip(da, db)) / (3.0 * len(da))
print("the sealed room reads %.2f at 02:00 and %.2f at 13:00" % (ma, mb))
print("apart by %.2f of a level on average, %d at the worst pixel" %
		(mean, worst))
ok = mean < 0.5 and worst <= 2
print("PASS: the hour does not reach a place with no sky in sight" if ok
		else "FAIL: the sky reaches a sealed room")
sys.exit(0 if ok else 1)
PY
