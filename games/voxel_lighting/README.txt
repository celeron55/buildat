voxel_lighting
==============

A static voxel scene for working on voxel lighting. Not a game: there is no
player, no physics and no world streaming, so that a change to the rendering
can be judged from framings that are identical between runs.

One 64x64x64 section is generated with digger's terrain generator, with the
octaves below a wavelength of 64 kept and the amplitude cut to suit a volume
this size. A cave is carved into it with a sphere swept along the camera's
view direction, yawed 20 degrees so it does not run straight away from the
camera.

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
started at. The two edits change a similar number of voxels in opposite
directions, so they check the relight both ways.

Every edit relights the whole scene: the skylight flood fill is run again over
all of it and only the voxels whose skylight actually changed are written back,
so only the chunks the light really moved in are remeshed. That costs about
130 ms for this 64^3 scene, which is fine for one section and would not be for
a streaming world; an incremental relight, unlighting outwards from the changed
voxels and refilling, is what that would need.

Running
-------

    $ bin/buildat_server -m ../games/voxel_lighting
    $ bin/buildat_client -s localhost

check.txt visits all three benchmarks and screenshots each, for comparing a
rendering change against the previous run:

    $ bin/buildat_client -s localhost -w 1600x900 \
            -c @../games/voxel_lighting/check.txt

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
