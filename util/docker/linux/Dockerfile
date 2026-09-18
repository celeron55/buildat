# The Linux packaging image ([PACKAGING] in doc/plan/packaging_plan.md):
# Debian oldstable, the oldest glibc worth supporting, so the tarball built
# here runs on newer distros; the build dependencies README.md names, and
# what util/package.sh's smoke test needs -- a virtual display for the
# client, ImageMagick to read its screenshot, zip and tar for the archives.
# Nothing of the host's tree is built here: util/package_in_docker.sh hands
# the container a git archive of the commit and takes the archives back.
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
	build-essential cmake git ca-certificates \
	libx11-dev libxrandr-dev libasound2-dev libgl1-mesa-dev \
	xvfb xauth libgl1-mesa-dri imagemagick zip tar gzip \
	&& rm -rf /var/lib/apt/lists/*
WORKDIR /work
