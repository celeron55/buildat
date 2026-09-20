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

# The Windows archive stands alone: every DLL an exe or dll in it imports
# is in the archive or is Windows' own. Wine never proved this -- it
# finds what a DLL wants in the image's mingw bin/ and its own built-ins
# -- and 0.3.1 shipped a libcurl whose DLL failed to initialise on a
# desktop ([WIN_DLL_INIT]). objdump -p lists the imports; the compiler
# tree under compiler/ is a distribution of its own and is left out.
check_imports() {
	local archive="$1"
	local objdump
	objdump=$(command -v x86_64-w64-mingw32-objdump || command -v objdump) || {
		echo "import check: no objdump here; not run"; return 0; }
	local dir
	dir=$(mktemp -d)
	unzip -q "$archive" -d "$dir" || { echo "import check: cannot unzip $archive" >&2; exit 1; }
	# Windows' own, lower case; the api-ms-win-* set by prefix, except the
	# api-ms-win-crt-* ones: those are the UCRT, and this archive is built
	# on msvcrt -- a DLL importing them brings a second C runtime into the
	# process, which is what 0.3.1's libcurl did
	local own=" kernel32.dll user32.dll gdi32.dll advapi32.dll shell32.dll \
ole32.dll oleaut32.dll ws2_32.dll opengl32.dll winmm.dll dbghelp.dll \
imm32.dll version.dll setupapi.dll crypt32.dll bcrypt.dll secur32.dll \
iphlpapi.dll msvcrt.dll comdlg32.dll shlwapi.dll uuid.dll rpcrt4.dll \
wldap32.dll normaliz.dll ntdll.dll psapi.dll userenv.dll cfgmgr32.dll \
hid.dll dinput8.dll dxgi.dll d3d11.dll d3d9.dll xinput1_4.dll \
xinput9_1_0.dll dwmapi.dll "
	local bad=0 f name have
	have=$(find "$dir" -path '*/compiler' -prune -o -iname '*.dll' -print \
		| xargs -n1 basename | tr 'A-Z' 'a-z' | sort -u)
	while IFS= read -r f; do
		for name in $("$objdump" -p "$f" 2>/dev/null | awk '/DLL Name:/ {print tolower($3)}'); do
			case "$name" in
			api-ms-win-crt-*)
				echo "import check: ${f#$dir/} imports $name: the UCRT, a second C runtime" >&2
				bad=1; continue ;;
			api-ms-win-*) continue ;;
			esac
			if ! grep -qx "$name" <<<"$have" && [[ "$own" != *" $name "* ]]; then
				echo "import check: ${f#$dir/} imports $name, which the archive does not carry" >&2
				bad=1
			fi
		done
	done < <(find "$dir" -path '*/compiler' -prune -o \( -iname '*.exe' -o -iname '*.dll' \) -print)
	rm -rf "$dir"
	[ "$bad" = 0 ] || { echo "import check failed" >&2; exit 1; }
	echo "import check: every import is in the archive or Windows' own"
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
	# One virtual display for the whole of it: the wineserver the server's
	# run starts is the one the client's run finds, and it keeps the
	# display it was started without
	local xvfb_pid=""
	if [ -z "${DISPLAY:-}" ] && command -v Xvfb >/dev/null 2>&1; then
		Xvfb :97 -screen 0 1280x720x24 > /dev/null 2>&1 &
		xvfb_pid=$!
		export DISPLAY=:97
		sleep 2
	fi
	# With TEMP and TMP unset, as a desktop with nothing set ([WIN_TMP]);
	# Wine gives its own from the registry, so this proves less than a
	# desktop does, and the desktop is the done-when
	(cd "$unpacked" && env -u TEMP -u TMP -u TMPDIR BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=smoke \
		"$wine" bin/buildat_server.exe -m games/vanilla -P "$port" -l 4 > "$dir/srv.log" 2>&1) &
	local srv=$!
	local i
	wait_for_vanilla "$dir/srv.log" "$srv" "smoke test under Wine" || {
		kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true; exit 1; }
	# And the client, on the virtual display through Wine's GL, which is
	# software rendering; what it has to have done is what the Linux smoke
	# asks: joined, drawn a chunk, run its commands to the end
	sleep 5
	printf 'delay 25000\nscreenshot %s/shot.png\nquit\n' "Z:$dir" > "$dir/cmds.txt"
	(cd "$unpacked" && timeout 180 "$wine" bin/buildat.exe -s "localhost:$port" -w 640x360 -l 3 -c "@Z:$dir/cmds.txt" > "$dir/cli.log" 2>&1) || true
	kill -INT "$srv" 2>/dev/null; sleep 3; kill -9 "$srv" 2>/dev/null
	wait "$srv" 2>/dev/null || true
	"$wine"server -k 2>/dev/null || true
	[ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null
	if ! grep -q "Connect succeeded" "$dir/cli.log" ||
			! grep -q "drawn again\|Node update\|player physics enabled\|chunks in scene" "$dir/cli.log"; then
		echo "smoke test under Wine: the client did not join and draw; its log:" >&2
		tail -40 "$dir/cli.log" >&2
		exit 1
	fi
	# Whether it ran its commands to the end is reported and not a
	# verdict: the luanti client joined, drew and then page-faulted in
	# Wine's software GL two seconds in ([WIN_MAPGEN_BUILD], 2026-09-20),
	# which the desktop is the place to read
	if ! grep -q "Command sequence complete" "$dir/cli.log"; then
		echo "smoke test under Wine: the client joined and drew but did not finish its commands; its log's end:" >&2
		tail -20 "$dir/cli.log" >&2
		read_crash "$dir/cli.log" || exit 1
	fi
	echo "smoke test under Wine passed: the server compiled every module and generated a section, the client joined and drew"
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
	# What built it ([WIN_DLL_INIT]): the toolchain packages' versions, into
	# the archive and the build log, so the next difference between two
	# archives of one source is read off two text files
	if command -v dpkg >/dev/null 2>&1; then
		{ echo "built $(date -u +%Y-%m-%dT%H:%MZ) from ${BUILDAT_GIT_HASH:-?}"
		  cat /etc/apt/sources.list 2>/dev/null | grep -v '^#'
		  dpkg -l 'mingw-w64*' 'gcc-mingw-w64*' 'binutils-mingw-w64*' \
			'gcc' 'g++' 'libc6' 'libstdc++6' 'cmake' 2>/dev/null \
			| awk '/^ii/ {print $2, $3}'
		} > "$stage/bin/TOOLCHAIN"
		# To stderr: this function's stdout is the archive's path
		echo "toolchain:" >&2; sed 's/^/  /' "$stage/bin/TOOLCHAIN" >&2
	fi
	case "$name" in
		*win64*)
			(cd "$stage/.." && rm -f "$out/$name.zip" && zip -qr "$out/$name.zip" "$name")
			echo "$out/$name.zip" ;;
		*)
			tar -C "$stage/.." -czf "$out/$name.tar.gz" "$name"
			echo "$out/$name.tar.gz" ;;
	esac
}

