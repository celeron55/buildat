#!/bin/sh
set -euv
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

header_files="$script_dir"/../src/*/*.h
cpp_files="$script_dir"/../src/*/*.cpp

header_files+=" "$(find "$script_dir"/../games -name '*.h')
cpp_files+=" "$(find "$script_dir"/../games -name '*.cpp')

header_files+=" "$(find "$script_dir"/../builtin -name '*.h')
cpp_files+=" "$(find "$script_dir"/../builtin -name '*.cpp')

header_files+=" "$(find "$script_dir"/../3rdparty/c55lib -name '*.h')
cpp_files+=" "$(find "$script_dir"/../3rdparty/c55lib -name '*.cpp')

lua_files=""$(find "$script_dir"/../extensions -name '*.lua')
lua_files+=" "$(find "$script_dir"/../client -name '*.lua')
lua_files+=" "$(find "$script_dir"/../games -name '*.lua')

cmake_files="$script_dir"/../CMakeLists.txt

echo "header_files: $header_files"
echo "cpp_files: $cpp_files"
echo "lua_files: $lua_files"
echo "cmake_files: $cmake_files"

# Fix all that uncrustify is capable of
uncrustify_base="$script_dir/../util/uncrustify.cfg"
uncrustify_add_header="$script_dir/../util/uncrustify.header.cfg"
uncrustify_add_cpp="$script_dir/../util/uncrustify.cpp.cfg"

uncrustify_header="/tmp/buildat.uncrustify.header.cfg"
uncrustify_cpp="/tmp/buildat.uncrustify.cpp.cfg"
cat "$uncrustify_base" "$uncrustify_add_header" > "$uncrustify_header"
cat "$uncrustify_base" "$uncrustify_add_cpp" > "$uncrustify_cpp"

uncrustify -c "$uncrustify_header" --no-backup $header_files
uncrustify -c "$uncrustify_cpp" --no-backup $cpp_files

# Fix or add Vim modeline magic
sed -i '/^\/\/ vim: set /d' $header_files $cpp_files
for f in $header_files $cpp_files; do
	echo '// vim: set noet ts=4 sw=4:' >> $f
done
sed -i '/^-- vim: set /d' $lua_files
for f in $lua_files; do
	echo '-- vim: set noet ts=4 sw=4:' >> $f
done
sed -i '/^# vim: set /d' $cmake_files
for f in $cmake_files; do
	echo '# vim: set noet ts=4 sw=4:' >> $f
done

# Format CMake too
sed -i -e 's/\(^[ \t]*\)\([A-Za-z_]\+\)[ \t]*(/\1\L\2(/' $cmake_files
sed -i -e 's/([\t ]\+\([A-Za-z_${)]\)/(\1/g' $cmake_files
sed -i -e 's/\([A-Za-z_}(]\)[\t ]\+)/\1)/g' $cmake_files

