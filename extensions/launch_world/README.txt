launch_world
============

An alternative launch UX: the room you start in. The client starts in a
small hand-authored room and walks out of it into a game -- the games are
warm orbs wedged in niches, the servers are mirrors on the floor, every
readout is a real light source and nothing is on a HUD. An *alternative*
to launch_menu, never a replacement, and its point is the opposite of a
feature tour: a showcase of how much a buildat program can leave out.
There is no server, no mapgen, no streaming, no sky, no day or night and
no entities -- the room is generated from a table every boot. The one
thing it does keep is what the player changed: the voxels they placed,
the spheres they moved, the field of view and the sound levels, as a
diff against the generated room.

The design, the reference frame it is built against and the reasoning
behind every number here are in doc/plan/launcher_plan.md under
[LAUNCH_WORLD]. This file is how to run it and what the keys do.

Running it
----------

    Build/bin/buildat -m launch_world

or the whole check, which drives it and reads the frames:

    extensions/launch_world/check.sh

and, for judging the exposure by looking rather than by argument, a
sheet of the room across the light from above and the tonemap's white
point, with the probe box standing in it:

    extensions/launch_world/probe_sheet.sh

and the two options rounds that are waiting on somebody's eye -- the
orb's mark, and the floor's value and finish:

    extensions/launch_world/mark_sheet.sh
    extensions/launch_world/floor_sheet.sh

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
    right click place one of your own voxels against what you point at
    left hold   on one of your own voxels, prise it out: it lifts for a
                second and then breaks into dust. On a sphere, it lifts
                toward you and launches at a second. The room's own
                stone wears no wireframe and cannot be dug -- no
                pointing indication means no interaction
    E           pick the sphere you are pointing at up; any number, one
                mixed stack, held in the right of the view
    right click place the top of the stack, or a voxel when it is empty
    arrows      turn, for a player without a mouse
    Return      the terminal, and back out of it
    Backspace   the same -- one way out that always works

Menu mode:

    arrows      browse the room: along the wall, then the floor's ranks
    Return      take what is browsed -- or, with text in the prompt,
                what it matched: the bay comes apart and the camera
                flies in
    (type)      any letter opens a one-line prompt that fuzzy-matches a
                game, a launch action or a save by name
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

Type "set" and press Return to sit at the terminal -- or, in FPS mode,
press Return anywhere. At the desk, up and down walk the rows and left
and right change them: the client's own preferences, then the room's
own -- the palette, the reflection probe, the field of view, and the
levels of the orbs and of the bed under them, which is where the sound
is meant to be tuned by ear. The room's rows are kept in its own save,
not in the client's preferences, because they are its taste rather than
the client's. Escape stands up.

Environment
-----------

    BUILDAT_LAUNCH_TONEMAP   which of Urho3D's post-process effects to
                             append, comma separated. "Tonemap" by
                             default; "" for none
    BUILDAT_LAUNCH_BIAS      the tonemap's exposure bias (1.05)
    BUILDAT_LAUNCH_WHITE     its white point -- where the curve reaches
                             255
    BUILDAT_LAUNCH_NOHDR     go back to LDR rendering. HDR is on: a
                             renderer that clips every radiance at 1.0
                             before the tonemap measures a clamp rather
                             than light
    BUILDAT_LAUNCH_SUN       add a directional light
    BUILDAT_LAUNCH_SKY       how bright the cold light from above is
                             (1.6), and BUILDAT_LAUNCH_ORB the orbs
    BUILDAT_LAUNCH_NOSHADOW  the lights without their shadow maps
    BUILDAT_LAUNCH_PROBEBOX  stand a probe box of known albedos in the
                             room: 90, 50, 18 and 4 per cent grey and
                             the orb's own orange
    BUILDAT_LAUNCH_PROBE8    an eight-bit reflection probe instead of
                             the float16 one, which is what the two were
                             compared with ([PBR_HDR])
    BUILDAT_LAUNCH_PROBEMIPS leave the probe's mip chain on. The
                             eight-bit probe then blurs its rough
                             surfaces correctly; the float16 one takes
                             every reflection black, which is what says
                             the chain is a format question and not a
                             missing call
    BUILDAT_LAUNCH_NORENDERPROBE
                             bind the probe's cube map without ever
                             rendering into it, which is how the two
                             halves of that fault were told apart
    BUILDAT_LAUNCH_MARK      A or B, the orb's mark: the icon in the
                             diffuse, or one bit in the roughness.
                             mark_sheet.sh draws both
    BUILDAT_LAUNCH_FLOOR_VALUE
                             scale the floor's light squares. They are
                             the brightest surface in the room and they
                             clip; floor_sheet.sh draws four values
    BUILDAT_LAUNCH_FLOOR_GLOSS
                             their roughness (0.07), lower being
                             glossier
    BUILDAT_LAUNCH_STAND     where the player stands, in metres from the
                             room's middle (8). Read together with the
                             field of view and nothing else
    BUILDAT_LAUNCH_POCKETS   hold the wall to fewer pockets than it
                             could take, which is how the spill onto the
                             floor is looked at on a tree with nine
                             games
    BUILDAT_LAUNCH_SAVES     how many saves stand on the floor (12). The
                             rest are still the prompt's to find, and
                             this is how that path is driven
    BUILDAT_LAUNCH_ATTRACT   seconds of quiet before the attract mode
                             starts (14)
    BUILDAT_LAUNCH_NOPBR     put the stock non-PBR techniques on the
                             primitives; with HDR on, this is what
                             lights when the PBR ones do not
    BUILDAT_SERVERLIST_URL   the serverlist extension's list, for a
                             check's own rather than the one this client
                             knows

