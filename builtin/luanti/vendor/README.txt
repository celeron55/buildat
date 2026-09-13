Vendored from Luanti
====================

Luanti is LGPL-2.1-or-later; buildat is Apache-2.0. This works because a
buildat module is dynamically linked at runtime -- src/server/rccpp.cpp
compiles each one to its own shared object and dlopens it -- so the vendored
code lives in that object and buildat_server itself links none of it. See
COPYING.LESSER beside this file, and doc/luanti_module.txt.

Nothing under this directory is copied into buildat proper.

Luanti states its licence once, in the LICENSE.txt at the root of its own
tree; these Lua files carry no header of their own. The statement, copied
verbatim, is in buildat's NOTICE, and the full licence is in COPYING.LESSER.
One file here is under other terms and does say so in itself:
builtin/common/serialize.lua is MIT, from appgurueu's modlib
(https://github.com/appgurueu/modlib, luon.lua).

No Luanti media is here. Luanti's textures and sounds are CC BY-SA, with
their authors listed in its LICENSE.txt; a client gets media from the server
it plays on.

Upstream: https://github.com/luanti-org/luanti
Commit:   befadef82035f57a478de88e3f939f3e77e6e77c (2026-09-05)

What is here
------------

builtin/          Luanti's own Lua layer: builtin/init.lua and the common/
                  and game/ trees it loads when INIT == "game". The C API
                  underneath it is buildat's, written in ../luanti.cpp.

Not taken: the mainmenu, client, async, emerge, sscsm and pause_menu trees,
which this never runs; common/filterlist.lua, common/menu.lua and
common/settings/, which only the main menu uses; and the tests/ directories,
which want Luanti's own test runner.

Modifications
-------------

None so far. A file that gets modified says so at the top of itself: which
version it came from and what was changed.
