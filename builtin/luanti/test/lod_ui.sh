#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 20s (this desk, 2026-09-26; local/run_all/costs corrects it per machine)
# [CLIENT_FRAME]: the distant terrain row, driven -- the launcher's menu,
# its "Luanti settings", "Reduced past half range" picked in the
# dropdown, and the settings file written. What this guards is the row
# reaching the far end: the pick goes to the server as a `lod_detail=`
# row, is kept in settings.json, comes back in the settings packet and
# turns into voxelworld's lod_distance. Every one of those is a name that
# can be misspelt in silence. Prints PASS or FAIL; settings.json is put
# back after.
#
#   builtin/luanti/test/lod_ui.sh
#
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/menu.lua
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_lod_ui.XXXXXX")
cd "$here/Build"
settings=$BUILDAT_USER_PATH/shared/vanilla/settings.json
mkdir -p $BUILDAT_USER_PATH/shared/vanilla
[ -f "$settings" ] && cp "$settings" "$tmp/settings.json.bak"
# An install from before [LOD_FULL_DEFAULT], whose saves wrote the old
# default under the old key: it must start at Full
printf '{"lod_detail": "half"}' > "$settings"
fifo="$tmp/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
cli=""
trap 'exec 3>&- 2>/dev/null; kill "$cli" 2>/dev/null; check_pkill -INT buildat_server 2>/dev/null;
	if [ -f "$tmp/settings.json.bak" ]; then cp "$tmp/settings.json.bak" "$settings"; else rm -f "$settings"; fi;
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"' EXIT
# The menu by name, not by preference: keys_ui.sh says why ([MENU_FALLBACK])
bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$tmp/cli.log" "$fifo" "$BUILDAT_USER_PATH/shared/vanilla/settings.json" <<'PY'
import re, sys, time
log, fifo, settings = sys.argv[1], sys.argv[2], sys.argv[3]
out = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        out.write(c + "\n")
    out.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(?: text "(.*)")?')
def scan(label):
    global seen
    write("delay 800", "event scan " + label)
    t0 = time.time()
    while time.time() - t0 < 30:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan %s: done" % label in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and ("scan %s:" % label) in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)), m.group(6) or ""))
            return els
        time.sleep(0.3)
    return None
def find(els, word):
    for e in els:
        if word.lower() in e[5].lower() and e[3] > 0:
            return e
    return None
def click(e):
    write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 150",
          "mouse_click left", "delay 300")
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
time.sleep(8)
write("text luanti sett")
els = scan("a")
if not els: fail("no menu scan")
b = find(els, "Luanti settings")
if not b: fail("no settings button; saw " + ", ".join(e[5] for e in els)[:300])
click(b)
# The game's server starts behind the row: scanned until its screen is up
# A dropdown since [UI_DROPDOWN]: scanned until its screen is up
row = None
for i in range(20):
    els = scan("b%d" % i)
    row = els and find(els, "Distant terrain detail")
    if row: break
    time.sleep(2)
if not row:
    fail("no distant terrain row; saw " + ", ".join(e[5] for e in els or [])[:300])
drops = [e for e in els[els.index(row):] if e[0] == "DropDownList"]
if not drops: fail("no distant terrain dropdown")
# One Down from where it opens: "half" only when it opened on Full, which
# an old install's stored half must ([LOD_FULL_DEFAULT]), and not the
# default, so the pick proves something
click(drops[0])
write("keypress Down", "delay 300", "keypress Return", "delay 800")
# The pick goes to the server, which writes the file
kept = ""
for i in range(20):
    time.sleep(1)
    try:
        kept = open(settings).read()
    except IOError:
        continue
    if '"distant_detail": "' in kept:
        break
if '"distant_detail": "half"' not in kept:
    fail("the file does not carry half (an old install's half did not "
         "start at Full, or the pick was lost): " + kept[:200])
print("PASS")
write("quit")
PY
status=$?
exec 3>&-
exit $status
# vim: set noet ts=4 sw=4:
