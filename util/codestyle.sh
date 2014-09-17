#!/bin/sh
set -euv
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

header_files="$script_dir"/../src/*/*.h
cpp_files="$script_dir"/../src/*/*.cpp

header_files+=" ""$script_dir"/../test/testmodules/*/*/*.h
cpp_files+=" ""$script_dir"/../test/testmodules/*/*/*.cpp

header_files+=" "$(find "$script_dir"/../share/builtin -name '*.h')
cpp_files+=" "$(find "$script_dir"/../share/builtin -name '*.cpp')

echo "header_files: $header_files"
echo "cpp_files: $cpp_files"

# Fix all that astyle is capable of
astyle -z2 -W3 -k3 -p -w -Y -K -N -t -m1 $header_files
astyle -z2 -W3 -k3 -p -w -Y -K -t -m1 $cpp_files

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


