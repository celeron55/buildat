#!/bin/bash
# [OFFICIAL_SHOTS]: this module's half of the reference shot set, against the
# same world and the same fixture official Luanti's half used. See
# doc/plan/rendering_plan.md.
#
#   builtin/luanti/test/reference_shots_module.sh [mode] [world]
#
# The mode is unlit, shadows or pbr and defaults to pbr, which is what the
# launcher draws when nothing asks otherwise. Each one has its own reference:
# unlit against official_noshadow/, shadows against official/, pbr against
# nothing but the sunlit anchor. See [RENDER_MODES] in
# doc/plan/rendering_plan.md.
#
# The world is the cache reference_shots.sh generated -- one engine makes the
# terrain and all three clients are pointed at it, so a difference between the
# sets is a difference in light and not in what was drawn. Run that script
# first if the cache is not there.
#
# sed -u, and it is not a detail: sed block-buffers when its output is a file,
# so the fixture's REFSHOT lines arrive in the log in chunks and the shooter
# names each picture after a state the world left several states ago. It is
# the one failure that produces a good picture of the wrong thing.
#
# The shooting half is reference_shots.sh's, called rather than copied: the
# window is found by the client's own pid, the states are counted out of the
# fixture's log and each shot is taken late in its hold.
#
# What the client is driven by is a command file that does nothing but wait,
# because the fixture's clock starts when the player joins and this client's
# starts when it launches -- and between the two is a mineclone2 world's
# loading, which is a minute and a half on this machine and is not a constant.
set -u

here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
seed=$(sed -n 's/^seed = //p' "$me/reference_world_map_meta.txt")
# PROBE=1 shoots only the two states the probe script reads, which is about
# fifteen seconds against two minutes and is what a tuning cycle wants. The
# warm-up cycles stay: what they prevent does not stop being possible because
# the run is short. See [PROBE_CYCLE] in doc/plan/rendering_plan.md.
fixture="$me/reference_views.lua"
if [ -n "${PROBE:-}" ]; then
	fixture=$(mktemp /tmp/refviews_probe.XXXXXX.lua)
	{ echo 'rawset(_G, "REFSHOT_PROBE", true)'; cat "$me/reference_views.lua"; \
			} > "$fixture"
fi
# HOLD=<seconds> for the calibration ladder: halve it until the run stops
# producing good results and then operate at four times what broke. See
# "Calibrate the timings rather than guessing them" in
# doc/plan/rendering_plan.md.
if [ -n "${HOLD:-}" ]; then
	prev="$fixture"
	fixture=$(mktemp /tmp/refviews_hold.XXXXXX.lua)
	{ echo "rawset(_G, \"REFSHOT_HOLD\", $HOLD)"; cat "$prev"; } > "$fixture"
fi

mode="${1:-pbr}"
case "$mode" in
unlit|shadows|pbr) ;;
*) echo "unknown mode: $mode (wanted unlit, shadows or pbr)" >&2; exit 2 ;;
esac
world="${2:-$here/local/reference_worlds/$seed}"
out="${OUT_DIR:-$here/local/reference_shots/module_$mode}"
save=buildat_test_refviews
tmp=$(mktemp -d)

[ -d "$world" ] || { echo "no cached world at $world" >&2
	echo "run: $me/reference_shots.sh reference" >&2; exit 2; }

cd "$here/Build"
# Another session on this machine may be running a server of its own, and two
# of them fight over the save directory's sqlite: a run that starts into one
# dies with "database is locked" before the fixture's first state. Waited for
# rather than raced, the way the sweep's own runner does.
for i in $(seq 1 600); do
	pgrep -x buildat_server >/dev/null || break
	sleep 2
done
rm -rf "../user/games/luanti_launcher/saves/$save"
port=$(( 29600 + (RANDOM % 90) ))
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_IMPORT="$world" BUILDAT_LUANTI_PBR="$mode" \
	BUILDAT_VOXELWORLD_KEEP_LOADED=1 \
	BUILDAT_LUANTI_LUA="$fixture" \
	bin/buildat_server -m ../games/luanti_launcher -D ../user -P "$port" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$tmp/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$tmp/srv.log" 2>/dev/null && break
	grep -q "Shutdown:" "$tmp/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 10
srv=$(pgrep -x buildat_server | head -1)
[ -z "$srv" ] && { echo "the server did not come up" >&2
	tail -3 "$tmp/srv.log" >&2; exit 1; }

# 1280x720, which is reference_shots.conf's screen_w and screen_h: a ratio
# between pictures of different sizes is a ratio about the size. The viewing
# range and the fog are the fixture's doing, not this file's -- see pin_view()
# in reference_views.lua.
# F5 is the launcher's status row -- the position, the yaw and the pitch --
# which a comparison shot is required to carry, the same way official Luanti's
# half carries show_debug. It is off by default, and the delay before it is
# for the client to have a world to draw it over.
# An hour, not half of one: the shooter decides when the run is over and this
# is only the client's outside lifetime. Half an hour used to be plenty and
# stopped being so once the fixture waited for its viewpoints to load -- the
# client quit mid-run with eleven states still to shoot.
{ echo "delay 45000"; echo "keypress F5"
	echo "delay 3600000"; echo "quit"; } > "$tmp/cmds.txt"
bin/buildat -s "localhost:$port" -w 1280x720 -l 3 -c @"$tmp/cmds.txt" \
	> "$tmp/cli.log" 2>&1 &
cli=$!

# Three cycles rather than the default two: this client imported the world
# rather than being handed a cached one, and it is still meshing it through
# the second pass -- a picture of viewpoint 1 with nineteen thousand blocks
# left to mesh is a picture of fog.
#
# **A probe cycle is only sound against a client that is already warm.** Two
# states go round in seconds where twenty take two minutes, and this client
# meshes an imported world for longer than either: eleven thousand blocks were
# still queued when a three-cycle probe run took its last picture, and eight
# cycles and then five minutes of waiting for the mesh queue to go quiet both
# ended the same way. The numbers such a run produces look like a rendering
# bug rather than an empty world. **What makes PROBE=1 worth its name is
# [PROBE_CYCLE]'s other half** -- one server and one client kept up across
# iterations -- and until that exists, a full twenty-state run is the one to
# believe.
CYCLES=${CYCLES:-3} \
	SHOT_AT=$(awk -v h="${HOLD:-6}" 'BEGIN{printf "%.2f", h * 2 / 3}') \
	"$me/reference_shots.sh" shoot "$tmp/srv.log" "$cli" "$out"
status=$?
# A run that shot nothing did not happen: two sessions on one machine fight
# over the save's sqlite and the loser dies before the fixture's first state,
# which the wait above can only narrow and not close. Retried rather than
# reported, a probe cycle being a minute.
if [ "$status" -ne 0 ] && [ "${REFSHOT_TRY:-1}" -lt 3 ]; then
	echo "nothing was shot; trying again" >&2
	kill "$cli" 2>/dev/null; sleep 2
	kill -INT "$srv" 2>/dev/null
	for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
	kill -9 "$srv" 2>/dev/null
	sleep 20
	# By its own absolute path: this has cd'd into Build by now, and a
	# relative $0 does not survive that -- the exec failed silently and the
	# retry never happened
	REFSHOT_TRY=$(( ${REFSHOT_TRY:-1} + 1 )) exec "$me/$(basename "$0")" "$@"
fi

kill "$cli" 2>/dev/null
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 120); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
kill -9 "$srv" 2>/dev/null
echo "logs in $tmp"
exit $status
