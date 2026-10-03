launch_world
============

The room you start in. The client starts in a small hand-authored room
and walks out of it into a game -- the games are warm orbs wedged in
niches, the servers are mirrors on the floor, every readout is a real
light source and nothing is on a HUD. It is to be the default launch
mode once it is polished enough, with launch_menu kept for the audience
that wants a list; and it is a showcase of what a buildat program can
be, not of how little one can be. There is no server, no mapgen, no streaming, no sky, no day or night and
no entities -- the room is generated from a table every boot. What it
keeps is the player's bookmarks row and its sound levels.

The reference the room is held to -- every element, interaction,
transition, look and sound, and where the room differs from it -- is
doc/plan/launch_world.md; how it was argued and everything tried on the
way is doc/plan/launch_world_history.md. This file is how to run it and
what the keys do.

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

One mode: point-and-click with full keyboard support, the mouse always
free ([LAUNCH_WORLD] section 11).

    Tab         the next station: the wall, the floor, the desk
    click       on a sphere, launch it
    arrows      browse the room: along the wall, then the floor's ranks
    Return      take what is browsed -- or, with text in the prompt,
                what it matched: the bay comes apart and the camera
                flies in
    (type)      any letter opens a one-line prompt that fuzzy-matches a
                game, a launch action or a save by name; Backspace edits
                it and nothing else
    B           pin what is browsed to the bookmarks row, or unpin it
    Escape      closes what is open -- the desk, a bay, the prompt --
                and with nothing open the pause dialog: Continue,
                Settings (the desk), 2D menu, the developer console,
                Exit Buildat

The F keys are the client's (F5 the debug line, F6 the profiler, F12 a
screenshot). The room's own switches are for runs: BUILDAT_LAUNCH_PRESET,
BUILDAT_LAUNCH_NO_PROBE, BUILDAT_LAUNCH_NO_ORNAMENT and
BUILDAT_LAUNCH_STILL at boot, and in a command sequence
`event room probe|ornament|still|attract`, `event room preset <n>` and
`event room station wall|floor|terminal`. The attract mode starts after
fourteen seconds of quiet.

Type "set" and press Return, or Tab to the desk, to sit at the terminal.
At the desk, up and down walk the rows and left and right change them:
the client's own preferences, then the room's own -- the palette, the
reflection probe, and the levels of the orbs and of the bed under them,
which is where the sound is meant to be tuned by ear. The levels are
kept in the room's own save, not in the client's preferences, because
they are its taste rather than the client's. Escape stands up.

Environment
-----------

    BUILDAT_LAUNCH_TONEMAP   which of Urho3D's post-process effects to
                             append, comma separated. "Tonemap" by
                             default; "" for none
    BUILDAT_LAUNCH_BIAS      the tonemap's exposure bias (1.15)
    BUILDAT_LAUNCH_WHITE     its white point -- where the curve reaches
                             255
    BUILDAT_LAUNCH_NOHDR     go back to LDR rendering. HDR is on: a
                             renderer that clips every radiance at 1.0
                             before the tonemap measures a clamp rather
                             than light
    BUILDAT_LAUNCH_SUN       add a directional light
    BUILDAT_LAUNCH_SKY       how bright the cold light from above is
                             (2.2), and BUILDAT_LAUNCH_ORB the orbs (16)
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
                             their roughness (0.04), lower being
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
    BUILDAT_LAUNCH_ATTRACT_WALL_S
                             how long the attract sweep spends showing
                             one wall before it turns to the next (14).
                             The pockets fill the faced wall first and
                             reach round as the tree grows, and this is
                             the sweep that shows them
    BUILDAT_LAUNCH_PITCH     the spacing between pockets along a wall,
                             in voxels (6). A wide pitch gives each wall
                             fewer, which is how the other three are
                             reached with the games this tree has
    BUILDAT_LAUNCH_GLOW_CUT  what survives under the mark on a glowing
                             orb, as the fraction of its emissive (0.04,
                             picked off the [GLOW_MARK] sheet). The
                             emissive is multiplied by 26, so the band
                             a mark can read in is one over that, and
                             0 is a hole in the light
    BUILDAT_LAUNCH_MARK_FIGURE
                             "outline" draws the mark's boundary rather
                             than the mask
    BUILDAT_LAUNCH_HOP       how far back the search's hop stops, in
                             metres (4.5). Two is a portrait distance,
                             which is what the mark sheets use
    BUILDAT_LAUNCH_HOP_FLAT  take that hop straight on instead of from
                             above. Close in, a rising camera leaves a
                             pocket's own corridor for the slab beside
                             it; the room's own hop keeps the rise,
                             which is what reads as "here is where it
                             lives"
    BUILDAT_LAUNCH_FACE_YAW  the quarter turn between "-Z at the viewer"
                             and "the middle of the UV map at the
                             viewer", for measuring it again
    BUILDAT_LAUNCH_BARE      leave the floor empty: the wall, its
                             pockets and nothing else
    BUILDAT_LAUNCH_WHITE_V   the white sphere's value
    BUILDAT_LAUNCH_FLOOR_SPEC
                             the floor's specular level (1.0)
    BUILDAT_MARK_OUT         mark_sheet.sh shoots into another
                             directory, so a re-shoot does not write
                             over a sheet somebody is still looking at
    BUILDAT_LAUNCH_NOPBR     put the stock non-PBR techniques on the
                             primitives; with HDR on, this is what
                             lights when the PBR ones do not
    BUILDAT_SERVERLIST_URL   the serverlist extension's list, for a
                             check's own rather than the one this client
                             knows

What is where
-------------

    core.sh                  the check an edit runs: one client, about
                             a minute -- the room boots, draws,
                             moves between stations, launches a game
                             and comes back, and
                             the log is read for a sandbox error.
                             check.sh is the whole of it and is what a
                             push runs ([CHECK_COST])
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
    ornament.lua             the ornament generator: a band style per
                             seed (a sigil, a worm or a worm with the
                             hand flipped) drawn voxel by voxel along a
                             frieze or a column, the wall's cut-block
                             inlay, and a name-seeded mark for anything
                             with no icon -- each a height field and an
                             inlay mask with the albedo and normal
                             derived from them
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
    Tab moves between the stations
    Escape pauses and Escape comes back
    a source is brighter than a lit wall   -- the top end, in HDR
    the room found launch actions at all   -- not a list written here
    the terminal changes a setting         -- and changes it back
    the arrows browse the room's own grid
    a save opens by name                   -- the floor's, and one past
                                              the floor's cap
    ContentDB opens from the room          -- against a local mirror
    the orbs are sized within their kind   -- and none wears an empty
                                              mark
    the floor's made-up servers say so     -- on a client with no
                                              history of its own
    every launch UI this tree ships boots  -- extensions/launch_menu/check.sh

The room's save is user/launch_world/room.txt: the bookmarks row,
"!bookmark <key>" a line, and the levels, "!sound_db <orbs> <bed>". A
file a person can read and delete. Placed voxels, moved spheres and the
field of view, which the proof saved, are read past and not written.

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