What is where
-------------

    init.lua                 the entry the client calls to boot a menu
                             extension; it runs world.lua
    room.lua                 the room: voxel_at() over a table of
                             numbers, at 45 cm a voxel. The floor's
                             checkerboard, the mass the room is cut out
                             of, the wall's slabs and insets, the three other
                             walls and the pockets all come out of it, and the build
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
    placing and digging do something       -- and write the save
    E picks up and right click puts down
    the terminal changes a setting         -- and changes it back
    the arrows browse the room's own grid
    a second client reads the save back    -- voxels and a moved sphere
    a save opens by name                   -- the floor's, and one past
                                              the floor's cap
    ContentDB opens from the room          -- against a local mirror
    the orbs are sized within their kind   -- and none wears an empty
                                              mark
    a placed voxel wins over the orb       -- and an orb is pointed at
                                              anywhere up its column
    a sphere put down rests on the floor
    the floor's made-up servers say so     -- on a client with no
                                              history of its own
    every launch UI this tree ships boots  -- extensions/__menu/check.sh

What the player changed is a diff against the generated room, in
user/launch_world/room.txt: a voxel they placed is "x,y,z" on a line, a
sphere they moved is "@<name> x y z" -- by name rather than by index,
since installing a game changes the order of the list -- and the room's
own settings are "!fov <degrees>" and "!sound <orbs> <bed>". A file a
person can read and delete.

Two of them exist because a feature drew nothing for a day while its own
log line said otherwise, and two more were passing on the HUD's text
rather than on what they named. The comparisons take the frame above the
bottom strip for that reason, and the runner fails on a crash rather
than reading the pictures the run before left behind.

What was known and is not any more
---------------------------------

**A float16 cube map on a zone costing the frame its red and green with
HDR rendering on** was [PBR_HDR], and it is fixed: a render-target cube
is given the whole mip chain and only level 0 is ever written, so every
sample above it read memory nobody wrote -- a wrong colour in eight
bits and a NaN in float16, which the shader then added to the frame.
The probe asks for one level (`SetNumLevels(1)`, a method: Urho3D's
`levels` is read-only and the property write this file once described
went nowhere) and the voxel shader refuses a sample that is not a
number. The probe is float16 again, so a reflection carries radiance
instead of clipping.

**What one level costs**: a rough surface reflects as sharply as a
mirror. The chain is not a missing call -- Urho3D regenerates a render
target's levels by itself -- it is the format: this driver does not
generate them for a float16 cube. `BUILDAT_LAUNCH_PROBEMIPS=1` is how
that gets measured again.

**Urho3D's stock PBR techniques do light under HDR.** That was this
room's own earlier reading and it was wrong: what was dark was the
reflection probe above, and a PBR metal with no environment is black but
for its highlight whether the target is float or not -- which the LDR
run with the probe off shows just as well.
