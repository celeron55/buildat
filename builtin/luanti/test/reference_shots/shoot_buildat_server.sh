#!/bin/bash
# [OFFICIAL_SHOTS]: the reference shot set's buildat-server half -- the
# module running the game inside buildat_server, with the launcher in front
# of it -- against the same world and the same fixture the Luanti-server
# half used. See doc/plan/rendering_plan.md, [REFVIEWS_MOD].
#
#   builtin/luanti/test/reference_shots/shoot_buildat_server.sh [mode ...]
#
# The mode is unlit, shadows, pbr or pbr_debug_shadows (the shadow-kind
# diagnostic, [PBR_FIT] 2c) and defaults to pbr, which is what the
# launcher draws when nothing asks otherwise. Each one has its own reference:
# unlit against official_unlit, shadows against official_shadows, pbr
# against the path-traced set. See [RENDER_MODES] in
# doc/plan/rendering_plan.md. **Several modes share one server**: the mode
# is the client's to ask for (BUILDAT_LUANTI_PBR on the client's process),
# so `unlit shadows pbr` boots VoxeLibre once and runs three clients against
# it, which is the ten-minute round of [PROBE_CYCLE] rather than the
# thirty-minute one. The sets land in $REFSHOT_SHOTS_DIR/module_<mode>_r<RANGE>.
#
# The world is the cache shoot_luanti_server.sh generated -- one engine makes
# the terrain and all three clients are pointed at it, so a difference
# between the sets is a difference in light and not in what was drawn. Run
# that script first if the cache is not there.
#
# sed -u, and it is not a detail: sed block-buffers when its output is a file,
# so the fixture's REFSHOT lines arrive in the log in chunks and the shooter
# names each picture after a state the world left several states ago. It is
# the one failure that produces a good picture of the wrong thing.
#
# What the client is driven by is a command file that does nothing but wait,
# because the fixture's clock starts when the player joins and this client's
# starts when it launches -- and between the two is a mineclone2 world's
# loading, which is a minute and a half on this machine and is not a constant.
set -u

# The repository root, from builtin/luanti/test/reference_shots/
here=$(cd "$(dirname "$0")/../../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
# Every copy of every fact comes out of build.sh; see [REFVIEWS_MOD]. What
# a run passes: PROBE=1 shoots only the states probes.sh reads, which is
# fifteen seconds against two minutes and what a tuning cycle wants;
# PATHTRACE=1 one dump per viewpoint for [PATH_TRACE_REF]; HOLD=<seconds>
# the calibration ladder's; RANGE=<nodes> the viewing range, 50 being what
# a path-trace dump wants while the camera is still being diagnosed. Every
# set directory carries the range as _r<RANGE>. KEEP: the server stays up
# between the clients.
# No sparkle in a reference set (user, 2026-09-18): the path-traced
# reference does not render the spots, so both clients leave them off
# under this variable and the comparison is of what both can draw
export BUILDAT_LUANTI_NO_SPOTS=1
# And no tonemap curve on pbr: the render's PNG is the metered frame
# clipped, and the probes compare linear to linear until the fit's last
# term ([PBR_FIT]) has a curve to compare. The parity modes have none.
# BUILDAT_LUANTI_LINEAR=0 on the command line shoots the graded frame
# instead (curve and bloom on), which is what a grade check looks at
# ([BLOOM_PLACE]); such a set goes under REFSHOT_SHOTS_DIR, not the fit's.
export BUILDAT_LUANTI_LINEAR="${BUILDAT_LUANTI_LINEAR:-1}"
built=$(mktemp -d /tmp/refshots_build.XXXXXX)
KEEP=1 "$me/build.sh" "$built" || exit 2
. "$built/env.sh"
RANGE=$REFSHOT_RANGE
fixture="$built/fixture.lua"
shots_root="${REFSHOT_SHOTS_DIR:-$here/local/reference_shots}"
worlds_root="${REFSHOT_WORLDS_DIR:-$here/local/reference_worlds}"

modes=""
world="$worlds_root/$REFSHOT_SEED"
for arg in "$@"; do
	case "$arg" in
	unlit|shadows|pbr|pbr_debug_shadows) modes="$modes $arg" ;;
	*) echo "unknown mode: $arg (wanted unlit, shadows, pbr or pbr_debug_shadows)" >&2; exit 2 ;;
	esac