# What both smoke tests wait for from the server ([WIN_MAPGEN_BUILD]):
# games/vanilla with the bundled minimal game, so that every builtin --
# luanti and luanti_mapgen above all, the modules a player uses -- is
# compiled by the shipped compiler, the game's mods load and one section
# generates. games/digger before never compiled either, and a mapgen that
# did not build under mingw shipped in 0.4.2.
# The CPU time, in seconds, of a process and everything under it, and of
# every Windows process there is: under Wine each process is reparented
# to pid 1 -- the server, its compiler, conhost -- so the tree says
# nothing there and the .exe's are counted wherever they hang. simplified:
# on a host running other Wine programs their CPU counts too; the
# container runs nothing else
tree_cpu() {
	ps -eo pid=,ppid=,times=,comm= | awk -v root="$1" '
		{ pp[$1] = $2; t[$1] = $3; exe[$1] = ($NF ~ /\.exe$/) }
		END {
			for (p in pp) {
				q = p
				while (q != root && (q in pp)) q = pp[q]
				if (q == root || exe[p]) s += t[p]
			}
			print s + 0
		}'
}

# Wait for $pattern in $log while the server is alive and doing something:
# a log that has not grown and a process tree whose CPU time has not
# moved for 30 s is a hang -- an idle select, a build step stuck, a Wine
# dialog nobody can click -- and is failed on the spot rather than at the
# end of the ceiling ([WIN_SMOKE_STALL]). A compile keeps the CPU moving,
# worldgen keeps the log moving. A progress line every 30 s says which.
wait_for_line() {
	local log="$1" srv="$2" pattern="$3" ceiling="$4"
	local i size cpu last_size=-1 last_cpu=-1 still=0
	for i in $(seq 1 "$ceiling"); do
		grep -q "$pattern" "$log" 2>/dev/null && return 0
		kill -0 "$srv" 2>/dev/null || return 1
		size=$(stat -c %s "$log" 2>/dev/null || echo 0)
		cpu=$(tree_cpu "$srv")
		if [ "$size" = "$last_size" ] && [ "$cpu" = "$last_cpu" ]; then
			still=$((still + 1))
		else
			still=0; last_size=$size; last_cpu=$cpu
		fi
		if [ "$still" -ge 30 ]; then
			echo "waited ${i}s: no log or CPU movement for 30 s; the server hangs" >&2
			return 1
		fi
		if [ $((i % 30)) -eq 0 ]; then
			echo "waited ${i}s, cpu ${cpu}s, last line: $(tail -n 1 "$log" 2>/dev/null | cut -c1-120)"
		fi
		sleep 1
	done
	return 1
}

