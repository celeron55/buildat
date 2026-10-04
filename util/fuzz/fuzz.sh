#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4: the decoders a peer or a file can feed, each a
# libFuzzer harness built with clang under ASan and UBSan, run time-boxed.
# The corpus and every crashing input are kept under
# local/security/fuzz/<target>/, so a run starts where the last stopped
# and a crash found once is replayed by every later run.
#
#   util/fuzz/fuzz.sh [seconds per target] [target ...]
#
# Without targets, all of them. A crash prints its file and the run ends
# non-zero.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
me="$here/util/fuzz"
out="$here/local/security/fuzz"
secs=${1:-60}
shift || true
mkdir -p "$out/bin"

flags="-std=c++17 -g -O1 -fsanitize=fuzzer,address,undefined
	-fno-sanitize-recover=undefined -I$here/src -I$here
	-I$here/3rdparty/c55lib -I$here/3rdparty/cereal/include
	-I$here/3rdparty/polyvox/library/PolyVoxCore/include
	-I$here/3rdparty/sajson/include -DBUILDAT_FUZZ
	-I$here/3rdparty/Urho3D/Build/include
	-I$here/3rdparty/Urho3D/Build/include/Urho3D
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/Math
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/Container
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/Core
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/ThirdParty"
# Each target's sources beside its harness
declare -A srcs=(
	[compress]="src/impl/compress.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp"
	[packet_stream]="src/impl/packet_stream.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp"
	[voxel_volume]="src/impl/voxel_volume.cpp src/impl/compress.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp 3rdparty/polyvox/library/PolyVoxCore/source/Region.cpp src/impl/voxel.cpp src/impl/linux/os.cpp src/impl/fs.cpp src/impl/linux/fs.cpp 3rdparty/c55lib/c55/filesys.cpp"
	[json]="src/core/json.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp"
	[zip]="src/impl/zip.cpp src/impl/compress.cpp src/impl/fs.cpp src/impl/linux/fs.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp 3rdparty/c55lib/c55/filesys.cpp"
	# The decoders compiled in, instrumented; the rest of Urho3D from its
	# library (image_fuzz.cpp)
	[image]="3rdparty/Urho3D/Source/Urho3D/Resource/Image.cpp 3rdparty/Urho3D/Source/Urho3D/Resource/Decompress.cpp"
	[markup]="src/impl/markup.cpp"
)
# C sources, compiled apart with the same sanitizers and linked in
declare -A csrcs=(
	[markup]="3rdparty/md4c/md4c.c"
)
declare -A libs=(
	[compress]="-lz -lzstd"
	[packet_stream]=""
	[voxel_volume]="-lz -lzstd"
	[json]=""
	[zip]="-lz -lzstd"
	[image]="-L$here/3rdparty/Urho3D/Build/lib -lUrho3D -Wl,-rpath,$here/3rdparty/Urho3D/Build/lib"
	[markup]="-I$here/3rdparty/md4c"
)
# Urho3D's own defines and include paths for the files compiled from it;
# stb_image's JPEG decoder shifts negative values left, and a PNG's empty
# first IDAT copies 0 bytes to a null buffer: both done as intended by
# every compiler here, and UBSan would stop on them
uflags=$here/3rdparty/Urho3D/Build/Source/Urho3D/CMakeFiles/Urho3D.dir/flags.make
declare -A extra=(
	[image]="$(sed -n 's/^CXX_\(DEFINES\|INCLUDES\) = //p' "$uflags" 2>/dev/null) -fno-sanitize=shift,nonnull-attribute -w"
)
targets=${*:-${!srcs[@]}}

build() {
	local t=$1 s=""
	for f in ${srcs[$t]}; do s="$s $here/$f"; done
	for f in ${csrcs[$t]:-}; do
		clang -g -O1 -fsanitize=fuzzer-no-link,address,undefined \
			-fno-sanitize-recover=undefined -c "$here/$f" \
			-o "$out/bin/$t.$(basename "$f").o" 2> "$out/bin/$t.build.log" || {
			echo "$t: build failed, $out/bin/$t.build.log"; return 1; }
		s="$s $out/bin/$t.$(basename "$f").o"
	done
	clang++ $flags ${extra[$t]:-} "$me/${t}_fuzz.cpp" $s ${libs[$t]} -o "$out/bin/$t" \
		2> "$out/bin/$t.build.log" || {
		echo "$t: build failed, $out/bin/$t.build.log"; tail -5 "$out/bin/$t.build.log"
		return 1
	}
}

status=0
for t in $targets; do
	build "$t" || { status=1; continue; }
	mkdir -p "$out/$t/corpus" "$out/$t/crashes"
	[ -d "$me/seeds/$t" ] && cp -n "$me/seeds/$t"/* "$out/$t/corpus/" 2>/dev/null
	# Every crash kept before is replayed first
	for c in "$out/$t/crashes"/*; do
		[ -e "$c" ] || continue
		"$out/bin/$t" "$c" > /dev/null 2>&1 || {
			echo "$t: a kept crash still crashes: $c"; status=1; }
	done
	"$out/bin/$t" -max_total_time="$secs" -rss_limit_mb=2048 -timeout=10 -print_final_stats=1 \
		-artifact_prefix="$out/$t/crashes/" "$out/$t/corpus" \
		> "$out/$t/last.log" 2>&1
	r=$?
	execs=$(grep -ao "stat::number_of_executed_units: [0-9]*" "$out/$t/last.log" | grep -o "[0-9]*$")
	cov=$(grep -ao "cov: [0-9]*" "$out/$t/last.log" | tail -1)
	if [ $r -ne 0 ]; then
		echo "$t: CRASH ($(ls -t "$out/$t/crashes" | head -1)); $out/$t/last.log"
		grep -a "ERROR: \|: runtime error" "$out/$t/last.log" | head -3
		status=1
	else
		echo "$t: ${execs:-?} runs in ${secs} s, $cov, $(ls "$out/$t/corpus" | wc -l) in the corpus"
	fi
done
exit $status