done
modes="${modes:- pbr}"
# The server's own mode is the first one asked for; every client asks for
# its own, so this only matters for a client that says nothing
first_mode=${modes# }
first_mode=${first_mode%% *}
save=buildat_test_refviews
tmp=$(mktemp -d)

[ -d "$world" ] || { echo "no cached world at $world" >&2
	echo "run: $me/shoot_luanti_server.sh reference" >&2; exit 2; }

cd "$here/Build"
# Whatever way this script ends, the server and the client go with it: a
# server that outlives its script sits beside the next thing that runs.
srv=""; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
# A leftover server from a picker or a killed run still holds the save
# sqlite. A random port does not help: two of them fight over the same
# database. Kill ours rather than wait twenty minutes for someone else's.
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "killing leftover buildat" >&2
	killall -TERM buildat_server buildat 2>/dev/null || true
	sleep 1
	killall -KILL buildat_server buildat 2>/dev/null || true
	sleep 1
fi
rm -rf "../user/games/vanilla/saves/$save"
port=$(( 29600 + (RANDOM % 90) ))
# **The orbit's tilt is the set's for pbr and zero for the parity modes.**
# This client tilts the sun and the moon when the game has no opinion,
# because an axis-aligned sun is a poor light. Official Luanti does not, so
# a parity set takes zero or its sun is twenty degrees from where official
# draws it; the render places its sun by set.lua's tilt, so the pbr set
# takes the same number ([PBR_FIT] 2c). One server serves every client in
# a run and the tilt is the server's, so a run that mixes pbr with a parity
# mode takes zero and says so. Overridable for a run that wants the other
# thing.
case " $modes " in
*" pbr "*|*" pbr_debug_shadows "*)
	case " $modes " in
	*" unlit "*|*" shadows "*) tilt=0
		echo "pbr shot with the parity modes: orbit tilt 0, not $REFSHOT_ORBIT_TILT" >&2 ;;
	*) tilt=$REFSHOT_ORBIT_TILT ;;
	esac ;;
*) tilt=0 ;;
esac
BUILDAT_LUANTI_ORBIT_TILT="${BUILDAT_LUANTI_ORBIT_TILT:-$tilt}" \
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_IMPORT="$world" BUILDAT_LUANTI_PBR="$first_mode" \
	BUILDAT_VOXELWORLD_KEEP_LOADED=1 \
	BUILDAT_LUANTI_LUA="$fixture" \
	bin/buildat_server -m ../games/vanilla -D ../user -P "$port" 2>&1 \
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

# The frame is set.lua's, the same one official Luanti's conf gets: a ratio
# between pictures of different sizes is a ratio about the size. The viewing
# range and the fog are the fixture's doing, not this file's -- see
# pin_view() in runner.lua.
# The launcher's status row -- the position, the yaw and the pitch -- which a
# comparison shot is required to carry, the same way official Luanti's half
# carries show_debug, is on by default ([STATUS_DEFAULT]); nothing is pressed.
# An hour, not half of one: the shooter decides when the run is over and this
# is only the client's outside lifetime. Half an hour used to be plenty and
# stopped being so once the fixture waited for its viewpoints to load -- the
# client quit mid-run with eleven states still to shoot.
{ echo "delay 3600000"; echo "quit"; } > "$tmp/cmds.txt"

