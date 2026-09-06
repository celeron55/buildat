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
PBRVoxel, a technique and shader in the voxel_shading module, which puts them
on each chunk in voxelworld.sub_material_update(). The mesher sets no technique
of its own; interface/mesh.h lists what it does hand a voxel shader. Nothing in
voxel_shading needs a module's privileges, since a module has none a game
lacks; it is a module so that both lighting games can share it. The scene is
rendered in HDR and tonemapped.

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

Materials
---------

The same technique also does normal mapping and per-texel roughness, and
reflects an environment cube map. None of the maps are authored: the atlas
derives a normal map and a surface map from each texture as it packs it, from
six numbers a voxel gives with it (interface/atlas.h):

    roughness  how wide the highlight is; the mean over the texture, with
               brighter texels a little smoother and darker ones rougher
    spec_strength  how much of a highlight there is at all
    bumpiness  how much the texture's luminance is read as height
    translucency  how much light passes through from behind, at a spot
    spots      fraction of the surface that is a spot at any one moment
    static_spots  the same, for spots that hold still

The first two are separate because roughness alone cannot make a surface matte.
It sets how wide a highlight is, and everything here except water sits between
0.85 and 0.98, a band across which the difference is barely visible;
spec_strength is what says whether there is a highlight to widen. Rock and dirt
are at 0.15 of it, so they are dull all over, and the tree trunk at 0.35, since
bark is not that shiny. Spots ignore spec_strength and reflect at full
strength, which is the whole point of it: rock can be dull everywhere except at
its crystalline facets, which is not something a single roughness could say.

bumpiness is the other half of how busy a surface looks, and the one that is
easy to mistake for gloss. It breaks the light up across the texture, diffuse
as much as specular, so a surface with a high one reads as grainy whether or
not it reflects anything. Rock and dirt were at 2.0 and 2.5 and are now at 0.5
and 0.6; most of what looked like too much shine on them was this. Grass reads
as smooth however many shapes are in it, so its normals are kept low as well;
any more and it turns grainy at a distance.

Grass and leaves keep full spec_strength but get their gloss from their spots,
because a leaf catching the light is a leaf that has turned and a bright texel
sits still. Water is the one surface here shiny enough for its texture's own
roughness to show, and has spots on top of that.

Metalness is not among the numbers. Nothing in this world has been metal, so it
is the material's own constant rather than a per-texel channel, and that channel
carries spec_strength instead.

Spots come in two kinds, and both are worked out from the world position
rather than stored in a map. That is the answer to the maps repeating: a map
lives in one voxel face, so anything in it appears again every voxel, which a
speckle must not do. Making the maps span 4x4 voxels instead would mean the
mesher writing texture coordinates that run across faces, and it still only
moves the repeat further out; a function of the world position has no period at
all. STATIC_SPOT_CELLS and TRANSMISSION_CELLS in PBRVoxel.glsl set how big the
two kinds are, in cells per voxel.

The still kind is on or off with no fade and holds one tilt across its cell, so
it reads as a flat facet with an edge. The moving kind fades in and out. Which
one a material gets is a separate fraction, and a material can have neither.

A spot is one thing with three effects, from one mask: the surface there is
turned away from the face it is on, is glossier than its roughness map says,
and passes translucency. They are the same event seen three ways, and which of
them shows is settled by the geometry, since transmission only appears with the
light behind the surface and a highlight only with it in front.

The turn is what does most of the work. Gloss on its own only shows where the
thing being reflected has contrast in it, and outside the sun disc this cube
map is a smooth gradient, so a sharper reflection of it looks no different from
a blurred one. Turning the normal moves the direct sunlight's
own highlight instead, which is the bright thing in the scene, and that is what
stands in for the animated normal map the water has not got. The turn is taken
across the surface rather than in any direction: a free direction tips some
normals past the horizon, and those reflect the ground half of the cube map as
brown specks on the water.

Grass has the same spots as leaves. Transmission is bright, being the sun
rather than the sky, and grass is usually near the camera, so its specks are
both large and clipped: a blown-out speck is what a gap in a backlit surface
looks like, and dialling the amount down until it stops clipping only makes it
a dull mottle. What is worth keeping down is how many there are, not how bright
each one is.

