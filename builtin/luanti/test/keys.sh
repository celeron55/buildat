#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 24s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# covers: src/client/command_seq.cpp src/client/command_seq.h
# [KEY_BINDINGS]: a rebound key walks the player. user/shared/vanilla/settings.json
# holds key.forward=U; a devtest client joins, holds U for three seconds,
# and the scan's position has to have moved; the scan's keys line has to
# say forward=U*. The settings.json is put back after. Prints PASS or FAIL.
#
#   builtin/luanti/test/keys.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_keys.XXXXXX")
cd "$here/Build"
settings=$BUILDAT_USER_PATH/shared/vanilla/settings.json
mkdir -p $BUILDAT_USER_PATH/shared/vanilla
[ -f "$settings" ] && cp "$settings" "$tmp/settings.json.bak"
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null;
	if [ -f "$tmp/settings.json.bak" ]; then cp "$tmp/settings.json.bak" "$settings"; else rm -f "$settings"; fi;
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"' EXIT
echo '{"render_mode": "pbr", "import_paths": [], "keys": {"forward": "U"}}' > "$settings"
rm -rf $BUILDAT_USER_PATH/apps/vanilla/saves/buildat_test_keys
srv=""; cli=""
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_keys \
	start_server "$tmp/srv.log" "Mods loaded" 200 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla ||
	{ echo "FAIL: the server did not start"; exit 1; }
port=$SERVER_PORT
sleep 3
srv=$(check_pgrep buildat_server | head -1)
{ echo "delay 15000"; echo "event scan before"; echo "keydown U"; echo "delay 3000"
	echo "keyup U"; echo "delay 1000"; echo "event scan after"; echo "quit"; } > "$tmp/cmds.txt"
bin/buildat -s "localhost:$port" -w 640x360 -l 3 -c @"$tmp/cmds.txt" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
# The scan's lines say "scan scan:" whatever the word given; the two
# scans are told apart by their order
for i in $(seq 1 60); do
	[ "$(grep -ac "scan scan: self at" "$tmp/cli.log")" -ge 2 ] && break
	kill -0 "$cli" 2>/dev/null || break
	sleep 1
done
before=$(grep -a "scan scan: self at" "$tmp/cli.log" | sed -n '1s/.*self at \([^ ]*\) .*/\1/p')
after=$(grep -a "scan scan: self at" "$tmp/cli.log" | sed -n '2s/.*self at \([^ ]*\) .*/\1/p')
keys=$(grep -a "scan scan: keys" "$tmp/cli.log" | tail -1 | grep -o "forward=[^ ]*")
echo "keys: $keys; before $before, after $after"
echo "logs in $tmp"
if [ "$keys" = "forward=U*" ] && [ -n "$before" ] && [ "$before" != "$after" ]; then
	echo PASS
else
	echo FAIL
	exit 1
fi
