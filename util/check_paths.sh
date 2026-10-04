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
# vim: set noet ts=4 sw=4:
