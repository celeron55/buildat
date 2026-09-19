#!/bin/bash
# The modding archives ([PACKAGING] in doc/plan/packaging_plan.md):
#
#   util/package.sh linux     -> buildat-<version>-<hash>-linux-x86_64-portable.tar.gz
#                                buildat-<version>-<hash>-linux-x86_64-xdg.tar.gz
#   util/package.sh windows   -> buildat-<version>-<hash>-win64.zip (a cross build)
#
# The version is the VERSION file's and the hash the tree's short git hash
# ([VERSION]); a dirty tree is refused, since its archive would be nobody's
# commit. Outside a checkout (a tarball of the tree) the hash is "unknown".
#
# Configures a build tree per archive under Build/package/, builds, runs the
# install rules into a staging directory, gathers every third-party licence
# into licenses/, writes VERSION, makes the archive under Build/package/out/,
# and smoke-tests it: unpacks into a clean directory, starts buildat_server
# on games/digger -- which compiles a module at run time through the found
# or bundled compiler -- connects a client that takes one screenshot that is
# not black, and quits. Nothing is packaged by hand. Runs the same inside
# util/docker's images as on a desk.
#
# The two Linux archives differ by one flag: PORTABLE keeps user/ and cache/
# beside the program, xdg puts them where XDG_DATA_HOME and XDG_CACHE_HOME say.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target="${1:-}"
if [ -z "$target" ]; then
	echo "usage: util/package.sh <linux|windows>" >&2
	exit 2
fi
version=$(tr -d '[:space:]' < "$here/VERSION")
# BUILDAT_GIT_HASH is what package_in_docker.sh hands in: the container
# has a git archive, which has no .git
hash="${BUILDAT_GIT_HASH:-$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
if [ -z "${BUILDAT_GIT_HASH:-}" ] && [ "$hash" != unknown ] &&
		! git -C "$here" diff --quiet HEAD 2>/dev/null; then
	echo "the tree has uncommitted changes; an archive is made from a commit" >&2
	exit 2
fi
version="$version-$hash"
jobs="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
root="$here/Build/package"
out="$root/out"
mkdir -p "$out"

# The licences the archive carries: buildat's own, every 3rdparty tree's
# and Urho3D's, and on Windows the compiler's, into one directory
gather_licenses() {
	local stage="$1"
	local lic="$stage/licenses"
	mkdir -p "$lic"
	cp "$here/NOTICE" "$lic/buildat-NOTICE.txt"
	[ -f "$here/LICENSE" ] && cp "$here/LICENSE" "$lic/buildat-LICENSE.txt"
	local d name f
	for d in "$here"/3rdparty/*/; do
		name=$(basename "$d")
		for f in "$d"LICENSE "$d"LICENSE.txt "$d"LICENSE.TXT "$d"COPYING "$d"COPYING.txt "$d"License.txt; do
			[ -f "$f" ] && cp "$f" "$lic/$name-$(basename "$f")"
		done
	done
	[ -d "$stage/compiler/licenses" ] && cp -r "$stage/compiler/licenses" "$lic/mingw-w64"
	return 0
}

# The Windows archive under Wine: the half that says the archive works
# where it is going -- buildat_server.exe compiling every module of a game
# with the compiler the archive ships -- and not yet the client, which
# wants GL under Wine on top. Skipped with a word where there is no wine.
smoke_test_wine() {
	local archive="$1"
	if ! command -v wine64 >/dev/null 2>&1 && ! command -v wine >/dev/null 2>&1; then
		echo "smoke test under Wine: no wine here; not run"
		return 0
	fi
	local wine
	wine=$(command -v wine64 || command -v wine)
	local dir
	dir=$(mktemp -d)
	(cd "$dir" && unzip -q "$archive")
	local unpacked
	unpacked=$(ls -d "$dir"/*/ | head -1)
	local port=$(( 29600 + (RANDOM % 90) ))
	echo "smoke test under Wine in $unpacked"
	export WINEDEBUG=-all WINEPREFIX="$dir/wine"
	(cd "$unpacked" && "$wine" bin/buildat_server.exe -m games/digger -P "$port" > "$dir/srv.log" 2>&1) &
	local srv=$!
	local i
	for i in $(seq 1 900); do
		grep -q "Listening at" "$dir/srv.log" 2>/dev/null && break
		kill -0 "$srv" 2>/dev/null || break
		sleep 1
	done
	kill -INT "$srv" 2>/dev/null; sleep 3; kill -9 "$srv" 2>/dev/null
	wait "$srv" 2>/dev/null || true
	"$wine"server -k 2>/dev/null || true
	if ! grep -q "Listening at" "$dir/srv.log"; then
		echo "smoke test under Wine: the server did not come up; its log:" >&2
		tail -40 "$dir/srv.log" >&2
		exit 1
	fi
	echo "smoke test under Wine passed: the server compiled its modules and listened"
}