status=0
shots_dir="$here/user/screenshots"
# One client per mode against the one server. Each client's set is the
# part of the server log written while it ran: the fixture starts a set on
# every join, so the log is sliced from where this client came in.
for mode in $modes; do
out="$shots_root/module_${mode}_r$RANGE"
mkdir -p "$out"
# What this set was taken with, beside its pictures: a set taken under an
# experiment's environment -- a flipped tilt, an ablated term -- reads as
# the client's word otherwise, and one did ([PBR_FIT], 2026-09-18)
{
	echo "taken $(date '+%Y-%m-%d %H:%M')"
	echo "orbit_tilt ${BUILDAT_LUANTI_ORBIT_TILT:-$tilt}"
	env | grep '^BUILDAT_LUANTI_' | sort
} > "$out/taken.txt"
from=$(wc -l < "$tmp/srv.log")
BUILDAT_LUANTI_PBR="$mode" \
bin/buildat -s "localhost:$port" -w "${REFSHOT_W}x$REFSHOT_H" -l 3 -c @"$tmp/cmds.txt" \
	> "$tmp/cli_$mode.log" 2>&1 &
cli=$!
since() { tail -n +"$((from + 1))" "$tmp/srv.log"; }

# **The client takes its own pictures and the fixture says when the set is
# done** -- see [ONE_CYCLE] in doc/plan/rendering_plan.md. Nothing here waits
# on a clock, grabs a window or counts cycles: the server marks a state once
# the world around the viewpoint is loaded, the client answers once it has
# drawn it, and one pass is enough because there is no longer such a thing as
# a picture taken too early.
#
# What this script does is wait, and then put the pictures where the set
# lives. The client cannot name them -- buildat.take_screenshot() names by
# the date and the time on purpose -- so the fixture logs the pairing and
# this reads it.
for i in $(seq 1 1800); do
	since | grep -q "REFSHOT done\|REFSHOT failed" 2>/dev/null && break
	kill -0 "$cli" 2>/dev/null || break
	sleep 2
done
sleep 2
if ! since | grep -q "REFSHOT done" 2>/dev/null; then
	status=1
	echo "the $mode run did not finish:" >&2
	since | grep -a "REFSHOT failed" | tail -1 >&2
fi

mkdir -p "$out"
taken=0
missing=0
while read -r stem file; do
	[ -n "$stem" ] || continue
	if [ -f "$shots_dir/$file" ]; then
		cp "$shots_dir/$file" "$out/$stem.png"
		taken=$((taken + 1))
	else
		echo "missing $file for $stem" >&2
		missing=$((missing + 1))
	fi
done <<EOF
$(since | grep -a "REFSHOT shot " | sed 's/^.*REFSHOT shot //' | sort -u)
EOF
echo "$taken pictures into $out"
[ "$missing" -eq 0 ] || status=1

if [ -n "${PATHTRACE:-}" ]; then
	mesh_out="$shots_root/pathtrace_r$RANGE"
	mkdir -p "$mesh_out"
	dumps=$here/user/meshdumps
	mesh_n=0
	while read -r stem file; do
		[ -n "$stem" ] || continue
		if [ -f "$dumps/$file" ]; then
			# The client writes the dump gzipped
			mv "$dumps/$file" "$mesh_out/$stem.obj.gz"
			[ -f "$dumps/${file%.obj.gz}_atlas.json" ] &&
				mv "$dumps/${file%.obj.gz}_atlas.json" "$mesh_out/${stem}_atlas.json"
			echo "mesh $stem"
			mesh_n=$((mesh_n + 1))
		else
			echo "missing mesh $file for $stem" >&2
			status=1
		fi
	done <<EOF
$(since | grep -a "REFSHOT mesh " | sed 's/^.*REFSHOT mesh //' | sort -u)
EOF
	# The textures are one set for the session, named meshdump_texN*.png
	# by the client and shared by every dump's usemtl lines
	for tex in "$dumps"/meshdump_tex*.png; do
		[ -f "$tex" ] && mv "$tex" "$mesh_out/"
	done
	echo "$mesh_n meshes into $mesh_out"
fi

# The two cheap tests over what this run shot, which is what they were always
# for; see check_shots() in shoot_luanti_server.sh
if [ "$taken" -gt 0 ]; then
	"$me/shoot_luanti_server.sh" check "$out" || status=1
fi

kill "$cli" 2>/dev/null
sleep 2
done

kill -INT "$srv" 2>/dev/null
for i in $(seq 1 120); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
kill -9 "$srv" 2>/dev/null
echo "logs in $tmp"
exit $status
