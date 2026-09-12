![Buildat](client/data/buildat_logo.png)

Buildat
=======
A small engine for networked 3D games.

The server runs C++ modules compiled at runtime. The client runs a
whitelisted subset of Urho3D's Lua API in a sandbox; scripts and data
come from the server.

Voxel worlds, replication, and worldgen are builtin modules. Nothing
requires a block game. Digger is a finite voxel example. Infidigger
streams an infinite world with the same modules.

Further reading:

* [doc/design.txt](doc/design.txt)
* [doc/conventions.txt](doc/conventions.txt)
* [doc/client_api.txt](doc/client_api.txt)
* [doc/client_commands.txt](doc/client_commands.txt)
* [doc/todo.txt](doc/todo.txt)

Buildat Linux How-To
====================

Install dependencies
----------------------

	$ # A compiler and cmake, plus the X, sound and GL headers Urho3D needs
	$ sudo apt-get install build-essential cmake \
	        libx11-dev libxrandr-dev libasound2-dev libgl1-mesa-dev
	$ sudo dnf install gcc-c++ cmake \
	        libX11-devel libXrandr-devel alsa-lib-devel mesa-libGL-devel

The server also needs a C++ compiler at run time, not just at build time: it
compiles game modules as it loads them. It looks for `c++` in PATH.

Build
-------

Urho3D 1.7.1 is bundled in `3rdparty/Urho3D` and is configured/built as part of
this project (shared library, Lua, safe Lua). `-DURHO3D_LIB_TYPE=SHARED` is
required for the module interface.

    $ cd $wherever_buildat_is
    $ mkdir Build  # Capital B is a good idea so it stays out of the way in tabcomplete
    $ cd Build
    $ cmake .. -DCMAKE_BUILD_TYPE=Debug
    $ make -j4

The bundled Urho3D is built by a sub-build that uses every core regardless of
the `-j` given here, which is where the `-j0 forced in submake` warning comes
from.

You can use -DBUILD_SERVER=false or -DBUILD_CLIENT=false if you don't need the
server or the client, respectively.

`-DPORTABLE=TRUE`, the default, keeps the cache and the user's own things
beside the program, in `cache/` and `user/`. That is what development wants.
`-DPORTABLE=FALSE` puts them where the platform says instead
(`$XDG_DATA_HOME/buildat` and `$XDG_CACHE_HOME/buildat` on Linux,
`%APPDATA%\buildat` and `%LOCALAPPDATA%\buildat\cache` on Windows,
`~/Library/Application Support/buildat` and `~/Library/Caches/buildat` on
macOS), which is what an installed copy wants. `-C` and `-D` override either.

Optional: `-DURHO3D_LUAJIT=TRUE` builds the bundled LuaJIT instead of Lua.
`URHO3D_HOME` still overrides the bundled tree if you need an external build.

Play
----

    $ $wherever_buildat_is/Build/bin/buildat

The launch menu: a local game, a server to connect to, or one of the
extensions that can be launched on their own -- a Luanti client, so far.
Arrows or the mouse to pick, enter to go.

Debug keys, in any game:

* F8: draw debug geometry
* F9: on-screen profiler, render and resource stats
* F10: sandbox test extension

Preferences
-----------

What the user sets once and every game honours: `render_scale` (3D viewports
drawn at a fraction of the window size, with the UI left at native
resolution), `vsync`, `max_fps`, `multisampling`, `sound_volume` and
`sound_mute`. They live in `user/preferences.json` beside the remembered
window size, and there is no screen for them yet -- edit the file, or set them
for one run with `-o`, which is not written back:

    $ bin/buildat -o render_scale=0.5,vsync=0,sound_mute=1

`user/` is where what the user made, chose or downloaded deliberately goes, as
against `cache/`, which is what the program can recreate by itself. In the
default portable build both sit in the buildat directory; `-D` and `-C` move
them, and `-DPORTABLE=FALSE` puts them where the platform says (see Build).

See [doc/client_api.txt](doc/client_api.txt) for what a game does to honour
`render_scale`, and what the client does not get to decide.

Server and client
-----------------

For development or hosting, run the two binaries separately:

Terminal 1:

    $ $wherever_buildat_is/Build
    $ bin/buildat_server -m ../games/minigame

Terminal 2:

    $ $wherever_buildat_is/Build
    $ bin/buildat -s localhost

Client command sequence (CI / visual checks)
--------------------------------------------

The client can run a one-shot command script and exit. Screenshots, delays,
and injected keyboard/mouse input:

    $ bin/buildat -c $'delay 2000\nscreenshot /tmp/menu.png'
    $ bin/buildat -c @commands.txt

See [doc/client_commands.txt](doc/client_commands.txt).

Modify something and see stuff happen
---------------------------------------

Edit something and then restart the client (CTRL+C in terminal 2):

    $ cd $wherever_buildat_is
    $ vim games/minigame/main/client_lua/init.lua
    $ vim games/minigame/main/main.cpp
    $ vim builtin/network/network.cpp

Buildat Windows How-To
======================

Use Mingw-w64 in an MSYS environment. Make sure to use a pthreads version of Mingw-w64. Windows threads are not supported ATM.

    $ cd /path/to/buildat
    $ mkdir Build
    $ cd Build
    $ cmake .. -G "MSYS Makefiles" -DCMAKE_BUILD_TYPE=Debug -DURHO3D_LUAJIT=TRUE
    $ make -j4

Running the server:

    $ bin/buildat_server.exe -m ../games/minigame -c "c++ -Lbin -lbuildat_server_core"

