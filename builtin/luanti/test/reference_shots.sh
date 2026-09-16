#!/bin/bash
# [OFFICIAL_SHOTS]: official Luanti's half of the reference shot set, taken
# by a script rather than by hand. See doc/plan/rendering_plan.md.
#
#   builtin/luanti/test/reference_shots.sh <fixture> [config]
#
# A fixture is a seed and its mapgen settings, never a world directory -- see
# "A fixture is a seed, never a copy" -- and the settings are the whole of
# reference_world_map_meta.txt beside this file rather than a few keys out of
# it. The world is generated into a cache under local/reference_worlds/ and
# reused if it is already there, so a bulk session pays for the terrain once. The worldmod in it is
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
fixture="${1:?reference | check}"
conf="${2:-$me/reference_shots.conf}"
out="${OUT_DIR:-$here/local/reference_shots/official}"
luanti=~/projects/luanti
# The patched client, branch buildat-refshots: no mouse look, no pointer grab,
# no pausing when unfocused, no damage. A run shares the desktop, and every
# one of those cost pictures before the branch existed. Build it with
# `git checkout buildat-refshots && make -j` and keep bin/luanti as it was.
bin=${LUANTI_BIN:-./bin/luanti-refshots}

# The shooting half, which is the same whichever client is on screen: find its
# window, learn how many states the fixture has, and photograph each one late
# in its hold. builtin/luanti/test/reference_shots_module.sh calls it through
#
#   builtin/luanti/test/reference_shots.sh shoot <server log> <client pid> [dir]
#
# rather than carrying a second copy of it. Reads $log, $cli and $out.
shoot_states()
{
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
		kill "$cli" "${srv:-}" 2>/dev/null; exit 1
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
	# And the shot is taken in the middle of the hold rather than right after the
# aim.
	# "Within a second of the aim" existed only to dodge the desktop's real
	# mouse; inside a granted window, settled terrain is worth more.
	# Exactly two cycles' worth of shots, counted rather than timed: the first
	# pass through a viewpoint can photograph terrain that has not arrived, the
	# second overwrites it warm, and a third is only a chance to overwrite a good
	# picture with a spoiled one.
	# Cycles, overwriting: the first pass through a viewpoint can photograph
	# terrain that has not arrived and the next overwrites it warm. Two is
	# enough for a client that was handed a cached world; a client that has
	# just imported one is still meshing it through the second, which is why
	# reference_shots_module.sh asks for three.
	want=$(( total * ${CYCLES:-2} ))
	taken=0
	# Which states were actually photographed, so one that was dropped in both
	# cycles is reported rather than left as whatever an older run put there
	# under that name. A stale picture of the right place is the other thing
	# the two cheap tests cannot see.
	shotlist=$(mktemp /tmp/refshots_taken.XXXXXX)
	# Counted from the first shot rather than from here. What comes before it
	# is the client loading the world, which is ten seconds for official Luanti
	# on a cached world and a minute and a half for the module importing one --
	# charge that to the deadline and the second cycle is what gets cut short.
	# The outer cap is for a client that never gets there at all.
	deadline=$(( $(date +%s) + 900 ))
	last=""
	while [ "$taken" -lt "$want" ] && [ "$(date +%s)" -lt "$deadline" ]; do
		line=$(grep -o "REFSHOT [0-9]* [0-9a-z_]*_\(none\|rain\)" "$log" | tail -1)
		name=$(echo "$line" | cut -d' ' -f3)
		if [ -n "$name" ] && [ "$name" != "$last" ]; then
			sleep 4
			# The name was read before the exposure. If the fixture moved on
			# during it the picture is of the next state, and saving it under
			# this name is the one failure the two cheap tests below cannot
			# see -- it is a good picture of the wrong thing. A state is four
			# seconds when the server is warm and fifteen while it loads a
			# world around a teleporting player, so this is checked rather
			# than assumed; the state comes round again next cycle.
			now=$(grep -o "REFSHOT [0-9]* [0-9a-z_]*_\(none\|rain\)" "$log" | tail -1 | \
					cut -d' ' -f3)
			if [ "$now" != "$name" ]; then
				echo "moved during $name, dropped" >&2
				last="$name"
				sleep 0.5
				continue
			fi
			if import -window "$win" "$out/$name.png" 2>/dev/null; then
				taken=$((taken + 1))
				echo "$name" >> "$shotlist"
				# A state is six seconds in the fixture, and fourteen is what
				# a server loading a world around a teleporting player
				# actually takes: nine cut the third cycle short and left
				# eight cold pictures standing in a twenty-picture set
				[ "$taken" -eq 1 ] && deadline=$(( $(date +%s) + \
						total * 14 * ${CYCLES:-2} + 60 ))
				echo "shot $name"
			else
				echo "MISSED $name" >&2
			fi
			last="$name"
		fi
		sleep 0.5
		kill -0 "$cli" 2>/dev/null || break
	done
	got=$(sort -u "$shotlist" 2>/dev/null | wc -l)
	# What this run shot, so the check reads those rather than the whole
	# directory: a probe cycle re-takes two of twenty and the other eighteen
	# are last round's, which are not this change's to answer for
	shot_names=$(sort -u "$shotlist" 2>/dev/null)
	rm -f "$shotlist"
	if [ "$got" -lt "$total" ]; then
		echo "only $got of $total states were shot; the rest are stale" >&2
	fi
	# Nothing at all is a run that did not happen -- the server lost a race for
	# the save's sqlite, or the client never drew. The caller retries on it.
	[ "$got" -gt 0 ]
}

