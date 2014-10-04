Buildat - A minecraftlike with vast extendability.
==================================================

Buildat doesn't actually even implement a minecraftlike by default. It just
provides a lot of useful machinery for doing just that, with immense modding
capabilities.

It wraps a safe subset of Urho3D's Lua API in a whitelisting Lua sandbox on
the client side and runs runtime-compiled C++ modules on the server side.

Go ahead and write some modules and extensions, maybe the minecraftlike will
exist in the near future!

Further reading:

* [doc/design.txt](doc/design.txt)
* [doc/conventions.txt](doc/conventions.txt)
* [doc/client_api.txt](doc/client_api.txt)
* [doc/todo.txt](doc/todo.txt)

Buildat Linux How-To
====================

Install dependencies
----------------------

	$ # Dependencies for Urho3D
	$ sudo apt-get install libx11-dev libxrandr-dev libasound2-dev
	$ sudo yum install libX11-devel libXrandr-devel alsa-lib-devel

Get and build Urho3D
----------------------

NOTE: You have to use celeron55's fork of Urho3D due to special features needed
	  by Buildat. Don't worry, Urho3D isn't a distro-packageable library due to
	  its various configuration options.

    $ git clone https://github.com/celeron55/Urho3D.git
    $ cd Urho3D
    $ ./cmake_gcc.sh -DURHO3D_LIB_TYPE=SHARED -DURHO3D_LUA=true -DURHO3D_SAFE_LUA=true  # Add -DURHO3D_64BIT=true on 64-bit systems
    $ cd Build
    $ make -j4

* `-DURHO3D_LIB_TYPE=SHARED` is required for the operation of the module interface.
* `-DURHO3D_SAFE_LUA=true` helps debugging issues in Lua.

Take note whether you build a 32 or a 64 bit version and use the same option in
Buildat's CMake configuration.

Build Buildat
---------------

    $ export URHO3D_HOME=/path/to/urho3d
    $ cd $wherever_buildat_is
    $ mkdir Build  # Capital B is a good idea so it stays out of the way in tabcomplete
    $ cd Build
    $ cmake .. -DCMAKE_BUILD_TYPE=Debug -DURHO3D_LIB_TYPE=SHARED  # Add -DURHO3D_64BIT=true on 64-bit systems
    $ make -j4

You can use -DBUILD_SERVER=false or -DBUILD_CLIENT=false if you don't need the
server or the client, respectively.

Run Buildat
-------------

Terminal 1:

    $ $wherever_buildat_is/Build
    $ bin/buildat_server -m ../games/minigame

Terminal 2:

    $ $wherever_buildat_is/Build
    $ bin/buildat_client -s localhost -U $URHO3D_HOME

Modify something and see stuff happen
---------------------------------------

Edit something and then restart the client (CTRL+C in terminal 2):

    $ cd $wherever_buildat_is
    $ vim games/minigame/main/client_lua/init.lua
    $ vim games/minigame/main/main.cpp
    $ vim builtin/network/network.cpp

Buildat Windows How-To
======================

Use Mingw-w64 in an MSYS environment.

    $ cd /path/to/Urho3D
    $ mkdir Build
    $ cd Build
    $ cmake ../Source -G "MSYS Makefiles" -DURHO3D_LIB_TYPE=SHARED -DURHO3D_LUAJIT=TRUE
    $ make -j4

    $ cd /path/to/buildat
    $ mkdir Build
    $ cd Build
	$ export URHO3D_HOME="/path/to/Urho3D"
    $ cmake .. -G "MSYS Makefiles" -DCMAKE_BUILD_TYPE=Debug -DURHO3D_LIB_TYPE=SHARED -DURHO3D_LUAJIT=TRUE
    $ make -j4

Running the server:

    $ bin/buildat_server.exe -m ../games/minigame -c "c++ -Lbin -lbuildat_server_core"

