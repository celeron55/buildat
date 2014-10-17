#!/bin/sh
set -euv
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

error() {
	local parent_lineno="$1"
	local message="$2"
	local code="${3:-1}"
	if [[ -n "$message" ]] ; then
		echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
		else
		echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
	fi
	exit "${code}"
}
trap 'error ${LINENO} "" ""' ERR

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

# Allow files to disable this script by the special directive
# 'codestyle:disable'
function filter_files() {
	local files=$@
	for f in $files; do
		if ! grep -lq 'codestyle:disable' "$f"; then
			echo "$f"
		fi
	done
}
header_files=$(filter_files $header_files)
cpp_files=$(filter_files $cpp_files)
lua_files=$(filter_files $lua_files)
cmake_files=$(filter_files $cmake_files)

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

# Fix miscellaneous stuff that uncrustify isn't capable of doing
python "$script_dir/extra_cpp_style.py" -i $header_files
python "$script_dir/extra_cpp_style.py" -i -b $cpp_files

# Fix comment indentation from spaces to tabs (because uncrusfity is unable to
# indent comments inside parameter lists (including lambda functions) with tabs
# if it aligns them by spaces)
sed -i -e ':loop' -e 's/    \(\t*\)\/\//\1\t\/\//' -e 't loop' $header_files $cpp_files

# Remove trailing whitespace
#sed -i -e 's/[\t ]*$//' $header_files $cpp_files $lua_files $cmake_files

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

