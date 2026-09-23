launch_world
============

An alternative launch UX: the room you start in. The client starts in a
small hand-authored room and walks out of it into a game -- the games are
warm orbs wedged in niches, the servers are a patch bay, every readout is
a real light source and nothing is on a HUD. An *alternative* to
launch_menu, never a replacement, and its point is the opposite of a
feature tour: a showcase of how much a buildat program can leave out.
There is no server, no mapgen, no streaming, no sky, no day or night, no
entities and no persistence -- the room is generated from a table every
boot and nothing is saved.

The design, the reference frame it is built against and the reasoning
behind every number here are in doc/plan/launcher_plan.md under
[LAUNCH_WORLD]. This file is how to run it and what the keys do.

Running it
----------

    Build/bin/buildat -m launch_world

or the whole check, which drives it and reads the frames:

    extensions/launch_world/check.sh

**There is no server.** The room is an extension rather than a game
because the room *is* the launcher: starting a game is ctx.launch on the
trusted side, which a game's own sandbox cannot call. The voxels are
described in room.lua, built in Lua and meshed straight into a node
through buildat.safe.set_8bit_voxel_geometry. What that costs, and the
plan said it would: no voxelworld means no skylight flood and no baked
ambient occlusion, so the wall's relief rests entirely on the real
lights, and the dissolve is a rewrite of the block and a re-mesh.

Keys
----

It starts in FPS mode, where you walk; Tab goes to menu mode, where you
type. The mouse is captured in FPS and free in menu.

    Tab         swap the two modes

FPS mode:

    W A S D     walk, mouse looks
    Space       jump
    Return      the terminal, and back out of it
    Backspace   the same -- one way out that always works

Menu mode:

    (type)      any letter opens a one-line prompt that fuzzy-matches a
                game, a launch action or a save by name
    Return      launch what the prompt matched: the bay comes apart and
                the camera flies in
    1-9         pick a slot without typing

Both:

    Escape      the way back -- stand up from the terminal, shut a bay,
                fly to the standing place -- and, with nothing left to
                go back from, the pause dialog: back to the room, switch
                to the old menu, or leave buildat
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
    BUILDAT_LAUNCH_NOHDR     go back to LDR rendering. HDR is on: a
                             renderer that clips every radiance at 1.0
                             before the tonemap measures a clamp rather
                             than light
    BUILDAT_LAUNCH_SUN       add a directional light
    BUILDAT_LAUNCH_ATTRACT   seconds of quiet before the attract mode
                             starts (14)
    BUILDAT_LAUNCH_NOPBR     put the stock non-PBR techniques on the
                             primitives; with HDR on, this is what
                             lights when the PBR ones do not

What is where
-------------

    init.lua                 the entry the client calls to boot a menu
                             extension; it runs world.lua
    room.lua                 the room: voxel_at() over a table of
                             numbers, at 45 cm a voxel. The floor's
                             checkerboard, the mass the room is cut out
                             of, the wall's slabs and insets and the six
                             pockets all come out of it, and the build
                             and the dissolve's restore both read it --
                             so the room is described once. Run it with
                             lua for its own check
    world.lua                everything the client draws and does
    ornament.lua             the recursive ornament generator: a meander,
                             a socket field, an orb's mark and a server's
                             sigil, each a height field and an inlay mask
                             with the albedo and normal derived from them
    synth.lua                the room's sound, synthesised, no assets

Every texture in the room is generated at boot and registered into the
resource cache under generated/; nothing generated is committed.

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
    FPS mode walks                         -- it is the mode you land in
    Escape pauses and Escape comes back
    a source is brighter than a lit wall   -- the top end, in HDR
    the room found launch actions at all   -- not a list written here

Two of them exist because a feature drew nothing for a day while its own
log line said otherwise, and two more were passing on the HUD's text
rather than on what they named. The comparisons take the frame above the
bottom strip for that reason, and the runner fails on a crash rather
than reading the pictures the run before left behind.

Known, and not this room's to fix
---------------------------------

**A float16 cube map on a zone costs the frame its red and green with
HDR rendering on.** A pixel that reads 60 71 89 in LDR reads 0 0 111,
and one keypress separates the readings: F5 takes the probe off the zone
and the same HDR frame is correct. The same cube map in eight bits is
correct too, which is why the probe is RGBA8 here -- at the cost of an
emissive orb clipping where it is reflected. See [PBR_HDR].

**Urho3D's stock PBR techniques do light under HDR.** That was this
room's own earlier reading and it was wrong: what was dark was the
reflection probe above, and a PBR metal with no environment is black but
for its highlight whether the target is float or not -- which the LDR
run with the probe off shows just as well.
