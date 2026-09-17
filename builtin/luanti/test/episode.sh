#!/bin/bash
# [AUTO_PLAYTEST] part 2: a compared episode. episode.lua builds one state
# on official Luanti's server and on this module, the client does one
# scripted thing, and the census the fixture logs is diffed between the
# two. The Luanti server's client is extensions/luanti_client, which is a
# scripted Luanti client; the module's is the launcher.
#
#   EPISODE=dig GAME=mineclone2 builtin/luanti/test/episode.sh
#
# What lands under local/episode/<episode>/: both servers' logs, both
# clients' logs, and the two census lines. Needs the Luanti checkout and
# its server binary the way reference_shots/shoot_luanti_server.sh does,
# and nothing else running.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
EPISODE="${EPISODE:-dig}"
GAME="${GAME:-mineclone2}"
# The client has no way to hear that the state is ready, so the timing is
# by delays: the client acts 40 seconds after launch, and the census is
# taken 50 seconds after the state, which is later than that on every
# machine this has run on. A client that missed its window shows as a
# census with nothing done on both sides -- the same, and wrong.
SECONDS_GIVEN="${SECONDS_GIVEN:-50}"
out="$here/local/episode/$EPISODE"
mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}

# The client's part: what the episode is. Every command file starts by
# waiting for the fixture's state, which is three seconds after the join
# plus a world's loading.
case "$EPISODE" in
dig)
	# Straight down for three seconds: the dirt underfoot, by hand
	{ echo "delay 40000"; echo "look 0 -89"; echo "mouse_down left"
		echo "delay 3000"; echo "mouse_up left"; echo "delay 600000"
		echo "quit"; } > "$out/cmds.txt" ;;
place)
	# The hotbar's first slot is empty, so a place does nothing; what is
	# asserted is that nothing happened on either side
	{ echo "delay 40000"; echo "look 0 -89"; echo "mouse_click right"
		echo "delay 600000"; echo "quit"; } > "$out/cmds.txt" ;;
*) echo "unknown episode $EPISODE (dig, place)" >&2; exit 2 ;;
esac

{ echo "rawset(_G, \"EPISODE_NAME\", \"$EPISODE\")"
	echo "rawset(_G, \"EPISODE_SECONDS\", $SECONDS_GIVEN)"
	cat "$me/episode.lua"; } > "$out/fixture.lua"

if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null ||
		pgrep -x luanti-refshots >/dev/null; then
	echo "a server or client is already running" >&2; exit 2
fi
srv=""; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT

wait_census() {   # log -> the census line, or nothing
	local i
	for i in $(seq 1 150); do
		grep -aq "episode: census" "$1" && break
		kill -0 "$cli" 2>/dev/null || break
		sleep 2
	done
	grep -a "episode: census" "$1" | sed 's/^.*episode: census //' | head -1
}

# --- the Luanti server, with the extension in front of it
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/episode"
cat > "$work/world.mt" <<EOF
gameid = $GAME
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = episode
creative_mode = false
enable_damage = false
server_announce = false
EOF
cp "$out/fixture.lua" "$work/worldmods/episode/init.lua"
printf 'name = episode\n' > "$work/worldmods/episode/mod.conf"
{ echo "fixed_map_seed = 1"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
for i in $(seq 1 300); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	sleep 1
done
sleep 3
srv=$(pgrep -x luanti-refshots | head -1)
[ -n "$srv" ] || { echo "the Luanti server did not come up" >&2; exit 1; }
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ep \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1 &
cli=$!
luanti_census=$(wait_census "$out/luanti_srv.log")
kill "$cli" 2>/dev/null; sleep 1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
kill -9 "$srv" 2>/dev/null

# --- the module, with the launcher in front of it
cd "$here/Build"
save=buildat_test_episode
rm -rf "../user/games/luanti_launcher/saves/$save"
port=$(( 29900 + (RANDOM % 90) ))
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -m ../games/luanti_launcher -D ../user -P "$port" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/module_srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/module_srv.log" 2>/dev/null && break
	grep -q "Shutdown:" "$out/module_srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the module's server did not come up" >&2; exit 1; }
bin/buildat -s "localhost:$port" -w 1280x720 -l 3 -c @"$out/cmds.txt" \
	> "$out/module_cli.log" 2>&1 &
cli=$!
module_census=$(wait_census "$out/module_srv.log")
kill "$cli" 2>/dev/null; sleep 1
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done

echo "luanti: ${luanti_census:-no census}"
echo "module: ${module_census:-no census}"
printf '%s\n%s\n' "$luanti_census" "$module_census" > "$out/census.txt"
if [ -z "$luanti_census" ] || [ -z "$module_census" ]; then
	echo "FAIL: a side gave no census" >&2; exit 1
fi
if [ "$luanti_census" != "$module_census" ]; then
	echo "FAIL: the censuses differ" >&2; exit 1
fi
echo "same"
