# SPDX-License-Identifier: Apache-2.0 OR MIT
# Sourced by every check and drive: a user and a cache path of the checks'
# own, so that the desk's playtesting and a check never share saves,
# settings, a local server's pid file or module builds (user, 2026-10-04).
# The binaries take BUILDAT_USER_PATH and BUILDAT_CACHE_PATH as their
# defaults (src/boot/autodetect.cpp); a -D or -C given still wins.
#
#   . "$(dirname "$0")/../util/check_paths.sh"
_check_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export BUILDAT_USER_PATH="$_check_root/local/check/user"
export BUILDAT_CACHE_PATH="$_check_root/local/check/cache"
mkdir -p "$BUILDAT_USER_PATH/shared/vanilla" "$BUILDAT_CACHE_PATH"
# The Luanti games and textures the checks play, from the desk's user path:
# hard links, so nothing is copied and a boxed server (Landlock is by path)
# can read them, which it could not through a symlink out of its user path.
# The checks only read them; a write into a linked file would reach the desk.
# simplified: linked once; a game the desk updates later is not seen until
# local/check/user/shared/vanilla/<dir> is removed and linked again
for _d in games texture_packs textures; do
	[ -d "$_check_root/user/shared/vanilla/$_d" ] &&
		[ ! -e "$BUILDAT_USER_PATH/shared/vanilla/$_d" ] &&
		cp -al "$_check_root/user/shared/vanilla/$_d" \
			"$BUILDAT_USER_PATH/shared/vanilla/$_d"
done
unset _d

# An address a scripted client may connect to without the network
# permission dialog, which a command file cannot answer: an accepted entry
# in the checks' own store, fresh for the week it is valid.
#   check_allow udp://127.0.0.1:30030
check_allow()
{
	local now; now=$(date +%s)
	mkdir -p "$BUILDAT_USER_PATH"
	printf '"true","%s","","%s","%s","","",""\n' "$1" "$now" "$now" \
		>> "$BUILDAT_USER_PATH/network_addresses.csv"
}

# **The checks' own processes, never the desk's.** A check's client and
# server -- and a server its client starts -- carry BUILDAT_USER_PATH in
# their environment from here; a playtest's do not. So "is a server up",
# "which pid is the server" and "stop the server" ask about these alone,
# and a check neither waits on, nor reads, nor kills the user's game. A
# scripted client's window is told apart by its WM_CLASS
# (doc/client_commands.txt), so a playtest is no reason to skip a check.
#
#   check_pgrep buildat_server         the pids, one a line; 1 if none
#   check_pkill [-SIG] buildat_server
check_pgrep()
{
	local p found=1
	for p in $(pgrep -x "$1"); do
		grep -qzxF "BUILDAT_USER_PATH=$BUILDAT_USER_PATH" \
				"/proc/$p/environ" 2>/dev/null || continue
		echo "$p"
		found=0
	done
	return $found
}

check_pkill()
{
	local sig=-TERM pids
	[ "${1#-}" != "$1" ] && { sig=$1; shift; }
	pids=$(check_pgrep "$1") || return 1
	kill "$sig" $pids
}
# For a python body's subprocess: bash -c "check_pgrep buildat_server"
export -f check_pgrep check_pkill

# **A check's server, started and waited for** ([CHECK_START_SERVER]):
#
#   start_server <log> <ready-regex> <timeout_s> <port|auto> <command...>
#
# runs the command with "-P <port>" added, its output ANSI-stripped into
# <log>, and waits until <log> matches <ready-regex> (grep -E). Sets
# SERVER_PID (the server itself, not a pipe's end) and SERVER_PORT.
# **The port is checked first**: one already listened on (a desk server
# on 29500, another check) fails at once, naming it -- before, the check
# waited out its timeout as "did not come up", or talked to the other
# server. "auto" picks a free one in 29700-29999. A server that exits
# while waited for fails at once too. Returns 1 when the server did not
# come up, 2 when the port is taken, with the reason (and the log's tail)
# on stderr; the caller says FAIL. A check with a verdict of its own on a
# server that did not come up (a SKIP) keeps it, and still fails on a
# taken port:
#   start_server ... || [ $? = 1 ] || exit 1
#   VAR=x start_server ...  sets VAR for the server, as for any command
port_taken()
{
	ss -Hltnu "( sport = :$1 )" 2>/dev/null | grep -q .
}
start_server()
{
	local log=$1 ready=$2 timeout=$3 port=$4 _i
	shift 4
	if [ "$port" = auto ]; then
		for _i in $(seq 50); do
			port=$((29700 + RANDOM % 300))
			port_taken $port || break
		done
	fi
	if port_taken $port; then
		echo "start_server: port $port is taken: $(ss -Hltnup "( sport = :$port )" 2>/dev/null | head -1)" >&2
		return 2
	fi
	SERVER_PORT=$port
	"$@" -P "$port" > "$log" 2>&1 &
	SERVER_PID=$!
	for _i in $(seq "$timeout"); do
		grep -qaE "$ready" "$log" 2>/dev/null && return 0
		if ! kill -0 $SERVER_PID 2>/dev/null; then
			echo "start_server: the server exited before \"$ready\" ($log):" >&2
			tail -15 "$log" >&2
			return 1
		fi
		sleep 1
	done
	grep -qaE "$ready" "$log" 2>/dev/null && return 0
	echo "start_server: no \"$ready\" in $timeout s ($log):" >&2
	tail -15 "$log" >&2
	return 1
}
# vim: set noet ts=4 sw=4:
