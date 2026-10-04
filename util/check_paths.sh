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
# vim: set noet ts=4 sw=4:
