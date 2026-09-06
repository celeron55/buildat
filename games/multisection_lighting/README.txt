multisection_lighting
=====================

voxel_lighting's scene, in a world of eight voxel sections instead of one, so
that everything it checks has to work across section boundaries. Not a game:
there is no player, no physics and no world streaming, so that a change to the
rendering can be judged from framings that are identical between runs.

The world is 128x128x128 voxels in 2x2x2 sections, which puts three boundary
planes through it, at x=64, y=64 and z=64. The terrain is generated over all
of it with digger's generator, as in voxel_lighting.

Sections
--------

voxel_lighting's scene is placed at SCENE_OFFSET in main.cpp rather than
rebuilt, so the terrain under the cave, the cave itself and the two benchmark
edits are the ones that game already framed. The offset is what decides where
the boundaries fall through it, and it puts them at scene x=57, y=29 and z=28.

The cave crosses those at roughly a fortieth, an eighth and three quarters of
its length: one boundary two voxels inside the mouth, where the light gradient
is steepest; one just under the surface there; and one far down the tunnel
where there is almost no light left. The cave runs through four sections that
way, and the benchmark shaft crosses the horizontal plane with five voxels
below it and six above.

Putting the mouth on the corner where all eight sections meet looks like the
hardest arrangement and is not. The cave leaves through one octant immediately
and then spends three quarters of its length inside a single section, which is
the case that was already working.

The terrain keeps going past the 64 voxel scene to fill the rest of the world.
That is the whole visible difference between the two games: the same view of
the same cave, with terrain running off the edges of the frame instead of a
floating block. The trees do not land where voxel_lighting puts them, because
they are placed per cell of a grid over the world rather than by a count per
section, which is what makes one growing over a boundary come out whole from
both sides.

Lighting
--------

The server flood fills a 4 bit skylight value into every voxel: full straight
down through air, losing one step per voxel as it spreads sideways and deeper.
The mesher packs that into vertex colors, and chunk geometry is drawn with
PBRVoxel, a technique and shader in client/data. The scene is rendered in HDR
and tonemapped.

The vertex color carries how much sky a surface sees in its alpha and the
light bounced off nearby surfaces in its rgb, and the shader adds them:

    ambient = zone ambient * color.a + color.rgb

so a face that can see the sky gets the zone's blue and one that cannot gets
the near-neutral grey of bounced light. That is what makes a cave look
different from a tree's shadow. Direct sunlight is left out of it, being
shadow mapped already.

Folded into both terms are per-vertex ambient occlusion, from how many of the
three voxels around each quad corner are solid, and a fixed per-face
brightness (top brightest, bottom darkest, the four sides spread either side
of the middle). The latter is for legibility rather than physics: without it,
two faces of a voxel in shadow receive the same light and the edge between
them disappears.

Skylight is opt-in per world: voxelworld.use_skylight, off by default. A world
that does not fill the bits, and any dynamic voxel node meshed by a game
itself, keeps the plain Diff technique and full brightness.

Benchmarks
----------

Three fixed camera placements, on the HUD buttons at the top right and on
keys 1, 2 and 3:

    1 Overview      outside the high +X +Y +Z corner, down the diagonal
    2 Cave mouth    on the cave axis outside it, looking in
    3 Inside cave   on the cave axis inside it, looking back out

3 is the one that matters most: dark rock around a blown-out opening.

Tab (or the top HUD button) toggles free move: WASD on the horizontal plane
whatever the camera is pitched at, Space up, Shift down, mouse to look.

Editing
-------

In free move, left mouse digs the pointed voxel and right mouse places rock
next to it. P and O (or the last two HUD buttons) make the two fixed edits used
for comparing images.

P digs a 3x3 shaft straight up out of the cave to the open air, starting far
enough in that the skylight there was 0. That is the strong test: a whole part
of the scene that had no skylight at all has to come up to daylight, and
benchmark 3 goes from near-black rock to a lit cave.

O caps the shaft with a 5x2x5 slab filling the two air voxels above the ground,
which takes back the light the shaft let in: benchmark 3 returns to the dark it
started at. The shaft reaches through the cap, so digging again cuts it back
out and the two can be alternated for as long as anyone wants to watch them.

Relighting is voxelworld's, not this game's: it is turned on with
set_skylight_enabled(true) and from then on every set_voxel keeps the light up
to date, generation included. An edit costs well under a millisecond
here, and what it costs depends on how far the light moves rather than on how
big the world is. Lighting the whole section at generation costs 40 ms.

V (or the last HUD button) checks that: it runs a skylight flood fill from
scratch over the whole scene and compares it voxel by voxel against what
voxelworld stored, logging either "skylight verify: ok" or the number of voxels
that differ and the first one. check.txt runs it after generation and after
every edit, so a run says outright whether the incremental relight got the same
answer as doing it all again.

Materials are voxel_lighting's, minus the pond: the same per-voxel roughness,
bumpiness, gloss and transmission, and the same zone cube map, so a rendering
change can be compared between the two scenes. See voxel_lighting's README for
what those mean. The benchmark cameras here are only its first three, the ones
for skylight; the ones it added for materials (the pond and the two of a
canopy against the sun) are not repeated.

Running
-------

    $ bin/buildat_server -m ../games/multisection_lighting
    $ bin/buildat_client -s localhost

check.txt visits all three benchmarks and screenshots each, for comparing a
rendering change against the previous run:

    $ bin/buildat_client -s localhost -w 1600x900 \
            -c @../games/multisection_lighting/check.txt

-w gives the run a fixed window size without changing the remembered one, so
the images come out the same size whatever the window was left at last time.
It also shoots both benchmark edits, so a run is: all three views of the scene
as generated, then the same three after the shaft and after the slab.

NOTE: the server reads client_lua and client_data once at startup, so restart
it after editing init.lua or the client will be served the previous version.

Tuning
------

The generator logs the noise range and the surface range it produced, and the
cave mouth it chose. GROUND_OFFSET and TERRAIN_AMPLITUDE in main.cpp are set
by reading that, not derived at runtime, so the scene stays put between
changes. The tree seed was picked by eye to keep the cave mouth clear.

Where the cave ended up is sent to the client in main:cave, so benchmarks 2
and 3 cannot drift out of sync with the carve. VIEW_DIR is the one thing still
duplicated between main.cpp and client_lua/init.lua, and has to be changed in
both: the server carves along it and benchmark 1 looks along it.
