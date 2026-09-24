#!/bin/bash
# A tier of checks, run in the packaging image ([CI_RUNS] (5)):
#
#   util/checks_in_docker.sh quick
#   util/checks_in_docker.sh full
#
# The same image the Linux archives are built in (util/docker/linux), a
# git archive of HEAD rather than a mount of the working tree, a Release
# build, and builtin/luanti/test/run_all.sh under Xvfb. Everything the
# run wrote under local/ is copied to Build/checks/out/ on the host, so a
# failure can be read from outside the container.
#
# The exit status is the tier's: 0 every runner passed or skipped, 1 any
# failed.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tier="${1:-quick}"
image="buildat-package-linux"
out="$here/Build/checks/out"
rm -rf "$out"; mkdir -p "$out"
docker build -t "$image" "$here/util/docker/linux"
tarball=$(mktemp /tmp/buildat_checks_in_docker.XXXXXX)
trap 'rm -f "$tarball"' EXIT
git -C "$here" archive --format=tar HEAD > "$tarball"
# BUILDAT_CI: a timing is a row and never a verdict on a machine whose
# speed nobody chose (builtin/luanti/test/verdict.sh)
docker run --rm -i \
	-v "$out:/out:z" \
	-e "BUILDAT_CI=1" \
	-e "JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}" \
	"$image" bash -c "
		set -eu
		mkdir -p /work/buildat && cd /work/buildat && tar -xf - &&
		mkdir -p Build && cd Build &&
		cmake .. -DCMAKE_BUILD_TYPE=Release > cmake.log 2>&1 ||
			{ tail -20 cmake.log; cp cmake.log /out/; exit 2; }
		cmake --build . -j \$JOBS > build.log 2>&1 ||
			{ tail -40 build.log; cp build.log /out/; exit 2; }
		cd /work/buildat
		status=0
		xvfb-run -a -s '-screen 0 1280x720x24' \
			builtin/luanti/test/run_all.sh $tier || status=\$?
		cp -r local/. /out/ 2>/dev/null || true
		exit \$status
	" < "$tarball"
