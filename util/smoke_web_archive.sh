#!/bin/bash
# A web archive on a bare box ([LINUX_SERVER] in
# doc/plan/packaging_plan.md):
#
#   util/smoke_web_archive.sh Build/package/out/buildat-*-web.tar.gz
#
# Unpacks it in debian:bookworm-slim with nothing added but libcurl4 --
# and build-essential for the "web" archive, which compiles the games on
# the box; the "web-precompiled" one has to start with no compiler and
# compile nothing -- starts games/floorplanner there, and checks from
# outside with util/test_web_transport.py that it serves the web client's
# page and WebSocket and a native client's TCP. Needs docker, and python3
# with websockets on the host. util/package_in_docker.sh runs it.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
port="${PORT:-$(( 29400 + (RANDOM % 90) ))}"
name="buildat-web-smoke-$$"
case "$archive" in
	*-web-precompiled.tar.gz) packages="libcurl4"; precompiled=1 ;;
	*-web.tar.gz) packages="libcurl4 build-essential"; precompiled= ;;
	*) echo "not a web archive: $archive" >&2; exit 2 ;;
esac
log=$(mktemp /tmp/buildat_smoke_web_archive.XXXXXX)
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "smoke: $(basename "$archive") in debian:bookworm-slim with $packages, port $port"
# simplified: the image by tag and the packages unpinned; a bare box of the
# day is what the archive meets
docker run -d --name "$name" -p "127.0.0.1:$port:29500" \
	-v "$(dirname "$archive"):/a:ro,z" debian:bookworm-slim bash -c "
		set -e
		apt-get update -qq && apt-get install -y -qq --no-install-recommends $packages >/dev/null
		mkdir /srv/b && tar -C /srv/b -xzf /a/$(basename "$archive") && cd /srv/b/*/
		echo compiler: \$(command -v c++ || echo none)
		exec bin/buildat_server -m games/floorplanner -l 3
	" >/dev/null
for i in $(seq 1 900); do
	docker logs "$name" > "$log" 2>&1 || true
	grep -q "Listening at" "$log" && break
	if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != true ]; then
		echo "smoke: the server stopped; its log's end:" >&2; tail -30 "$log" >&2; exit 1
	fi
	sleep 1
done
grep -q "Listening at" "$log" || { echo "smoke: no Listening in 900 s" >&2; tail -30 "$log" >&2; exit 1; }
python3 "$here/util/test_web_transport.py" "127.0.0.1:$port"
docker logs "$name" > "$log" 2>&1 || true
if [ -n "$precompiled" ]; then
	grep -q "No C++ compiler (c++) found" "$log" ||
		{ echo "smoke: the box had a compiler?" >&2; exit 1; }
	if grep -q "STATUS Compiling" "$log"; then
		echo "smoke: something compiled on a box with no compiler:" >&2
		grep "STATUS Compiling" "$log" >&2; exit 1
	fi
else
	grep -q "STATUS Compiling main" "$log" ||
		{ echo "smoke: the game's module was not compiled on the box" >&2; exit 1; }
fi
[ -n "${SMOKE_LOG:-}" ] && cp "$log" "$SMOKE_LOG"
rm -f "$log"
echo "smoke passed: $(basename "$archive") serves browsers and native clients on a bare box"
