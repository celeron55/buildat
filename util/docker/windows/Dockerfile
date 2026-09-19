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
WORKDIR /work
