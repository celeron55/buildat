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

    $ git clone https://github.com/urho3d/Urho3D.git
    $ cd Urho3D
    $ ./cmake_gcc.sh -DURHO3D_LUA=true -DURHO3D_SAFE_LUA=true # Add -DURHO3D_64BIT=true on 64-bit systems
    $ cd Build
    $ make -j4

`-DURHO3D_SAFE_LUA=true` helps debugging issues in Lua.

Take note whether you build a 32 or a 64 bit version and use the same option in
Buildat's CMake configuration.

Build Buildat
---------------

    $ export URHO3D_HOME=/path/to/urho3d
    $ cd $wherever_buildat_is
    $ mkdir Build  # Capital B is a good idea so it stays out of the way in tabcomplete
    $ cd Build
    $ cmake .. -DCMAKE_BUILD_TYPE=Debug  # Add -DURHO3D_64BIT=true on 64-bit systems
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

Umm... well, you need to first port some stuff. Try building it and see what
happens. Then fix it and make a pull request.

You probably want to use MinGW or Clang in order to bundle the compiler with the
end result.

