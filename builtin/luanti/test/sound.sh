#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [NO_SOUND]: **does a sound the server asks for reach the speakers**.
# Nothing in this tree could hear, so a room that placed no listener
# played into nowhere for as long as it took somebody to notice, and
# the question "is devtest silent too" could only be answered by ear.
#
#   builtin/luanti/test/sound.sh
#
# sound.lua asks for three sounds every four seconds through
# core.sound_play(), which is the one thing that is unambiguously a
# packet -- digging and placing are played client-side by official
# Luanti and this tree does not implement them at all.
#
# **The measurement is the client's own PipeWire stream**, not the
# desk's speakers: pw-record on the node buildat writes into, and what
# is asserted is that the samples are not all zero. Nothing is played
# out loud that was not already going to be.
#
# **-o sound_mute=0**: a -c run is muted on purpose (app.cpp:1028,
# "a driven run playing a game's music through the developer's
# speakers"), so a check that wants to hear has to say so.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/lib.sh" 2>/dev/null || true
out="$here/local/sound"; mkdir -p "$out"
save=buildat_test_sound
port=31998
cd "$here/Build"
command -v pw-record >/dev/null || {
	echo "SKIP: no pw-record; this measures the client's own audio stream" >&2
	exit 77; }
command -v pw-dump >/dev/null || { echo "SKIP: no pw-dump" >&2; exit 77; }
[ -d "$here/user/luanti/games/devtest" ] || {
	echo "SKIP: devtest is not installed" >&2; exit 77; }
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2; exit 77
fi
rm -rf "$here/user/games/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=$save \
	BUILDAT_LUANTI_LUA="$me/sound.lua" \
	bin/buildat_server -m ../games/vanilla -D ../user -P "$port" -l 3 \
	> "$out/srv.log" 2>&1 &
srv=$!
for i in $(seq 1 120); do
	grep -aq "Running world" "$out/srv.log" && break
	sleep 1
done
if ! grep -aq "Running world" "$out/srv.log"; then
	echo "SKIP: the world did not come up"; kill -9 "$srv" 2>/dev/null; exit 77
fi
{ echo "delay 90000"; echo "quit"; } > "$out/cmds.txt"
timeout 200 bin/buildat -s localhost:"$port" -D ../user -o sound_mute=0 \
	-w 640x400 -l 3 -L "$out/cli.log" -c @"$out/cmds.txt" > /dev/null 2>&1 &
cli=$!
# The join is a minute of world loading away; the fixture then asks
# every four seconds, so the capture only has to land inside that
for i in $(seq 1 150); do
	grep -aq "sound check: three asked" "$out/srv.log" && break
	sleep 1
done
node=$(pw-dump 2>/dev/null | python3 -c '
import json, sys
for o in json.load(sys.stdin):
    p = o.get("info", {}).get("props", {})
    if p.get("media.class") == "Stream/Output/Audio" and \
            "buildat" in str(p.get("node.name", "")).lower():
        print(o["id"]); break')
peak=0
if [ -n "$node" ]; then
	timeout 12 pw-record --target "$node" "$out/cap.wav" >/dev/null 2>&1
	peak=$(python3 - "$out/cap.wav" <<'PY'
import sys, wave, array
try:
    w = wave.open(sys.argv[1])
    a = array.array("h")
    a.frombytes(w.readframes(w.getnframes()))
    print(max(max(a), -min(a)) if a else 0)
except Exception:
    print(0)
PY
)
fi
kill -9 "$cli" 2>/dev/null; wait "$cli" 2>/dev/null
kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
rm -rf "$here/user/games/vanilla/saves/$save"
asked=$(grep -ac "sound check: three asked" "$out/srv.log")
echo "the server asked $asked times; the client's own stream peaked at $peak"
if [ -z "$node" ]; then
	echo "SKIP: the client opened no audio stream to measure"
	exit 77
fi
if [ "$asked" -lt 1 ]; then
	echo "FAIL: the fixture never asked for a sound"
	exit 1
fi
if [ "${peak:-0}" -lt 200 ]; then
	echo "FAIL: a sound the server asked for came out as silence"
	exit 1
fi
echo "PASS: a sound the server asks for reaches the client's audio stream"
