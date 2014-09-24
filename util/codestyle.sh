#!/bin/sh
set -euv
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

header_files="$script_dir"/../src/*/*.h
cpp_files="$script_dir"/../src/*/*.cpp

header_files+=" "$(find "$script_dir"/../test/testmodules -name '*.h')
cpp_files+=" "$(find "$script_dir"/../test/testmodules -name '*.cpp')

header_files+=" "$(find "$script_dir"/../builtin -name '*.h')
cpp_files+=" "$(find "$script_dir"/../builtin -name '*.cpp')

header_files+=" "$(find "$script_dir"/../3rdparty/c55lib -name '*.h')
cpp_files+=" "$(find "$script_dir"/../3rdparty/c55lib -name '*.cpp')

lua_files=""$(find "$script_dir"/../extensions -name '*.lua')
lua_files+=" "$(find "$script_dir"/../client -name '*.lua')
lua_files+=" "$(find "$script_dir"/../test/testmodules -name '*.lua')

cmake_files="$script_dir"/../CMakeLists.txt

echo "header_files: $header_files"
echo "cpp_files: $cpp_files"
echo "lua_files: $lua_files"
echo "cmake_files: $cmake_files"

# Fix all that astyle is capable of
# Note: Astyle's character limit doesn't count tabs as multiple spaces.
basestyle="-n -z2 -W3 -k3 -p -Y -K -t4 -m1 -xC80"
astyle $basestyle -N $header_files
astyle $basestyle $cpp_files

# Remove spaces before semicolons
sed -i -e 's/ *;/;/g' $header_files $cpp_files

# Fiddle around with spacing
sed -i -e 's/\(for\|while\|if\) (/\1(/g' $header_files $cpp_files
sed -i -e 's/) {/){/g' $header_files $cpp_files
sed -i -e 's/}[\t ]*else[\t ]*{/} else {/g' $header_files $cpp_files
sed -i -e 's/ << /<</g' $header_files $cpp_files
sed -i -e 's/ >> />>/g' $header_files $cpp_files
sed -i -e 's/^\(\s*\(EXPORT\|virtual\|\)\s*[a-zA-Z0-9_:,]*\) \*\([a-zA-Z0-9_:,]*(\)/\1* \3/g' $header_files $cpp_files
sed -i -e 's/^\(\s*\(EXPORT\|virtual\|\)\s*[a-zA-Z0-9_:,]*\) &\([a-zA-Z0-9_:,]*(\)/\1& \3/g' $header_files $cpp_files
sed -i -e 's/ \*)/*)/g' $header_files $cpp_files
sed -i -e 's/ \*>/*>/g' $header_files $cpp_files
sed -i -e 's/ &)/&)/g' $header_files $cpp_files
sed -i -e 's/ &>/&>/g' $header_files $cpp_files
sed -i -e 's/\*\s\+>/\*>/g' $header_files $cpp_files
sed -i -e 's/ + "/+"/g' $header_files $cpp_files
sed -i -e 's/" + /"+/g' $header_files $cpp_files
sed -i -e 's/" *+$/"+/g' $header_files $cpp_files
sed -i -e 's/^\(\t\+\)   \+/\1\t\t/g' $header_files $cpp_files

# Fix or add Vim modeline magic
sed -i '/^\/\/ vim: set /d' $header_files $cpp_files
for f in $header_files $cpp_files; do
	echo '// vim: set noet ts=4 sw=4:' >> $f
done
sed -i '/^# vim: set /d' $lua_files $cmake_files
for f in $lua_files $cmake_files; do
	echo '# vim: set noet ts=4 sw=4:' >> $f
done

# Format CMake too
sed -i -e 's/\(^[ \t]*\)\([A-Za-z_]\+\)[ \t]*(/\1\L\2(/' $cmake_files
sed -i -e 's/([\t ]\+\([A-Za-z_${)]\)/(\1/g' $cmake_files
sed -i -e 's/\([A-Za-z_}(]\)[\t ]\+)/\1)/g' $cmake_files