Leaves are also the one translucent thing here. A backlit leaf gets no direct
sun on the side facing the camera, so without it the only thing lighting the
side you see is the sky, and a canopy against the sun comes out blue. What
makes it warm instead is light coming through the leaf, which is a transmission
term rather than anything to do with reflections: tinting the cube map towards
the sun would not reach it, because in that geometry the surface reflects the
sky behind the camera, away from the sun.

It is a few specks rather than a whole face. A face at a time is a lamp, not a
tree; light gets through a canopy where a leaf happens to have a gap behind it.
Where that is, is not something the leaf texture knows, and it does not hold
still either: in any wind it is a different leaf a moment later. So the spots
are not stored anywhere. The shader dices the world into cells a sixteenth of a
voxel across, gives each one its own cycle from a hash of its position, and
makes it a spot for the material's fraction of that cycle; a slow ramp along
the wind direction is added to the phase, so they cross the surface in gusts
rather than twinkling evenly. The map carries only how much light gets through
and how much of the surface is a spot at once.

The cycle is worked in its own 0..1 position rather than in the height of a
wave. Near the top of a sine the wave is almost flat, so a threshold that fully
opens 4 per cent of cells leaves another 10 per cent hovering just under it,
and the surface hazes over instead of speckling.

What comes through keeps only part of the surface's color. Taking the albedo
raw would apply the leaf's green a second time and the spots would come out as
saturated as the texture; the shader mixes it most of the way to white, since a
gap passes the sun unchanged. TRANSMISSION_TINT in PBRVoxel.glsl is that mix.

What it reflects is the zone's cube map, voxel_shading/VoxelSky.xml,
generated by
make_client_data.py in the same brightness range as the zone's ambient color:
the same sky, seen in a mirror rather than diffusely. It has a sun disc in it,
a few degrees across rather than the half degree the real one is, because at 64
pixels a face a half-degree disc is smaller than a texel. The disc is what
gives a glossy surface something with contrast in it to reflect. The
directional light draws the sun's highlight as well, so a surface facing it
right gets both; the disc is left at the top of the 8 bit range rather than
made an HDR value, so that neither swamps the other.

The same sky is also drawn, by VoxelSkybox.glsl on a skybox, in the gradient
the cube map is baked in so that what a surface reflects agrees with what is
overhead. It has a square sun rather than a disc, since everything else here
is cubic, and a layer of noise clouds projected onto the sky by direction. A
skybox has no depth presence, so neither is ever in the way of the ground.

The clouds are the one place the drawn sky and the reflected one knowingly
disagree: they are not in the cube map, so nothing reflects them. Below the
horizon the drawn sky is a neutral haze rather than the cube map's ground
color, since the only time it shows is past the edge of the world.

There are two cube maps. voxel_shading/VoxelSkyIndoor.xml is the same sky
dimmed, with
no sun disc and no glow, going to a flat grey both above and below a brighter
band at the horizon: indoors the bright thing around you is the windows, and
what is over and under you is whatever the room is made of, which cannot be
known when the map is generated. The shader fades between the two by
IndoorBlend, which the client sets each frame from the skylight of the voxel the
camera is in, eased so that crossing a voxel boundary does not step. Digging the
shaft with P lets skylight into the cave and takes the blend back to the outdoor
map, which is the easiest way to see it work.

Only which map is reflected changes; the skylight scaling below applies to
either. That keeps the feature from brightening the cave, and it is also why it
is subtle there: a surface that sees no sky has almost no reflection to
recolour. Where it shows is the middle ground the indoor map is named for, a
surface that sees some sky while the camera sees none.

Only the specular half of image based lighting is taken. The diffuse half
would be an unoccluded sky added to every surface, which would light the
inside of the cave; the skylight in the vertex color is this scene's ambient
diffuse and it already knows where the sky can be seen from. The specular term
is scaled by that same skylight for the same reason, so the cave reflects
nothing.

A world that sets no zone cube map gets black reflections and is otherwise
unaffected.

Benchmarks
----------

