#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 21s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FORMSPEC_SCROLL]: a formspec dropdown is drawn, opens on a click and
# sends the item that was picked. The fixture shows a form with
# dropdown[...;alpha,beta,gamma;1]; the client finds the box by its text,
# clicks it, clicks "gamma" in the list that opens, and the server says
# what it received.
#
#   builtin/luanti/test/dropdown.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/dropdown"
mkdir -p "$out"
save=buildat_test_dropdown
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/dropdown.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29785 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
sleep 5
srv=$(check_pgrep buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s localhost:29785 -w 1280x720 -l 3 -c - < "$fifo" > "$out/cli.log" 2>&1 &
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/srv.log" "$here/util" <<'PY'
import sys, time
log, fifo, srv = sys.argv[1:4]
sys.path.insert(0, sys.argv[4])
import uidrive
d = uidrive.Drive(log, fifo)
# The form comes up three seconds after the join
uidrive.wait_log(srv, "dropdown: the form is shown", 90)
time.sleep(3)
els = d.scan()
box = uidrive.find(els, "alpha")
if not box:
    d.fail("no dropdown on the screen; saw " + uidrive.texts(els))
d.click(box)
els = d.scan()
item = uidrive.find(els, "gamma")
if not item:
    d.fail("the list did not open; saw " + uidrive.texts(els))
d.click(item)
time.sleep(1.5)
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "dropdown: fields pick=" in l]
if not got:
    d.fail("the server received no fields")
last = got[-1].split("dropdown: fields ")[-1]
if last != "pick=gamma":
    d.fail("the server received " + last)
print("PASS: the picked item is what was sent")
d.write("quit")
PY
status=$?
exec 3>&-
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
