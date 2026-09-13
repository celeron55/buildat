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

    voxel.h, voxel.cpp

Shims, written here:

    irrlichttypes.h, irrlichttypes_bloated.h, irr_v3d.h, irr_v2d.h
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
