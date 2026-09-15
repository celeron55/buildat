#!/bin/bash
# [OFFICIAL_SHOTS]: official Luanti's half of the reference shot set, taken
# by a script rather than by hand. See doc/plan/rendering_plan.md.
#
# The world is a copy, so the reference itself is never mutated, and the
# worldmod in the copy is builtin/luanti/test/reference_views.lua -- the same
# file this module runs as its own fixture, so the two sides line up by
# construction rather than by aim.
#
#   util/reference_shots.sh <world-to-copy> [config]
#
# It waits for the fixture's own "REFSHOT <n> <name>" line in the server log
# and shoots within a second of it, rather than counting seconds: the aim is
# re-asserted every second, so a shot taken right after one is the one least
# likely to have been spoiled by the desktop's real mouse.
set -u
src="${1:?a world to copy}"
conf="${2:-$HOME/.claude/jobs/4fbe3c07/tmp/ref.conf}"
out="${OUT_DIR:-/home/celeron55/projects/buildat/local/reference_shots/official}"
luanti=~/projects/luanti
work="$luanti/worlds/buildat_ref_shots"
log=$(mktemp /tmp/refshots_srv.XXXXXX.log)

mkdir -p "$out"
rm -rf "$work"
cp -r "$src" "$work"
mkdir -p "$work/worldmods/refviews"
cp /home/celeron55/projects/buildat/builtin/luanti/test/reference_views.lua \
	"$work/worldmods/refviews/init.lua"
printf 'name = refviews\n' > "$work/worldmods/refviews/mod.conf"

port=$(( 31000 + (RANDOM % 200) ))
cd "$luanti"
./bin/luanti --server --world "$work" --port "$port" --config "$conf" \
	> "$log" 2>&1 &
srv=$!
# A mineclone2 world takes more than five seconds to load
for i in $(seq 1 180); do
	grep -q "Server for gameid" "$log" 2>/dev/null && break
	sleep 1
done
sleep 5

./bin/luanti --go --address 127.0.0.1 --port "$port" --name ref \
	--config "$conf" > /tmp/refshots_cli.log 2>&1 &
cli=$!
sleep 10
win=$(xdotool search --name "Luanti" 2>/dev/null | tail -1)
echo "window=$win  log=$log  out=$out"

total=$(grep -o "REFSHOT world seed .*, [0-9]* states" "$log" | \
		grep -o "[0-9]* states" | grep -o "[0-9]*")
total=${total:-20}
echo "states=$total"
seen=0
while [ "$seen" -lt "$total" ]; do
	line=$(grep -o "REFSHOT [0-9]* [0-9a-z_]*" "$log" | tail -1)
	n=$(echo "$line" | cut -d' ' -f2)
	name=$(echo "$line" | cut -d' ' -f3)
	if [ -n "$name" ] && [ ! -f "$out/$name.png" ]; then
		import -window "$win" "$out/$name.png" 2>/dev/null && \
			echo "shot $n $name" && seen=$((seen + 1))
	fi
	sleep 1
	kill -0 "$cli" 2>/dev/null || break
done

kill "$cli" 2>/dev/null
sleep 1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
kill -9 "$srv" 2>/dev/null
echo "done: $(ls "$out" | wc -l) pictures in $out"
