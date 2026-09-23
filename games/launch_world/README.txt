launch_world
============

An alternative launch UX: the room you start in. The client starts in a
small hand-authored room and walks out of it into a game -- the games are
warm orbs wedged in niches, the servers are a patch bay, every readout is
a real light source and nothing is on a HUD. An *alternative* to
launch_menu, never a replacement, and its point is the opposite of a
feature tour: a showcase of how much a buildat program can leave out.
There is no mapgen, no streaming, no sky, no day or night, no entities
and no persistence -- the room is generated from a table every boot and
nothing is saved.

The design, the reference frame it is built against and the reasoning
behind every number here are in doc/plan/launcher_plan.md under
[LAUNCH_WORLD]. This file is how to run it and what the keys do.

Running it
----------

    Build/bin/buildat_server -m ../games/launch_world -D ../user -P 29795
    Build/bin/buildat -s localhost:29795

or the whole check, which drives it and reads the frames:

    games/launch_world/check.sh

Keys
----

    (type)      any letter opens a one-line prompt that fuzzy-matches a
                game or a server by name; the match is shown as you type
    Return      launch what the prompt matched: the bay comes apart and
                the camera flies in
    1-6         pick a slot without typing
    Escape      leave: fly back to the standing place, shut every bay,
                stand up from the terminal
    F1-F4       the four palette presets ([LAUNCH_WORLD]'s own
                experiment; the pick is the user's, and check.sh leaves
                all four in one picture at
                local/options_for_LAUNCH_WORLD/presets_sheet.png)
    F5          the reflection probe off and on
    F6          the generated ornament off and on
    F7          freeze the idle drift, which is what the checks need
    F8          start the attract mode at once

Type "set" and press Return to sit at the terminal.

Environment
-----------

    BUILDAT_LAUNCH_TONEMAP   which of Urho3D's post-process effects to
                             append, comma separated. "Tonemap" by
                             default; "" for none
    BUILDAT_LAUNCH_BIAS      the tonemap's exposure bias (1.05)
    BUILDAT_LAUNCH_WHITE     its white point (1.8)
    BUILDAT_LAUNCH_HDR       turn HDR rendering on. **It draws only the
                             unlit materials** -- see the plan
    BUILDAT_LAUNCH_SUN       add a directional light, which is how that
                             was shown not to be about light types
    BUILDAT_LAUNCH_ATTRACT   seconds of quiet before the attract mode
                             starts (14)
    BUILDAT_LAUNCH_OWNSCENE  draw a scene of this client's own making
                             rather than the replicated one -- no voxels
                             in it; a diagnostic for the HDR question
    BUILDAT_LAUNCH_NOPBR     put the stock non-PBR techniques on the
                             primitives; with HDR on, this is what
                             lights when the PBR ones do not

What is where
-------------

    main/main.cpp            the room: a worldgen generator over a table
                             of numbers, at 45 cm a voxel. The floor's
                             checkerboard, the mass the room is cut out
                             of, the six bays and the niches behind them
                             all come out of voxel_at(), which the
                             generator and the dissolve's restore both
                             read -- so the room is described once
    client_lua/init.lua      everything the client draws and does
    client_lua/ornament.lua  the recursive ornament generator: a meander,
                             a socket field, an orb's mark and a server's
                             sigil, each a height field and an inlay mask
                             with the albedo and normal derived from them
    client_lua/synth.lua     the room's sound, synthesised, no assets
    make_client_data.py      the voxel tiles, four flat 16x16 PNGs

What the checks assert
----------------------

check.sh drives one client through the room and reads the frames. Each
line is a thing that has been seen to fail:

    the four presets are four pictures     -- the palette actually moves
    the probe reaches the metals           -- a metal sees the room
    a bay opens and closes again           -- and comes back to 0.00
    typing a name flies the camera in      -- and Escape flies it out
    the terminal is flat, dark and readable
    nothing in the room is static          -- the era's own rule
    the room shows itself off when left alone
    the generated ornament is on something -- it once was not

Two of them exist because a feature drew nothing for a day while its own
log line said otherwise, and two more were passing on the HUD's text
rather than on what they named. The comparisons take the frame above the
bottom strip for that reason, and the runner fails on a crash rather
than reading the pictures the run before left behind.

Known, and not this room's to fix
---------------------------------

**Urho3D's stock PBR techniques do not light under HDR in this build.**
With BUILDAT_LAUNCH_HDR=1 the orbs and the readout draw and everything
lit by a light does not, whatever the light type -- but add
BUILDAT_LAUNCH_NOPBR=1, which swaps the primitives onto the stock
non-PBR techniques, and the same scene with the same effects lights
(blown out, since the lights are tuned for PBR's scale). games/voxel_lighting renders in HDR with the
same three effects appended in the same order. Ruled out so far: the
effects and their order, their curve parameters, the light type,
set_preferred_viewports (the renderer's own viewport draws the same
black) and the order of registering the viewport against setting
HDRRendering -- voxel_lighting registers first and so does this now,
with no change. Until then the room is tonemapped in LDR, which
costs it the top of its range: against the reference frame's mean 67,
median 38, 90th 171, 99th 252 and 0.31 per cent pure white, it reads
60 / 38 / 173 / 175 / 0.00.

**Generated ornament cannot reach a voxel.** A voxel's tile is loaded by
resource name out of Urho3D's ResourceCache, and AddManualResource is not
in Urho3D's Lua bindings at all. So the meander and the socket field are
on primitives standing proud of the voxel wall, and the voxel tiles are
flat colours. Binding that call is small, and a sandbox policy question:
a script that can name any resource can shadow one.