# Two cheap tests, which catch every failure this run has actually had: the
# "You died" dialog fills the screen centre with one flat grey, and a player
# who fell through unloaded ground photographs flat sky. Neither catches the
# failure that cost the most -- a world that generated fine and is simply not
# the right world -- so one look per viewpoint stays part of the recipe.
#
#   builtin/luanti/test/reference_shots.sh check
#
# is the whole check over whatever is on disk, without taking the pictures
# again.
check_shots()
{
	local bad=0 f mean sd
	local files=""
	if [ -n "${shot_names:-}" ]; then
		for f in $shot_names; do files="$files $out/$f.png"; done
	else
		files="$out"/*.png
	fi
	for f in $files; do
		[ -f "$f" ] || continue
		read -r mean sd < <(magick "$f" -gravity center \
				-crop 200x200+0+0 +repage -colorspace Gray \
				-format "%[fx:mean] %[fx:standard_deviation]" info:)
		if awk "BEGIN{exit !($sd < 0.01)}"; then
			echo "FLAT SKY  $(basename "$f")  sd=$sd" >&2
			bad=$((bad + 1))
		elif awk "BEGIN{exit !($mean > 0.75 && $mean < 0.86 && $sd < 0.10)}"
		then
			echo "YOU DIED  $(basename "$f")  mean=$mean" >&2
			bad=$((bad + 1))
		fi
	done
	# And against the reference set for this mode, which is the test that
	# catches what the two above cannot: a picture that is dark but not flat,
	# where the sky arrived and the terrain did not. The same state in the
	# reference is the same world at the same hour, so a frame three times
	# brighter or darker than it is not a rendering difference.
	local ref=""
	case "$out" in
	*_unlit) ref="$(dirname "$out")/official_noshadow" ;;
	*official*) ref="" ;;
	*) ref="$(dirname "$out")/official" ;;
	esac
	if [ -n "$ref" ] && [ -d "$ref" ]; then
		for f in $files; do
			[ -f "$f" ] || continue
			local r="$ref/$(basename "$f")"
			[ -f "$r" ] || continue
			read -r a b < <(magick "$f" -colorspace Gray \
					-format "%[fx:mean] " info: && magick "$r" \
					-colorspace Gray -format "%[fx:mean]" info:)
			if awk "BEGIN{exit !($a > $b * 3 || $a < $b / 3)}"; then
				echo "OFF BY A LOT  $(basename "$f")  $a against the" \
						"reference's $b" >&2
				bad=$((bad + 1))
			fi
		done
	fi
	if [ -n "${shot_names:-}" ]; then
		echo "$(echo "$shot_names" | wc -w) pictures checked in $out, $bad suspect"
	else
		echo "$(ls "$out" | wc -l) pictures in $out, $bad suspect"
	fi
	[ "$bad" -eq 0 ]
}

case "$fixture" in
check)
	check_shots; exit $? ;;
shoot)
	log="$2"; cli="$3"; out="${4:-$out}"
	mkdir -p "$out"; shoot_states; check_shots; exit $? ;;
reference)
	meta="$me/reference_world_map_meta.txt"
	;;
snow)
	echo "the snow viewpoint is viewpoint 5 of the reference world now;" >&2
	echo "run: $0 reference" >&2
	exit 2
	;;
*)
	echo "unknown fixture: $fixture" >&2; exit 2 ;;
esac

# The fixture is the whole parameter file, not a seed and a few keys. The
# mgvalleys_* scalars in it decide where snow sits, and a world generated
# without them is not a nearby world, it is an unrelated one -- which is what
# the sixteen superseded pictures were of. So the seed is read out of the file
# rather than written twice.
seed=$(sed -n 's/^seed = //p' "$meta")
[ -n "$seed" ] || { echo "no seed in $meta" >&2; exit 2; }

# And a seed reproduces a world only under the game that made it: five minor
# versions of biome changes put a flower meadow where the reference has snow.
# Checked rather than trusted, because generating a different world silently is
# the worst failure available here -- the pictures look fine.
want_vl=$(sed -n 's/^vl_world_initial_version = //p' "$meta")
have_vl=$(sed -n 's/^version *= *//p' "$luanti/games/mineclone2/game.conf")
if [ -n "$want_vl" ] && [ "$want_vl" != "$have_vl" ]; then
	echo "the fixture was generated by VoxeLibre $want_vl, the game here is" >&2
	echo "$have_vl: the set has to be re-taken rather than patched." >&2
	exit 2
fi

[ -f "$conf" ] || { echo "no config at $conf" >&2; exit 2; }

# The non-PBR set, which is the same twenty with Luanti's dynamic shadows off
# -- [NON_PBR]'s half of this session. A copy of the config with one line
# added rather than a second config file: two files that must agree about
# fifteen settings and differ about one drift apart, and the last value of a
# key is the one Luanti keeps. Shaders themselves have no switch left to
# throw; 5.18 dropped enable_shaders.
if [ -n "${NO_SHADOWS:-}" ]; then
	out="${OUT_DIR:-$here/local/reference_shots/official_noshadow}"
	base="$conf"
	conf=$(mktemp /tmp/refshots_noshadow.XXXXXX.conf)
	{ cat "$base"; echo "enable_dynamic_shadows = false"; } > "$conf"
fi

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
	# Copied in whole, every line of it. Deleting map.sqlite from a cache
	# and letting it regenerate gives the same world back; that is the check
	# to repeat whenever the fixture is touched.
	cp "$meta" "$work/map_meta.txt"
else
	echo "reusing cached world $work"
fi

mkdir -p "$out" "$work/worldmods/refviews"
# PROBE=1 shoots only the two states the probe script reads -- fifteen seconds
# against two minutes, which is what a tuning cycle wants. The prelude goes in
# front of the fixture rather than into a setting because the three clients
# that run it have three ways of being configured and none of a file. See
# [PROBE_CYCLE] in doc/plan/rendering_plan.md.
if [ -n "${PROBE:-}" ]; then
	echo 'rawset(_G, "REFSHOT_PROBE", true)' \
			> "$work/worldmods/refviews/init.lua"
	cat "$me/reference_views.lua" >> "$work/worldmods/refviews/init.lua"
else
	cp "$me/reference_views.lua" "$work/worldmods/refviews/init.lua"
fi
printf 'name = refviews\n' > "$work/worldmods/refviews/mod.conf"

log=$(mktemp /tmp/refshots_srv.XXXXXX.log)
# A port the client's own sandbox has already been told about. The extension
# goes through extensions/network, which asks the user before a script opens a
# socket and remembers the answer for a week; a fresh random port every run
# would put that dialog in front of every run, and the harness is not the
# thing to answer it. 30030 is one the user has accepted for a local Luanti
# server. When the week runs out the dialog comes back and wants one click.
if [ "${CLIENT:-luanti}" = "extension" ]; then
	port=${PORT:-30030}
else
	port=${PORT:-$(( 31000 + (RANDOM % 200) ))}
fi
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

# Which client is in front of the server. The extension is a Luanti client of
# its own -- it speaks the protocol to an unmodified server -- so it takes its
# half of the set through this same server and this same worldmod, which is
# what makes the three sets comparable. See "The other two clients shoot the
# same set" in doc/plan/rendering_plan.md. The module's half is the odd one
# out and has a script of its own, because it runs the game itself.
if [ "${CLIENT:-luanti}" = "extension" ]; then
	out="${OUT_DIR:-$here/local/reference_shots/extension_${MODE:-unlit}}"
	mkdir -p "$out"
	# Three passes rather than two: this client fetches the server's media and
	# meshes the world as it goes, so the second is still catching up
	CYCLES="${CYCLES:-3}"
	# Nothing to click: BUILDAT_LUANTI_CONNECT skips the extension's connect
	# dialog, whose focus sits in a LineEdit that swallows Return. The command
	# file only has to keep the client alive -- the shooter below decides when
	# the run is over.
	cmds=$(mktemp /tmp/refshots_ext.XXXXXX.txt)
	{ echo "delay 1800000"; echo "quit"; } > "$cmds"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ref \
		BUILDAT_LUANTI_CONNECT=1 BUILDAT_LUANTI_PBR="${MODE:-unlit}" \
		"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
		-c @"$cmds" > /tmp/refshots_ext.log 2>&1 &
	cli=$!
else
	"$bin" --go --address 127.0.0.1 --port "$port" --name ref \
		--config "$conf" > /tmp/refshots_cli.log 2>&1 &
	cli=$!
fi

shoot_states

kill "$cli" 2>/dev/null
sleep 1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
kill -9 "$srv" 2>/dev/null
echo -n "done: "
check_shots
