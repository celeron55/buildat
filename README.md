Buildat - A minecraftlike with vast extendability.
==================================================

Buildat doesn't actually even implement a minecraftlike by default. It just
provides a lot of useful machinery for doing just that, with immense modding
capabilities.

It wraps a safe subset of Polycode's Lua API in a whitelisting Lua sandbox on
the client side and runs runtime-compiled C++ modules on the server side.

Go ahead and write some modules and extensions, maybe the minecraftlike will
exist in the near future!

Buildat Linux How-To
====================

Install dependencies for Polycode (replace with however your package manager works)
-------------------------------------------------------------------------------------

    $ sudo yum install python-ply

Get and build Polycode
------------------------

    $ git clone https://github.com/ivansafrin/Polycode.git
    $ cd Polycode

At the moment (2014-09-19) BuildLinux.sh is so outdated that it is unusable:

    $ wget https://raw.githubusercontent.com/celeron55/Polycode/b7e729e2be26b75ae0922f61cb56df3d6e98b86d/BuildLinux.sh -O BuildLinuxFixed.sh

    $ sh BuildLinuxFixed.sh -j4  # -j<n> selects number of threads for compilation

To make sure Polycode was built and is fully working, try running the Polycode IDE:

    $ cd IDE/Build/Linux/Build
    $ ./Polycode

Build Buildat
---------------

    $ cd $wherever_buildat_is  # Preferably ../buildat from Polycode
    $ mkdir Build  # Capital B is a good idea so it stays out of the way in tabcomplete
    $ cd Build
    $ cmake .. -DCMAKE_BUILD_TYPE=Debug -DPOLYCODE_ROOT_DIR=../../Polycode
    $ make -j4

Run Buildat
-------------

Terminal 1:

    $ $wherever_buildat_is/Build
    $ bin/buildat_server -m ../test/testmodules

Terminal 2:

    $ $wherever_buildat_is/Build
    $ bin/buildat_client -s localhost -p ../../Polycode

Modify something and see stuff happen
---------------------------------------

Edit something and then restart the client (CTRL+C in terminal 2):

    $ cd $wherever_buildat_is
    $ vim test/testmodules/minigame/client_lua/init.lua
    $ vim test/testmodules/minigame/minigame.cppp
    $ vim builtin/network/network.cpp

Buildat Windows How-To
======================

Umm... well, you need to first port some stuff. Try building it and see what
happens. Then fix it and make a pull request.

You probably want to use MinGW or Clang in order to bundle the compiler with the
end result.

