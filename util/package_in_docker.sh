#!/bin/bash
# The archives, made in a container and nowhere else ([PACKAGING]):
#
#   util/package_in_docker.sh linux <version>
#   util/package_in_docker.sh windows <version>
#
# Builds util/docker/<target>'s image, hands it a git archive of HEAD --
# not a mount of the working tree, so the host's Build/ and 3rdparty/Urho3D/
# Build/ take no part and the container builds Urho3D against its own
# libraries -- runs util/package.sh inside, and copies the archives to
# Build/package/out/ on the host. A build that targets packaging runs
# here; the host builds for development and testing only.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target="${1:-}"
version="${2:-}"
if [ -z "$target" ] || [ -z "$version" ]; then
	echo "usage: util/package_in_docker.sh <linux|windows> <version>" >&2
	exit 2
fi
if [ ! -f "$here/util/docker/$target/Dockerfile" ]; then
	echo "no image for $target: util/docker/$target/Dockerfile" >&2
	exit 2
fi
image="buildat-package-$target"
out="$here/Build/package/out"
mkdir -p "$out"
docker build -t "$image" "$here/util/docker/$target"
# The tree as committed, including the bundled Urho3D and the other
# 3rdparty sources; anything uncommitted is not in a release
tarball=$(mktemp)
git -C "$here" archive --format=tar HEAD > "$tarball"
docker run --rm -i \
	-v "$out:/out" \
	-e "JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}" \
	"$image" bash -c "
		set -eu
		mkdir -p /work/buildat && cd /work/buildat && tar -xf - &&
		xvfb-run -a util/package.sh $target $version &&
		cp Build/package/out/* /out/
	" < "$tarball"
rm -f "$tarball"
echo "archives in $out:"
ls -la "$out"
