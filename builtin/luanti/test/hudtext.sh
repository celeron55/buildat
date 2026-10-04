#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 195s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [UI_PARITY]: a HUD text element's size.X multiplies the font, as Luanti's
# hud.cpp does it (`font_size *= e->size.X`). The fixture adds the same word
# at size 1 and size 3 and the scan measures what was drawn.
#
#   builtin/luanti/test/hudtext.sh
#
# **Its two hundred seconds are devtest's own start**, not delays to
# trim (looked at 2026-09-25, when [CHECK_COST] went through the tier):
# the drive carries 5.5 s of `delay` in all, and the rest is the server
# loading a game and generating a world before the fixture can add a
# HUD element. The same is true of dawn_light.sh, whose three-second
# delays were measured and are the light settling.
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/lib.sh"
out="$here/local/hudtext"; mkdir -p "$out"
save=buildat_test_hudtext
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/hudtext.lua" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -P 29791 \
	-l 3 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
{ echo "wait_log 180000 hud text check: four lines added"
	echo "delay 4000"
	echo "event scan"
	echo "delay 1500"
	echo "quit"; } > "$out/cmds.txt"
# A run that has stopped logging is taken down rather than waited out
run_client 60 "$out/cli.log" bin/buildat -s localhost:29791 -w 1280x720 \
	-l 3 -c @"$out/cmds.txt"
sed -i -e 's/\x1b\[[0-9;]*m//g' "$out/cli.log"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
python3 - "$out/cli.log" <<'PY'
import re, sys
log = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
found = {}
for m in re.finditer(r'hud text "(sized\d)" size "([^"]*)" at (-?\d+),(-?\d+) '
		r'size (\d+)x(\d+)', log):
	found[m.group(1)] = (int(m.group(5)), int(m.group(6)), m.group(2))
if len(found) < 2:
	print("FAIL: the scan found %s" % sorted(found))
	sys.exit(1)
one, three = found["sized1"], found["sized3"]
print("size %r drew %dx%d, size %r drew %dx%d" % (one[2], one[0], one[1],
		three[2], three[0], three[1]))
ratio = three[1] / float(one[1])
print("three times the size is %.2f times the height" % ratio)
ok = 2.5 < ratio < 3.5
print("PASS: a HUD text element's size multiplies the font" if ok else
		"FAIL: size.X is not what the font is scaled by")
sys.exit(0 if ok else 1)
PY