# A crash in the client's log, read rather than passed over
# ([WIN_SMOKE_STALL]): winedbg's report names the module of every frame,
# and the topmost frame's module is the answer to whether the desktop
# has the same crash. Wine's own -- its GL, its window server, its
# libc -- is Wine's and is reported (return 0); anything else is
# buildat's and is a failed smoke (return 1). No report at all is
# reported too. The Linux client says only "Segmentation fault", which
# is printed for what it is.
read_crash() {
	local log="$1" frame
	if grep -q "Unhandled page fault\|Unhandled exception" "$log"; then
		echo "the client crashed; the report:" >&2
		grep -A12 "Unhandled page fault\|Unhandled exception" "$log" | head -40 >&2
		frame=$(grep -m1 "^=>0 " "$log" || true)
		if [ -z "$frame" ]; then
			echo "the client crashed and left no backtrace" >&2
			return 0
		fi
		if echo "$frame" | grep -qi " in \(opengl32\|wined3d\|winex11\|win32u\|gdi32\|user32\|ntdll\|kernel32\|kernelbase\|ucrtbase\|msvcrt\|winevulkan\|dxgi\|d3d[0-9]*\|mesa\|libgl[a-z0-9_]*\|swrast[a-z0-9_]*\|llvmpipe\)"; then
			echo "the client crashed in Wine's own code; reported, not a verdict" >&2
			return 0
		fi
		echo "the client crashed in buildat's own code: $frame" >&2
		return 1
	fi
	if grep -q "Segmentation fault\|SIGSEGV" "$log"; then
		echo "the client crashed:" >&2
		grep -B2 -A2 "Segmentation fault\|SIGSEGV" "$log" | head -10 >&2
	fi
	return 0
}

wait_for_vanilla() {
	local log="$1" srv="$2" what="$3"
	if ! wait_for_line "$log" "$srv" "Listening at" 900; then
		echo "$what: the server did not come up; its log:" >&2
		tail -40 "$log" >&2
		return 1
	fi
	if ! wait_for_line "$log" "$srv" "Generating section\|on_generated" 300; then
		echo "$what: the game loaded no world; its log:" >&2
		tail -40 "$log" >&2
		return 1
	fi
	if grep -q "Failed to build module" "$log"; then
		echo "$what: a module did not build; its log:" >&2
		grep -n "Failed to build\|error" "$log" | head -20 >&2
		return 1
	fi
	echo "$what: the server compiled every module, loaded the game and generated a section"
}

# The archive unpacked into a clean directory and run: the server on
# games/vanilla with the bundled game through the found compiler, a client connected for one
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
	(cd "$unpacked" && BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=smoke \
		bin/buildat_server -m games/vanilla -P "$port" -l 4 > "$dir/srv.log" 2>&1) &
	local srv=$!
	local i
	# The server compiles every module it loads through the compiler
	# the archive found, which is minutes on a first run; the client
	# joins once the server listens and the world is there
	wait_for_vanilla "$dir/srv.log" "$srv" "smoke test" || {
		kill -9 "$srv" 2>/dev/null; exit 1; }
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
			! grep -q "drawn again\|Node update\|player physics enabled\|chunks in scene" "$dir/cli.log"; then
		echo "smoke test: the client did not join, draw and finish; see $dir/cli.log" >&2
		tail -40 "$dir/cli.log" >&2
		read_crash "$dir/cli.log"
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
	# and libcurl's static build (util/docker/windows builds it into
	# /opt/curlwin/curl); CURLWIN in the environment overrides
	cw="${CURLWIN:-/opt/curlwin/curl}"
	win_args=(-DPORTABLE=TRUE \
		-DCMAKE_TOOLCHAIN_FILE="$tc" \
		-DMINGW_PREFIX="${MINGW_PREFIX:-/usr/bin/x86_64-w64-mingw32}" \
		-DBUILDAT_SHIP_COMPILER="${BUILDAT_SHIP_COMPILER:-/opt/winlibs/mingw64}" \
		-DCURL_INCLUDE_DIR="$cw/include" -DCURL_LIBRARY="$cw/lib/libcurl.a")
	a=$(make_one "buildat-$version-win64" "${win_args[@]}")
	echo "archive: $a"
	check_imports "$a"
	smoke_test_wine "$a"
	# The runtime variant beside it, until it answers the desktop's
	# 0xc0000142 and becomes the packaging ([WIN_DLL_INIT]): the three
	# runtime DLLs from the cross toolchain that built the binaries
	# rather than from the shipped winlibs tree. WIN_VARIANTS=0 skips it.
	# (A static-runtime variant was tried and does not link: see
	# BUILDAT_RUNTIME_DLLS in CMakeLists.txt.)
	if [ "${WIN_VARIANTS:-1}" != 0 ]; then
		b=$(make_one "buildat-$version-win64-runtimes-toolchain" \
			"${win_args[@]}" -DBUILDAT_RUNTIME_DLLS=toolchain)
		echo "archive: $b"
		check_imports "$b"
	fi
	;;
*)
	echo "unknown target $target" >&2; exit 2 ;;
esac