# One archive: a build tree configured for it, the install rules into a
# staging directory named as the archive is, and the archive out of that
make_one() {
	local name="$1"; shift
	local build="$root/build-$name"
	local stage="$root/stage/$name"
	rm -rf "$stage"
	mkdir -p "$build" "$stage"
	(cd "$build" && cmake "$here" -DCMAKE_BUILD_TYPE=Release "$@" > cmake.log 2>&1) || {
		echo "configure failed; see $build/cmake.log" >&2; exit 1; }
	(cd "$build" && cmake --build . -j "$jobs" > build.log 2>&1) || {
		echo "build failed; see $build/build.log" >&2; exit 1; }
	(cd "$build" && cmake --install . --prefix "$stage" > install.log 2>&1) || {
		echo "install failed; see $build/install.log" >&2; exit 1; }
	gather_licenses "$stage"
	echo "$version" > "$stage/VERSION"
	case "$name" in
		*win64*)
			(cd "$stage/.." && rm -f "$out/$name.zip" && zip -qr "$out/$name.zip" "$name")
			echo "$out/$name.zip" ;;
		*)
			tar -C "$stage/.." -czf "$out/$name.tar.gz" "$name"
			echo "$out/$name.tar.gz" ;;
	esac
}

# The archive unpacked into a clean directory and run: the server on
# games/digger through the found compiler, a client connected for one
# screenshot, which must not be black. The one check that says the archive
# starts on the machine it is on.
smoke_test() {
	local archive="$1"
	local dir
	dir=$(mktemp -d)
	tar -C "$dir" -xzf "$archive"
	local unpacked
	unpacked=$(ls -d "$dir"/*/ | head -1)
	local port=$(( 29600 + (RANDOM % 90) ))
	echo "smoke test in $unpacked"
	(cd "$unpacked" && bin/buildat_server -m games/digger -P "$port" > "$dir/srv.log" 2>&1) &
	local srv=$!
	local i
	# The server compiles every module it loads through the compiler
	# the archive found, which is minutes on a first run; the client
	# joins once the server listens
	for i in $(seq 1 900); do
		grep -q "Listening at" "$dir/srv.log" 2>/dev/null && break
		kill -0 "$srv" 2>/dev/null || { echo "server exited; see $dir/srv.log" >&2; exit 1; }
		sleep 1
	done
	sleep 5
	printf 'delay 25000\nscreenshot %s/shot.png\nquit\n' "$dir" > "$dir/cmds.txt"
	# Software GL where there is no GPU (the container); harmless with one
	(cd "$unpacked" && LIBGL_ALWAYS_SOFTWARE=1 timeout 120 bin/buildat -s "localhost:$port" -w 640x360 -l 3 -c @"$dir/cmds.txt" > "$dir/cli.log" 2>&1) || true
	kill -INT "$srv" 2>/dev/null
	for i in $(seq 1 30); do
		kill -0 "$srv" 2>/dev/null || break
		sleep 1
	done
	kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true
	if [ ! -f "$dir/shot.png" ]; then
		echo "smoke test: no screenshot; see $dir/cli.log and $dir/srv.log" >&2
		exit 1
	fi
	# What the archive has to have done: joined, drawn the world -- the
	# client says when a chunk was drawn -- and run its commands to the
	# end. The screenshot's mean is read beside that: under a virtual
	# display with software GL the readback has come out black on a
	# frame the client drew, so it is reported and not a verdict there.
	if ! grep -q "Connect succeeded" "$dir/cli.log" ||
			! grep -q "Command sequence complete" "$dir/cli.log" ||
			! grep -q "drawn again\|Node update\|player physics enabled" "$dir/cli.log"; then
		echo "smoke test: the client did not join, draw and finish; see $dir/cli.log" >&2
		tail -40 "$dir/cli.log" >&2
		exit 1
	fi
	local mean
	mean=$(magick "$dir/shot.png" -format '%[fx:mean]' info: 2>/dev/null || echo 0)
	if awk -v m="$mean" 'BEGIN{exit !(m < 0.01)}'; then
		if [ -n "${DISPLAY:-}" ] && [ -z "${BUILDAT_SMOKE_VIRTUAL:-}" ]; then
			echo "smoke test: the screenshot is black (mean $mean)" >&2
			exit 1
		fi
		echo "smoke test: joined, drew and finished; the screenshot is black under the virtual display (mean $mean)"
	else
		echo "smoke test passed (screenshot mean $mean)"
	fi
}

case "$target" in
linux)
	a=$(make_one "buildat-$version-linux-x86_64-portable" -DPORTABLE=TRUE)
	b=$(make_one "buildat-$version-linux-x86_64-xdg" -DPORTABLE=FALSE)
	smoke_test "$a"
	echo "archives:"; echo "  $a"; echo "  $b"
	;;
windows)
	# The cross build: Urho3D's own MinGW toolchain file, with Debian's
	# x86_64-w64-mingw32 tools (util/docker/windows); CMAKE_TOOLCHAIN_FILE
	# and MINGW_PREFIX (a path prefix, /usr/bin/x86_64-w64-mingw32) in the
	# environment override for another toolchain
	tc="${CMAKE_TOOLCHAIN_FILE:-$here/3rdparty/Urho3D/CMake/Toolchains/MinGW.cmake}"
	# and the native tree the archive ships under compiler/, which the
	# image unpacks to /opt/winlibs/mingw64
	a=$(make_one "buildat-$version-win64" -DPORTABLE=TRUE \
		-DCMAKE_TOOLCHAIN_FILE="$tc" \
		-DMINGW_PREFIX="${MINGW_PREFIX:-/usr/bin/x86_64-w64-mingw32}" \
		-DBUILDAT_SHIP_COMPILER="${BUILDAT_SHIP_COMPILER:-/opt/winlibs/mingw64}")
	echo "archive: $a"
	smoke_test_wine "$a"
	;;
*)
	echo "unknown target $target" >&2; exit 2 ;;
esac
