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
The mesher turns the skylight of the voxel in front of each face into a vertex
color, and chunk geometry is drawn with PBRDiffVCol, a PBR technique in
client/data/Techniques. The scene is rendered in HDR and tonemapped.

The vertex color multiplies the zone's ambient color, which is a blue sky
bounce. Because it fades towards a warm tint rather than towards black, a face
that has lost most of its skylight ends up neutral grey, like light bounced off
rock, while a merely shaded outdoor face stays blue. That is what makes a cave
look different from a tree's shadow.

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

Running
-------

    $ bin/buildat_server -m ../games/voxel_lighting
    $ bin/buildat_client -s localhost

check.txt visits all three benchmarks and screenshots each, for comparing a
rendering change against the previous run:

    $ bin/buildat_client -s localhost -c @../games/voxel_lighting/check.txt

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
