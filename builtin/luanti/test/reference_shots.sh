#!/bin/bash
# [OFFICIAL_SHOTS]: official Luanti's half of the reference shot set, taken
# by a script rather than by hand. See doc/plan/rendering_plan.md.
#
#   builtin/luanti/test/reference_shots.sh <fixture> [config]
#
# A fixture is a seed and its mapgen settings, never a world directory -- see
# "A fixture is a seed, never a copy". The world is generated into a cache
# under local/reference_worlds/ and reused if it is already there, so a bulk
# session pays for the terrain once. The worldmod in it is
# builtin/luanti/test/reference_views.lua, the same file this module runs as
# its own fixture, so the two sides line up by construction rather than by
# aim.
#
# It waits for the fixture's own "REFSHOT <n> <name>" line in the server log
# and shoots within a second of it, rather than counting seconds: the aim is
# re-asserted every second, so a shot taken right after one is the one least
# likely to have been spoiled by the desktop's real mouse.
set -u

# The repository root, from builtin/luanti/test/
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
fixture="${1:?reference | snow}"
conf="${2:-$me/reference_shots.conf}"
out="${OUT_DIR:-$here/local/reference_shots/official}"
luanti=~/projects/luanti
# The patched client, branch buildat-refshots: no mouse look, no pointer grab,
# no pausing when unfocused, no damage. A run shares the desktop, and every
# one of those cost pictures before the branch existed. Build it with
# `git checkout buildat-refshots && make -j` and keep bin/luanti as it was.
bin=${LUANTI_BIN:-./bin/luanti-refshots}

case "$fixture" in
reference)
	seed=2845188330406634615
	meta="mg_name = valleys
water_level = 1
mg_flags = caves, nodungeons, light, decorations, biomes, ores
chunksize = 5"
	;;
snow)
	echo "the snow viewpoint is viewpoint 5 of the reference world now;" >&2
	echo "run: $0 reference" >&2
	exit 2
	;;
*)
	echo "unknown fixture: $fixture" >&2; exit 2 ;;
esac

[ -f "$conf" ] || { echo "no config at $conf" >&2; exit 2; }

# The cache. Kept, not deleted: a bulk session generates the terrain once.
work="$here/local/reference_worlds/$seed"
if [ ! -d "$work" ] && [ -n "${src_world:-}" ]; then
	echo "copying $(eval echo "$src_world") into $work  (cannot be regenerated; see the snow case)"
	mkdir -p "$(dirname "$work")"
	cp -r "$(eval echo "$src_world")" "$work"
elif [ ! -d "$work" ]; then
	echo "generating $seed into $work"
	mkdir -p "$work"
	cat > "$work/world.mt" <<-EOF
		gameid = mineclone2
		backend = sqlite3
		player_backend = sqlite3
		auth_backend = sqlite3
		mod_storage_backend = sqlite3
		world_name = refshots_$seed
		creative_mode = false
		enable_damage = false
		server_announce = false
	EOF
	{ echo "seed = $seed"; [ -n "$meta" ] && echo "$meta"
		echo "[end_of_params]"; } > "$work/map_meta.txt"
else
	echo "reusing cached world $work"
fi

mkdir -p "$out" "$work/worldmods/refviews"
cp "$me/reference_views.lua" \
	"$work/worldmods/refviews/init.lua"
printf 'name = refviews\n' > "$work/worldmods/refviews/mod.conf"

log=$(mktemp /tmp/refshots_srv.XXXXXX.log)
port=$(( 31000 + (RANDOM % 200) ))
cd "$luanti"
"$bin" --server --world "$work" --port "$port" --config "$conf" \
	> "$log" 2>&1 &
srv=$!
# A mineclone2 world takes more than five seconds to load, and a freshly
# generated one takes longer than a cached one
for i in $(seq 1 300); do
	grep -q "Server for gameid" "$log" 2>/dev/null && break
	sleep 1
done
sleep 5

"$bin" --go --address 127.0.0.1 --port "$port" --name ref \
	--config "$conf" > /tmp/refshots_cli.log 2>&1 &
cli=$!

# The window, by the client's own pid rather than by its title. `xdotool
# search` walks the whole window tree and hangs on this desktop; wmctrl -lp
# is one EWMH query. By pid also cannot photograph the wrong renderer, which
# a title match can when a buildat client is on screen at the same time.
win=""
for i in $(seq 1 40); do
	sleep 1
	win=$(wmctrl -lp 2>/dev/null | awk -v p="$cli" '$3 == p {print $1; exit}')
	[ -n "$win" ] && break
done
if [ -z "$win" ]; then
	echo "no window for pid $cli after 40s" >&2
	kill "$cli" "$srv" 2>/dev/null; exit 1
fi
echo "window=$win  log=$log  out=$out"

# Wait for the fixture to say how many states this world has rather than
# guessing: a wrong count makes the deadline wrong, and an over-long deadline
# is what let a third cycle overwrite a good set with a spoiled one.
total=""
for i in $(seq 1 60); do
	total=$(grep -o "REFSHOT world seed .*, [0-9]* states" "$log" | \
			grep -o "[0-9]* states" | grep -o "[0-9]*" | tail -1)
	[ -n "$total" ] && break
	sleep 1
done
total=${total:-16}
echo "states=$total"
# Two full cycles, overwriting: the world generates lazily as the player is
# teleported, so the first pass through a viewpoint can photograph terrain
# that has not arrived. The second cycle overwrites it with a warm one, which
# is cheaper than a separate warm-up run -- a cycle is only four seconds a
# state.
#
# And the shot is taken late in the hold rather than right after the aim.
# "Within a second of the aim" existed only to dodge the desktop's real
# mouse; inside a granted window, settled terrain is worth more.
# Exactly two cycles' worth of shots, counted rather than timed: the first
# pass through a viewpoint can photograph terrain that has not arrived, the
# second overwrites it warm, and a third is only a chance to overwrite a good
# picture with a spoiled one.
want=$(( total * 2 ))
taken=0
deadline=$(( $(date +%s) + total * 6 * 2 + 60 ))
last=""
while [ "$taken" -lt "$want" ] && [ "$(date +%s)" -lt "$deadline" ]; do
	line=$(grep -o "REFSHOT [0-9]* [0-9a-z_]*" "$log" | tail -1)
	name=$(echo "$line" | cut -d' ' -f3)
	if [ -n "$name" ] && [ "$name" != "$last" ]; then
		sleep 2.5
		if import -window "$win" "$out/$name.png" 2>/dev/null; then
			taken=$((taken + 1))
			echo "shot $name"
		else
			echo "MISSED $name" >&2
		fi
		last="$name"
	fi
	sleep 0.5
	kill -0 "$cli" 2>/dev/null || break
done

kill "$cli" 2>/dev/null
sleep 1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
kill -9 "$srv" 2>/dev/null
echo "done: $(ls "$out" | wc -l) pictures in $out"
