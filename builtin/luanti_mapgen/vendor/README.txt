Luanti's mapgen, vendored, and the shim under it
================================================

The files here are either Luanti's own, copied without changes, or a shim
written for this module. The shims are what let Luanti's mapgen compile
against buildat instead of against Luanti's engine; they answer the small
part of Luanti's headers that the mapgen actually uses, and no more. See
"Mapgen stage 3: how it lands" in doc/plan/luanti_module_plan.md for why
each one is a shim rather than a vendoring.

They sit in the same directory as the vendored code on purpose: a
runtime-compiled module gets no include directories of its own, and a
quoted #include looks beside the file that wrote it.

Luanti's own, unchanged (upstream: git master, 2026-09):

    voxel.h, voxel.cpp                  <- compiled
    objdef.h, objdef.cpp                <- vendored, not yet compiled
    mapgen.h, mapgen.cpp                <- vendored, not yet compiled
    mapgen_singlenode, _v5, _v6, _v7, _flat, _fractal, _valleys,
        _carpathian                     <- vendored, not yet compiled
    mg_biome, mg_ore, mg_decoration, mg_schematic,
        cavegen, dungeongen, treegen    <- vendored, not yet compiled
    util/serialize.h, util/serialize.cpp, util/hex.h, util/ieee_float.*
                                        <- vendored, not yet compiled

Where the port stopped (2026-09-13)
-----------------------------------

luanti_mapgen.cpp compiles the bottom of the tree: voxel.cpp with the shims
under it, the noise adapter and the node definitions. Everything above is
in the tree and not yet in that list of includes.

The next piece is util/serialize.cpp, which mg_schematic wants. It needs
three things:

 1. `video::SColor`, Irrlicht's colour, which no shim has yet.
 2. `core::clamp`, one line beside the vectors.
 3. A name collision: this shim's `itos` and `ftos` against buildat's own
    in core/types.h. Rename the shim's, or leave them out -- the mapgen
    uses `itos` twice.

And one trap to know about: a header reached by two different paths --
"util/string.h" and "util/util/../string.h" -- is included twice because
`#pragma once` compares paths. The forwarding headers under util/util/ are
what make that happen, so anything they reach needs an include guard rather
than a pragma.

After serialize comes mg_schematic's own two: `compress`/`decompress`,
which buildat has as interface::compress_zlib, and MapNode::serializeBulk,
which lives in Luanti's mapnode.cpp and is not vendored -- mapnode.h here
is a shim.

Shims, written here:

    irrlichttypes.h, irrlichttypes_bloated.h, irr_v3d.h, irr_v2d.h
    map.h, mapblock.h, emerge.h, gamedef.h, server.h, profiler.h,
    settings.h, voxelalgorithms.h
    util/string.h, util/numeric.h, util/container.h, util/config.h,
    util/directiontables.h
    mapgen/*.h and util/util/*.h, which only forward to the file beside
    them: a vendored file that includes "mapgen/mapgen.h" or
    "util/string.h" has to find something, and a runtime-compiled module
    gets no include directories of its own
    irrlicht_changes/printing.h
    mapnode.h
    nodedef.h, nodedef.cpp
    constants.h
    exceptions.h
    debug.h
    log.h, log.cpp
    porting.h
    util/basic_macros.h

A file that is Luanti's must stay Luanti's: if something does not compile,
the shim is what changes.
