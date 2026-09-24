#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [NEW_WORLD_FORM]: the new-world screen. A name that is already taken
# leaves the screen standing with the name, the seed and the toggles as
# they were, the seed is copied out of its field and pasted into the name
# with Ctrl+C and Ctrl+V, and the mapgen picked on the screen is the one
# written into the new world's world.mt. Needs VoxeLibre installed under
# user/luanti/games, which drive.sh's menu runs want too.
#
#   builtin/luanti/test/new_world.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/new_world"; mkdir -p "$out"
saves="$here/user/games/vanilla/saves"
if pgrep -x buildat >/dev/null || pgrep -x buildat_server >/dev/null; then
	echo "a client or a server is already running" >&2; exit 2
fi
# The name the screen is refused: a directory under the saves is enough,
# because storage refuses a name whose path is there
rm -rf "$saves/mgtest" "$saves/taken"
# storage tells a save by its save.sqlite, so an empty file is what makes
# the name taken
mkdir -p "$saves/taken"; : > "$saves/taken/save.sqlite"
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
( cd "$here/Build" && bin/buildat -w 1280x720 -l 3 -c - < "$fifo" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log" ) &
cli=$!
trap 'kill "$cli" 2>/dev/null; pkill -x buildat_server 2>/dev/null' EXIT
exec 3> "$fifo"
python3 "$me/new_world.py" "$out/cli.log" "$fifo" "$saves"
status=$?
exec 3>&-
sleep 2
pkill -x buildat 2>/dev/null
pkill -x buildat_server 2>/dev/null
for i in $(seq 1 30); do pgrep -x buildat_server >/dev/null || break; sleep 1; done
# What this run made goes with it
rm -rf "$saves/taken" "$saves/mgtest"
exit $status