Six fixed camera placements, on the HUD buttons at the top right and on keys
1 to 6. Each is there for something specific, so a rendering change can be
judged against the previous run's images one feature at a time:

  # Name            Frames                      What it is there for
  - --------------  --------------------------  --------------------------
  1 Overview        the whole volume from the   the scene as a whole; the
                    high +X +Y +Z corner        shape of the terrain and
                                                where everything else is
  2 Cave mouth      the cave axis from          skylight falling off into an
                    outside, looking in         opening, and the shape of the
                                                mouth against lit ground
  3 Inside cave     the cave axis from inside,  skylight at its darkest: rock
                    looking back out            that sees no sky at all
                                                around a blown-out opening.
                                                The main one for relighting;
                                                the shaft and slab edits are
                                                shot from here
  4 Pond            across the water from over  the environment cube map. A
                    its far rim                 reflection is strongest at a
                                                grazing angle, and leaves,
                                                grass and dirt are in the
                                                same frame for contrast
  5 Backlit canopy  a tree from back and above  the canopy's directly lit top
                    it, sun behind and above    face against its shaded side,
                                                in one frame
  6 Sun behind      the same tree from below,   light through the leaves at
                    looking up at the sun       its strongest: the leaves
                    through it                  facing the camera have the
                                                sun square behind them. Also
                                                the grass on the terrain
                                                either side

Reading them, 3 is the one that matters for skylight and relighting, 4 to 6
are the ones for materials.

Light through leaves is animated off the scene's clock, so a shot of it comes
out differently every run. F (or the last HUD button) holds the clock at
FROZEN_TIME, and check.txt presses it before it shoots anything. It is a toggle
rather than something the benchmark cameras do by themselves: moving between
cameras should not stop the scene animating, and a frozen scene that nothing
said it had frozen is a confusing thing to land in.

The pond is dug rather than found. This terrain is one slope, so a water line
drawn across it fills the low ground at the edge of the volume and reads as a
sea the world runs out of; a basin dug into the flattest ground away from the
cave reads as a pond. POND_CENTRE_X, POND_CENTRE_Z, POND_RADIUS, POND_DEPTH
and WATER_LEVEL in main.cpp were picked off the surface heights the generator
reports, in the same way as GROUND_OFFSET and TERRAIN_AMPLITUDE.

5 and 6 are two framings of the same tree, the one nearest the middle of the
volume. The sun is high, so they cannot be the same camera: standing back from
a tree far enough to see its top means the sun is above it rather than behind
it, and putting a canopy between the camera and the sun means standing under
the tree and looking up.

Tab (or the top HUD button) toggles free move: WASD on the horizontal plane
whatever the camera is pitched at, Space up, Shift down, mouse to look.

Editing
-------

F freezes and unfreezes the wind, whatever mode the camera is in.

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

Running
-------

    $ bin/buildat_server -m ../games/voxel_lighting
    $ bin/buildat_client -s localhost

check.txt visits all six benchmarks and screenshots each, for comparing a
rendering change against the previous run:

    $ bin/buildat_client -s localhost -w 1600x900 \
            -c @../games/voxel_lighting/check.txt

-w gives the run a fixed window size without changing the remembered one, so
the images come out the same size whatever the window was left at last time.
It also shoots both benchmark edits, so a run is: all six views of the scene
as generated, then three of them after the shaft and after the slab.

NOTE: the server reads client_lua and client_data once at startup, so restart
it after editing init.lua, the shader or a cube map, or the client will be
served the previous version. That goes for the voxel_shading module's files as
much as for this game's own.

Tuning
------

The generator logs the noise range and the surface range it produced, and the
cave mouth it chose. GROUND_OFFSET and TERRAIN_AMPLITUDE in main.cpp are set
by reading that, not derived at runtime, so the scene stays put between
changes. The tree seed was picked by eye to keep the cave mouth clear.

Where the cave ended up is sent to the client in main:cave, where benchmark 4's
camera goes in main:water, and which tree benchmarks 5 and 6 look at in main:tree, so
none of those can drift out of sync with what was generated. Benchmark 4's
camera is worked out on the server rather than the client because it needs the
terrain height around the pond to stay above ground; benchmarks 5 and 6 are
worked out on the client because they need the sun direction, which lives
there. VIEW_DIR is the one thing still
duplicated between main.cpp and client_lua/init.lua, and has to be changed in
both: the server carves along it and benchmark 1 looks along it.
