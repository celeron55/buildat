# The Windows packaging image ([PACKAGING] step 3): Debian's mingw-w64 cross
# toolchain builds buildat.exe, buildat_server.exe and the bundled Urho3D
# (through Urho3D's own CMake/Toolchains/MinGW.cmake); Wine runs the smoke
# test. The compiler the archive ships under compiler/ is a separate,
# native MinGW-w64 distribution -- not this one, which is a Linux program
# -- pinned by URL and hash below once step 3's install rules take it.
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
	build-essential cmake git ca-certificates \
	mingw-w64 g++-mingw-w64-x86-64 binutils-mingw-w64-x86-64 \
	zip tar gzip curl xz-utils \
	&& rm -rf /var/lib/apt/lists/*
# The POSIX-threads flavour of the cross compiler, for std::thread
RUN update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix && \
	update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
# The compiler the archive ships under compiler/: a native MinGW-w64
# distribution, winlibs' GCC 13.2 with the msvcrt runtime and POSIX
# threads, the same C runtime and thread model as Debian's cross
# toolchain above, so a module it compiles links against what that built.
# One URL and one hash; a change of either is a deliberate commit.
ARG WINLIBS_URL=https://github.com/brechtsanders/winlibs_mingw/releases/download/13.2.0posix-17.0.6-11.0.1-msvcrt-r5/winlibs-x86_64-posix-seh-gcc-13.2.0-mingw-w64msvcrt-11.0.1-r5.zip
ARG WINLIBS_SHA256=675f79b6fba8d3c8165bd9b5fb8e96ab73370dd8611f13e520cb185357d3dafc
# And Wine, for the smoke test: the server out of the archive, compiling
# a module with the compiler the archive ships, under the virtual display
# the client will want later
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends unzip \
	wine wine64 wine32:i386 xvfb xauth libgl1-mesa-dri imagemagick \
	&& rm -rf /var/lib/apt/lists/* \
	&& curl -sSL -o /tmp/winlibs.zip "$WINLIBS_URL" \
	&& echo "$WINLIBS_SHA256  /tmp/winlibs.zip" | sha256sum -c - \
	&& mkdir -p /opt/winlibs && unzip -q /tmp/winlibs.zip -d /opt/winlibs \
	&& rm /tmp/winlibs.zip
# libcurl for the cross build ([CONTENTDB], a required dependency): Debian
# has no mingw-w64 curl package, so curl-for-win's mingw build, pinned the
# same way -- headers and import library for the link, the DLL shipped
# beside the executables. util/package.sh hands its paths to CMake.
ARG CURLWIN_URL=https://curl.se/windows/dl-8.22.0_1/curl-8.22.0_1-win64-mingw.zip
ARG CURLWIN_SHA256=7f23b039f6ea4197362d4468e1a0e71428201222e1bef3b680d5ef7b2aefb714
RUN curl -sSL -o /tmp/curlwin.zip "$CURLWIN_URL" \
	&& echo "$CURLWIN_SHA256  /tmp/curlwin.zip" | sha256sum -c - \
	&& mkdir -p /opt/curlwin && unzip -q /tmp/curlwin.zip -d /opt/curlwin \
	&& mv /opt/curlwin/curl-*-win64-mingw /opt/curlwin/curl \
	&& rm /tmp/curlwin.zip
WORKDIR /work
