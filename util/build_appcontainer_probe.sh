#!/bin/bash
# [PROCESS_SANDBOX]: builds util/windows/appcontainer_probe.cpp into
# local/appcontainer_probe.exe with the Windows packaging image's
# mingw-w64, static, one file to copy to the Windows box and run there as
# a normal user.
#
#   util/build_appcontainer_probe.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/local"
docker build -q -t buildat-package-windows "$here/util/docker/windows" >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "$here:/src:z" -w /src buildat-package-windows \
	x86_64-w64-mingw32-g++ -O2 -static -std=c++17 \
	util/windows/appcontainer_probe.cpp -o local/appcontainer_probe.exe \
	-lws2_32 -luserenv -ladvapi32 -lshell32 -luser32 -lole32 -luuid 2>&1 |
	grep -v "^$" || true
ls -la "$here/local/appcontainer_probe.exe"
# vim: set noet ts=4 sw=4:
