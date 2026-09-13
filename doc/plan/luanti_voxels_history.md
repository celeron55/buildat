# History: the finished work of the Luanti client plan

What is done, moved out of `doc/plan/luanti_voxels_plan.md` so that the plan holds
only what is still open. Nothing here is a to-do: every piece of it is
committed on the `luanti-client` branch, and the commit hashes in the text are
where to read the actual diff.

Kept because the *reasoning* is worth more than the diff -- why a thing was
built the way it was, what was measured, which blind alleys were walked and
what the tests that caught a mistake were checking. A later change to any of
this starts by reading the entry for it.

In the order the plan had them, which is roughly the order they were done.
A piece of work that is finished but still has something left over stayed in
the plan, with the leftover.


## What is done

Committed on `luanti-client`, oldest first: the extension and its primitives,
zstd, `pack_voxel_volume`, map blocks arriving and meshed, the server's own
textures, movement and walking, light and alpha, texture modifiers, tile
overlays and voxel colours, the frame of reference, pointing/digging/placing,
formspecs and inventories, per-segment atlas uploads, non-cube voxel shapes,
chat, active objects, the sky, a hotbar and a health bar, dropped items.

Since the plan was last written: the player's pace (Luanti applies BS to
acceleration twice), the light of a dug voxel, clicks reaching a form at all
(a Urho3D UI element is disabled until told otherwise), a chat dialog with a
field and buttons that can be seen, objects lit the way the voxels are, `-c -`
so a client can be driven from stdin a command at a time, forms that look
like the game meant them to (the style, the backgrounds, the text, the media
they name), the colour a voxel's param2 picks out of a palette, which way a
voxel faces -- the tile a facedir moves to each face of a cube, a shape turned
by one, and the wallmounted boxes and quads -- fields that can be typed into,
tables and tabs and checkboxes in a form, stacks taken half at a time, item
aliases, a torch that is a torch and gives light, the metadata that hangs
off a voxel, the boxes the player walks into rather than a cube, servers from
5.11.0 up, the frame time a loading world used to cost, the registry built a
slice a frame, the texture turned inside a facedir voxel's face, the tooltips
a form asks for, a light source's colour taken from its own texture, and a
session that ends saying why in a dialog -- back to the connect dialog if the
game never arrived, out of the client if it had.

Everything that is left is written as a step in "What is next".

## Found while playing: the light did not follow a node change

- **The light did not follow a node change.** DONE (2026-09-10), and then
  done properly the same day: the client works the light out itself, the way
  Luanti's own client does. `extensions/luanti_client/light.lua` is the
  algorithm -- take away the light that came from what changed, then spread
  what is left back in, once per light bank -- and world.lua provides what it
  reads and writes.

  The thing I said made this impractical was wrong, and it is worth writing
  down why. A block's param1 is a Lua string, so a flood fill that wrote it
  once per node would copy four kilobytes hundreds of times. But the writes
  do not have to go in one at a time: hold them in a table, let the reads see
  them, and put them into each block in one pass when the flood is done. Then
  the cost is one string rebuild per *block* touched, whatever the flood did,
  and the flood itself is a few dozen node visits for a placed or dug node
  (measured: 16 to 63 per change on the test game, and no resends at all).

  Sunlight is the one rule that separates the two banks: it is the value 15,
  one more than any light source can give, and it goes straight down undimmed
  through anything that lets it -- so a node that starts or stops letting
  sunlight through takes the whole column below it with it, which is a loop
  of its own. `sunlight_propagates` is what says whether it does, and it is
  now kept per node id beside `light_propagates`.

  light.lua takes its accessors rather than reaching for the map, so test.lua
  runs it on a small world of its own: a torch lighting what is around it and
  being taken away again, a stone shading the column under it and being
  taken away again, a three by three roof being two steps of shade at its
  middle, and glass letting light through but not the sun. Those are the
  cases that catch a wrong algorithm.

  The old way is still the fallback for what the flood cannot finish -- a
  node in a block we do not have, or the budget running out: tell the server
  we no longer have the block (TOSERVER_DELETEDBLOCKS) and it sends the block
  again with the light it worked out itself.

  Only a change that can move light is worth a resend: one where the light
  the node gives or whether light passes through it differs, which is why
  nodedef.lua now keeps `light_propagates`. A rail replaced by air costs
  nothing; a torch or a wall costs a block or a few. The blocks a change can
  reach are the one it is in plus any neighbour within fifteen nodes of it,
  and at most eight go out a frame.

  One thing to know if this is ever revisited: **air has no definition among
  the ones a server sends**, so `light_propagates` had to be seeded for it
  the way the node map already seeds air's voxel id. Without that seed every
  air-to-something change looked like no change at all, which is exactly the
  bug this was fixing.

  simplified, and it is a real one: the round trip. Luanti's client shows the
  new light in the same frame; this one shows it when the block comes back.

  And the traffic is the thing to watch, which is why it is throttled
  (2026-09-10, after the anarchy session loaded worse than the one before
  it): a block is only asked for again when it is within three blocks of the
  camera, at most eight go out a frame, and no more than twenty-four are ever
  waiting -- a storm of changes leaves the light stale rather than the world
  unsent. On a busy server every nearby player's digging would otherwise
  compete with the map that has not arrived yet, for light the player is not
  looking at.

## Found while playing: a public server's world only partly loaded

- **A public server's world only partly loaded.** SOLVED (2026-09-10) from
  the third log, and it was two bugs of this client's own. The counters added
  for it earned their keep by pointing away from the network: from the moment
  the definitions finished arriving there was nothing unacked, nothing early
  and no half-assembled split on any channel, while the block count sat at 21
  for a minute -- so nothing was stuck in the reliable layer, and the server
  was still sending other things (it re-sent a formspec every couple of
  seconds). The server had simply run out of blocks to send *where it thought
  we were*.

  **We were telling it we were at the origin.** `move()` synced the avatar
  from the server's own position -- MOVE_PLAYER, the only thing that says
  where a player starts -- *after* the early return that stands the player
  still while a form is up. A server sends a player who joins dead a death
  screen one tenth of a second after the spawn position, so the form was up
  from the first frame, the avatar never left (0, 0, 0), and every PLAYERPOS
  said so. The blocks the user saw "elsewhere" were the ones around the
  origin. The sync now happens before anything else in the frame.

  **And Respawn did nothing because the fields carried no "quit".** Luanti's
  own client sends the form's fields with `quit = "true"` whenever the
  *player* closes a form; the death screen's handler is
  `formname == "__builtin:death" and fields.quit and hp == 0`. This client
  sent only the button's own name, so the server heard a button press on a
  form nobody had closed and did nothing. Now an exit button, escape and the
  inventory key all send quit, and a form the server closed or replaced does
  not.

  Both are verified on the test game, which grew two things for it: a
  `/bfields` command that logs and echoes whatever a form sends back (a plain
  button gives `btn_stay=, text=`, an exit button `btn_exit=, quit=true,
  text=`, escape `quit=true, text=`), and a form shown on join behind
  `buildat_form_on_join`, which is the death-screen situation exactly. With
  that form up from the first frame and the player 850 nodes from the origin,
  175 blocks arrived where the player was.

## 0a. Textures with a tRNS chunk load as garbage -- DONE

`mcl_flowers:allium` and half of devtest's tools draw as a black rectangle
with coloured stripes. Both textures are **8-bit RGB PNGs with a `tRNS`
chunk** -- transparency by colour key, no alpha channel -- and a stride
mismatch is exactly what black-with-stripes looks like.

The cache file is byte-identical to the game's, so it is the decode. Urho3D's
`Image::GetImageData` calls
`stbi_load_from_memory(..., &components, 0)`, and with `req_comp == 0`
stb_image's PNG path reports the *file's* channel count while returning a
buffer with the *expanded* one:

    3rdparty/Urho3D/Source/ThirdParty/STB/stb_image.h:4543
        if (has_tRNS) s->img_out_n = s->img_n + 1;
    3rdparty/Urho3D/Source/ThirdParty/STB/stb_image.h:4609
        if (n) *n = p->s->img_n;      // <-- three, while the buffer is four

So `Image::SetSize(w, h, 3)` over a four-byte-per-texel buffer. A
palette PNG with `tRNS` goes the same way (line 4559).

Fix: one line in the vendored stb_image, `*n = p->s->img_out_n`, which is
what the returned buffer actually holds; `req_comp != 0` callers are
unaffected because the conversion above already sets `img_out_n = req_comp`.
It belongs in doc/urho3d_fork.txt with the rest of the fork.

DONE (c701b2f): the stb line, the fork note, and a 2x2 RGB-plus-tRNS PNG in
res/ that engine_test blits and reads back. devtest's tools draw right now;
basetools_steelshovel.png is colour type 2 with a tRNS chunk, so it was one
of the affected files. The re-sweep below is still worth doing.

Then: sweep the games again and compare the screenshots, because this has
been making textures wrong everywhere, not only in those two games. Worth a
check in engine_test.lua as well -- a tiny RGB-plus-tRNS PNG in res/, blitted
and read back -- so the fork patch cannot be lost silently.

## 0b. Double free in the mesher -- DONE

The backtrace is a worker thread inside
`CVoxelRegistry::get_cached()` doing `vector::_M_default_append` (that is
`m_cached_defs.resize()`, src/impl/voxel.cpp:127) while the main thread is
inside `add_voxel()`. There is no lock anywhere in CVoxelRegistry. The line
logged immediately before the crash is `add_voxel(): Added id=386
basenodes:water_flowing^57/...`, so it is exactly that: a pair voxel
registered on the main thread while a chunk was being meshed.

`SetVoxelGeometryTask`'s constructor calls `preload_textures()` on the main
thread, which is meant to warm the cache -- but a voxel added *after* the
task was queued makes `m_defs` longer than `m_cached_defs`, and the worker
then resizes it itself.

This is a latent race that step 5 made likely: a flowing liquid registers a
new pair whenever the player walks up to a water level nobody has seen yet,
which is constantly.

Fix, in two parts:
- The worker must never build or resize. `get_cached()` gets a "may build"
  flag; the mesher passes false and treats a cold id as drawing no faces.
  The block is already re-meshed when the registry changes, so nothing is
  lost.
- Appending must not move what a worker is reading. `m_defs` and
  `m_cached_defs` become `std::deque`, which never invalidates a reference
  to an existing element on push_back, and `add_voxel()` appends the cache
  slot next to the definition under a mutex. The worker's bounds check reads
  an atomic count. No lock on the per-quad path.

`-std=c++0x` in CMakeLists.txt means C++11: no `std::shared_mutex`.

The same hazard is in AtlasRegistry (`get_texture()` reads `m_cache` with no
lock while the main thread adds segments), and `update_cache_textures()`
called from a worker would touch it. Once the worker cannot build, it only
reads -- so the atlas needs the same stable-storage treatment.

DONE (bc82372), simpler than the two-part plan above: both registries take a
mutex on *every* access and hold their entries in `std::deque`, so a pointer
handed out stays valid across an append. The "may build" flag was dropped --
a lock-free read path needs the storage to be stable *and* untouched, and a
deque's own internals are written by a push_back, so a reader has to hold the
lock anyway. No "may build" means no cold entries and no silently missing
faces either. Measured cost: none worth naming -- devtest's registry build
246 ms against 253 ms before, VoxeLibre's 1338 ms against 1539 ms -- and a
run of eighteen teleports across fresh terrain (4102 blocks, fifteen new
param2 pairs registered while chunks meshed) stayed up.

If atlas contention ever does show up in a profile, the next step is the
snapshot: `SetVoxelGeometryTask` already warms every id in its volume on the
main thread, so it could copy the cached definitions and segment caches it
needs into the task and let the worker touch neither registry.

## 0c. Items that are used rather than swung -- DONE

devtest's `chest_of_everything:bag` and `basenodes:apple` do nothing on left
click: the client tries to dig instead. Luanti's own rule, in
src/client/game.cpp around 2793:

    if (selected_def.usable && isKeyDown(DIG))
        client->interact(INTERACT_USE, pointed);   // pointed may be NOTHING
    else if (pointed.type == POINTEDTHING_NODE)
        ... the dig path ...

and right-clicking nothing sends `INTERACT_ACTIVATE` with a pointed thing of
type NOTHING (`handlePointingAtNothing`).

The protocol side is already there and needs nothing: `itemdef.lua` reads
`usable` (line 84) and `liquids_pointable` (85), `client:interact()` already
serializes POINTEDTHING_NOTHING and OBJECT, and INTERACT_USE and
INTERACT_ACTIVATE are already constants. What is missing is the client's
input logic, all of it in init.lua:
- Left click while holding a `usable` item sends INTERACT_USE with whatever
  is pointed at, including nothing, and starts no dig.
- Right click pointing at nothing sends INTERACT_ACTIVATE.
- The dig path keeps the left button only when the held item is not usable.
- A usable item held down must fire once per press, not per frame: Luanti
  uses `wasKeyPressed`, so this wants the same edge detection the number
  keys have.

Then check on devtest: the bag opens its formspec, the apple is eaten and the
hotbar count drops.

DONE (07ddc19). Checked on devtest: the bag's own inventory form opened, and
three apples went down to one on two clicks. One thing found on the way: the
urho3d extension's event multiplexer walked the very list a handler was
unsubscribing from, so closing a form printed a Lua error every time -- it
now walks a copy and skips a handler an earlier one removed.

## 0d. Pointing at objects, hitting them, and dropping items -- DONE

One test walks through the whole of this, on devtest: drop an item out of the
inventory, or press Q with it wielded; the game throws it in front of the
player, where a voxel item is a small spinning cube wearing that voxel's
textures; then left-click it and the game's own code deletes the entity and
puts the item back in the inventory. Nothing in that chain works today.

Four pieces, in the order they unblock each other:

**1. The ray has to hit objects.** `view:point_ray(reach)` walks voxels and
nothing else, so an object is never pointed at, never clicked, never hit with
a tool. What it takes: test each object's selection box -- `selection_min`
and `selection_max` are already read into its props, and are in nodes,
offset by the object's own position -- against the same ray, and take the
nearest hit, object or voxel, whichever comes first. `props.pointable` gates
it, and it is Luanti's PointabilityType rather than a boolean: 0 not
pointable, 1 pointable, 2 stops the ray without being pointed at.

The outline follows: `set_pointed()` draws a wire box around a whole voxel,
and for an object it wants the object's own selection box. And the infotext
element 0c added is where Luanti puts a pointed object's nametag and
infotext, which is how a player reads what a mob is.

**2. Clicking what is pointed at.** The protocol is already there --
`client:interact()` serializes POINTEDTHING_OBJECT, and the pointed thing
carries the object's id. Luanti's rules, from `handlePointingAtObject`:
- Left click sends INTERACT_START_DIGGING with the object pointed at, once
  per press and then no faster than a hit delay while held (Luanti's
  `object_hit_delay`, 0.2 s).
- Right click sends INTERACT_PLACE with the object pointed at, which is what
  a game's `on_rightclick` on an entity runs.
Neither of them digs.

**3. Dropping.** Two ways in, one command out. Luanti's IDropAction, from
inventorymanager.h:

    Drop <count> <from_inv> <from_list> <from_i>

with a count of zero meaning the whole stack and the index zero-based, which
is the same shape as the `Move` this client already sends
(`send_inventory_move`). So `send_inventory_drop` beside it, and then:
- **Q** while an item is wielded: drop from `current_player` / `main` /
  the wielded slot, the whole stack, or one of it while sneaking, which is
  what Luanti does.
- **Out of the formspec**: the drag this client already has, released
  outside any slot, and the click-to-pick then click-to-place path the same
  way. That is a small addition to the existing drag: today a release
  outside a slot puts the stack back.

**4. What a dropped item looks like.** A voxel item is drawn by Luanti as a
small cube wearing the voxel's six tiles, turning slowly --
`props.automatic_rotate`, already read, is how fast. This client draws a
billboard of the item's inventory picture, which for a voxel is the flat
isometric cube: right from one angle and wrong from every other, and it does
not turn.

What it takes is a real cube of quads on the object's node, with the six
tiles' atlas coordinates on its faces -- the voxel registry already has
them -- and the node turned about Y each frame. That is the same "hand quads
to an object's node" machinery a mob mesh needs, so doing it here is doing
most of that too.

DONE (f75560b), all four pieces, and the whole test walked on devtest: Q
drops the wielded stack, the item lands in front of the player as a small
spinning cube of the node's tiles, pointing at it outlines its selection box
and shows its infotext ("Dirt"), and a left click gives the stack back.

What it did not need: the atlas coordinates. The cube is a CustomGeometry of
six one-quad geometries, each wearing the tile's own resolved texture as a
material of its own -- which is the same thing objmesh and b3dmesh would
want, and it is what a mob mesh can be hung on next. Three things worth
remembering:
- A click is down and up inside one frame, so an object hit has to go out
  from the button-down handler; waiting for the next update_dig loses it.
- The tiles are only resolved for drawtype 0. A node box or a plant keeps
  its inventory picture until an object can carry a real shape.
- The faces are wound both ways, like the selection frame, rather than
  getting the winding right per face.

Two things the first test of it turned up, both fixed (2e02ade, 509f7a4):
dragging a stack out of a formspec died on reading the window element's
size, because `simple_property()` can only wrap a class-typed read when it
is handed the wrapped class rather than the class's *name* -- so
UIElement.size, minSize, fixedSize and colour were write-only in the
sandbox. The drop now takes the numbers from the layout the form was drawn
from, and the four properties were given their classes so the next reader
of one does not hit the same wall.

## 0e. Water, and what the second mesher is for

The question was whether the neighbour mask in `pack_voxel_volume()` is
enough. It is not, for water:
- A flowing liquid's surface is **four corner heights**, each averaged from
  the levels of the four voxels around that corner. As voxel ids that is
  thousands per liquid; as a mask it does not fit at all, because a mask
  carries bits and this needs a value per neighbour.
- Water is **alpha blended**, not alpha masked, so it belongs in a
  back-to-front pass rather than in the opaque geometry.
- Faces *inside* a body of water must not be drawn, while the terrain
  surface *under* the water must be. A shaped voxel today gets
  EDGEMATERIALID_EMPTY, which is right for the second half and wrong for the
  first: nothing culls water against water.

**So: the two-pass shape.** Polyvox keeps the cube case, which is most of the
world and what it is fast at. A voxel definition gains a flag saying it is
not polyvox's business; polyvox skips its faces and its neighbours draw
against it as they would against air, which is already what EMPTY does. Then
a second pass over the same padded volume, on the same worker thread, walks
only the voxels that were skipped and builds:
- **connected shapes**: a shape per neighbour mask, uploaded once per
  definition at registration rather than as a voxel id per mask. That is the
  neighbour-mask idea evaluated inside the mesher instead of in the volume
  packing, and it costs 64 shapes per definition rather than 64 registry
  entries.
- **liquid surfaces**: a liquid family with the level in param2, corner
  heights averaged from the four neighbours, a face against the same liquid
  not drawn, and the top face kept when the voxel above is not the same
  liquid. This is Luanti's `getCornerLevel` and `drawLiquidSides`, and it is
  general enough to be a voxel-world feature rather than a Luanti one.

What it must not do is call Lua: the pass runs on a worker thread. So it is
data driven, from tables uploaded at registration.

Output: the opaque quads append into the same per-atlas `TemporaryGeometry`
map polyvox filled, and the translucent ones into a second map that becomes
a second CustomGeometry on the chunk's node with an alpha-blended technique
and depth writing off.

**Sorting**, and how far to take it: Urho3D sorts alpha *drawables* by
distance, not triangles inside one. One alpha geometry per chunk, sorted
between chunks by Urho3D itself, is what a voxel game does and is enough --
once the internal faces are culled there is rarely more than one water
surface along a ray inside one chunk. Write that down as the simplification;
per-triangle sorting or depth peeling is the upgrade path.

**Under the water** wants three more things, each its own piece of work: the
surface drawn from both sides so it is there when the camera is below it,
the fog colour and range the game gives for being in a liquid, and Luanti's
own tint over the whole screen. None of them are the mesher.

**How the translucent geometry reaches the scene -- the one thing to decide
before writing any of this.** Read while doing 0a-0d, so it is written down:
`generate_voxel_geometry()` fills `sm_<uint, TemporaryGeometry>` keyed by
atlas id, and `set_voxel_geometry()` turns each entry into one geometry of
one CustomGeometry, with a fresh Material each. Skylit geometry is left
without a technique on purpose -- only the game knows which shader reads
what the mesher packed -- and world.lua's `apply_technique()` walks the
component's materials and puts VoxelUnlit on all of them. So there is
nowhere for "this geometry is water" to be said today, and the map is
unordered, so "the translucent ones come last" is not available either.
Three routes:

- **A. A second key range in the same map** (atlas id with a high bit set)
  and something for Lua to ask which geometries are translucent. Smallest
  C++ change, but it needs a new accessor and Lua then has to trust an
  index-to-kind mapping.
- **B. A second CustomGeometry on a child node of the chunk** -- the task's
  `post()` creates or finds a child called something like "alpha" and fills
  it from the translucent map. `apply_technique()` grows a branch that puts
  an alpha-blended technique with depth writing off on that child's
  materials, and Urho3D sorts the child drawables between chunks by
  distance, which is the sorting the simplification above wants anyway.
  This is what the output paragraph above already describes.
- **C. The definition names its technique** and C++ sets it. Fewest moving
  parts at the Lua end, but it puts a resource name for a shader in the
  voxel registry, which is the game's business and not the mesher's.

**B, decided (2026-09-10, by the user's call): a child node on the chunk,
and Urho3D does the alpha sorting between chunks.** It needs no new registry
field beyond the translucent flag, it keeps the "the game picks the
technique" rule that the skylight path already relies on, and the per-chunk
alpha drawable is exactly what makes Urho3D's own sorting do the right thing
between chunks. Per-triangle sorting and depth peeling stay the upgrade
path, written down as the simplification rather than built.

What B comes to, concretely:
- `VoxelDefinition` gains a `translucent` flag, copied into
  `CachedVoxelDefinition` the way the rest of it is.
- `generate_voxel_geometry()` takes a second `sm_<uint, TemporaryGeometry>`
  and puts a translucent voxel's faces there instead of in the opaque one,
  keyed by atlas id the same way. The extra map is empty for a chunk with
  no water in it, which is most of them.
- `SetVoxelGeometryTask::post()` fills the chunk's own CustomGeometry from
  the opaque map, and -- only when the translucent map is not empty --
  creates or finds a child node ("alpha", LOCAL) with a CustomGeometry of
  its own and fills that from the other. An empty map removes the child, so
  a chunk that loses its water does not keep a stale drawable.
- world.lua's `apply_technique()` grows the same branch: the child's
  materials get an alpha-blended technique with depth writing off. That is
  a new .xml beside VoxelUnlit, reading the same vertex colours.
- The liquid cubes stop culling against stone. Today a full liquid cube is
  EDGEMATERIALID_GROUND, so the face between water and stone is drawn by
  neither -- invisible under opaque water, a hole under translucent water.
  Water wants an edge material of its own: culls against the same liquid,
  draws against everything else.

Staging, so that something is visible early:
1. The read-only worker registry from 0b, which the second pass needs
   anyway.
2. Water in an alpha pass with the flat per-level shapes step 5 already
   builds, and a liquid edge material so water culls against water. This is
   most of what water looks like, without the new mesher. **DONE**, along the
   lines of B above; see the note below.
3. The second mesher, with liquid corner heights first and connected shapes
   after -- fences and panes are the same machinery once it exists.

Stage 3, first half DONE (2026-09-10), and it did not need a second mesher
at all. The shape pass in `generate_voxel_shapes()` already walks the padded
volume with the neighbours in reach, which is the whole of what "a second
pass that looks at neighbours" was going to be; the shape-group culling above
was the first use of that and the corner heights are the second. So:
`VoxelDefinition` gains `is_liquid` and `liquid_top` (where the surface
stands inside the voxel, 0.5 for a liquid drawn as a full cube), world.lua
takes `liquid_top` from the top of the shape it built, and the mesher moves
every shape vertex that sits on that surface to `liquid_corner_top()` -- the
average over the four columns meeting at that corner, with Luanti's two
rules (the same liquid above a column means full to the top; two empty
columns mean the corner drops to the bottom, which thins out the edge of a
spill). Four corners per voxel, computed once each rather than per vertex.
Verified on devtest: the spill's surface slopes continuously and thins at the
edge, and the mesh time per block did not move.

No check runnable outside the client: there is no C++ test target in the tree
and the mesher is not reachable from test.lua, so this was verified on screen
like the rest of mesh.cpp. Worth knowing when the connected shapes land on
the same pass.

What the second half -- connected shapes -- now comes to, given the above: a
definition carrying a shape per neighbour mask rather than one shape, and the
same pass picking by the mask it computes from the neighbours. No new pass,
no new thread, no Lua on the worker.

Stage 2 DONE (2026-09-10). What it came to, and the two things worth
remembering:
- `VoxelDefinition.translucent` (cereal version 4) is copied into the cached
  definition, `generate_voxel_geometry()` takes an optional second map and
  both the cube emit and `generate_voxel_shapes()` pick between the two by
  it, `SetVoxelGeometryTask::post()` puts the second map on an "alpha" child
  node of the chunk (removing it when the map is empty, and
  `clear_voxel_geometry()` removes it too), and world.lua's
  `apply_technique()` gives that child res/VoxelUnlitAlpha.xml.
- The alpha technique is not a second shader: VoxelUnlit.glsl grew a
  TRANSLUCENT define that replaces the half-alpha cutoff with keeping the
  texture's alpha, and the technique's one pass is blend="alpha"
  depthwrite="false" with no light pass -- an additive pass over a blended
  one would count the surface twice.
- Liquids are the kind "liquid" in CUBE_DRAWTYPES, which is edge material 11
  and `translucent = true`. So water culls against water, and the terrain
  under it is drawn because stone is "ground".
- Tested on devtest: water placed on grass shows the grass through it, and
  the water it flowed into over the terrain sorts without visible artifacts.
  VoxeLibre's water is a grayscale+alpha texture at alpha 185, which is what
  it now blends at.
- The first look at it turned up what the plan itself predicted: a flowing
  liquid read as opaque next to a transparent source, because nothing culled
  the faces inside a body of water. Fixed in the same round rather than
  waiting for the second mesher, and it took three things:
  `VoxelDefinition.shape_group` (the TODO in voxel.h that asked for exactly
  this), which `generate_voxel_shapes()` uses to drop an axis-aligned quad
  whose neighbour has the same group; one edge material per liquid family
  rather than one for all liquids, keyed on `liquid_alternative_source`, so
  water culls against water and lava against lava; and a rule in
  `IsQuadNeededByRegistry` and the shape pass alike that a translucent
  voxel's face against an opaque one is not drawn at all, because that
  surface is the opaque voxel's own. Without the last one the lake bottom sat
  behind two blended layers and the water read as opaque from above.
- What is left of it, and it is the reason for corner heights rather than a
  separate item: a quad against a *lower* level of the same liquid is dropped
  with the rest, so the surface steps down where the level does.
- Not done here, and the honest limit: the *node's* own alpha mode is not
  read. Luanti puts `use_texture_alpha` after collision_box in
  ContentFeatures and nodedef.lua stops at collision_box, so glass a game
  gave a real alpha to is still alpha masked. Reading two more fields there
  is the upgrade path, and it is what would put framed glass and panes in the
  same pass.

## 0f. The round of 2026-09-10: water, connected boxes, objects, particles, outlines -- DONE

What each of these came to. What is left over from any of them is in the
plan under the same numbers.

In this order, which is what each is worth on screen over what it costs:

1. **The rest of water.** DONE (2026-09-10), and both halves came out
   smaller than expected. The surface from below is the alpha technique's
   `cull="none"` rather than doubled quads -- doubling a blended quad blends
   it twice, which is what made a flowing liquid read as opaque. And there is
   no per-liquid fog in the protocol this client reads: what Luanti gives is
   the node's `post_effect_color`, painted over the whole screen while the
   camera is in that node, which nodedef.lua now reads and init.lua draws as
   a panel in front of the world and behind the rest of the UI.
2. **Connected node boxes**: fences with their rails, panes in a run, walls,
   framed glass. This is the largest remaining "the world is drawn wrong"
   item -- VoxeLibre is full of both -- and the pass it goes in is the one
   water's corner heights are already in.

   DONE (2026-09-10), on the shape pass the liquids' corner heights are on,
   and the 32-family bitmask the question below settled. What it came to:
   - `VoxelQuad` gains one byte, `connect_dir`: 0 for a quad that is always
     drawn, 1...6 for one drawn only when the neighbour in that direction
     connects, 7 for one drawn only when none of them does -- which is what
     a lone pane's stub is. So a connected shape is still *one* shape and
     one voxel id, not sixty-four of either.
   - `VoxelDefinition` gains `connect_group` (which family this voxel is in,
     1...32), `connect_mask` (a bit per family it reaches out to) and
     `connect_to_solid` (Luanti's connect_sides, which is how a fence
     reaches into stone). `connected_faces()` in the mesher works the six
     directions out once per voxel, and each quad tests one bit.
   - nodedef.lua keeps `connects_to`, `connect_sides` and the six
     `connect_<side>` box lists it used to read past -- Luanti's order there
     is top, bottom, front, left, back, right with front at -Z, which is
     face 1, 2, 6, 4, 5, 3 in buildat's order -- and shapes.lua tags the
     quads it builds from them.
   - world.lua's `connect_families()` is the answer to the question that was
     here: Luanti says connections with node ids and the mesher has voxel
     ids, so the ids are turned into families once per set of definitions.
     Two nodes are in the same family when exactly the same definitions
     reach out to them, which makes every wood's fence one family and every
     stone's wall another. Over 32 families the rest share the last one,
     with a warning.

   Verified on VoxeLibre: three fences placed in a row grew rails towards
   each other, and the neighbour's mesh was rebuilt when the next one went
   down. test.lua checks the wire format of a connected node box, the
   mapping of Luanti's side order onto buildat's faces, and that the quads
   come out tagged.

   **Rails DONE too (2026-09-10)**, on a second mechanism beside the tags,
   because a rail does not gain a piece per direction: it changes altogether.
   `VoxelDefinition.shape_masked` is a shape per neighbour mask -- 0...15 for
   the sixteen masks of the four horizontal neighbours, in Luanti's own bit
   order, and 16...19 for the four a rail climbs a step in -- kept as one
   vector and twenty-one offsets so that the definition stays small. The
   mesher uses it instead of `shape` when it is there, which is the "shape
   per neighbour mask" this plan sketched from the start; rails are what
   actually wanted it.

   shapes.lua's `rail_shapes()` is Luanti's rail_kinds table: which of the
   four tiles and which turn per mask, and the four ramps, whose raised edge
   is one node above their flat edge so that a ramp meets the flat rail a
   step above it exactly -- the user caught that being a sixteenth short.
   Rails connect by Luanti's `connect_to_raillike` group rather than by
   connects_to, so each of those groups gets a family in `connect_families()`
   and every rail in it connects to every other.

   Verified by the user on their own build: rails connect on flat ground and
   the slope renders, and the two rail families in the test game's formation
   do not connect to each other.

3. **Objects that are not boxes.** DONE (2026-09-10) for the static pose,
   and it was as small as the plan hoped: `object_resource()` reads the
   model through the same `read_mesh()` node meshes go through and hands back
   its quads with one resolved texture per material, and world.lua's
   `build_object_mesh()` is `build_item_cube()` generalised -- one geometry
   per material, both windings. The one thing that was not obvious: an
   object's model is authored in Luanti's scene units, where a node is ten
   across, so visual_size has to be divided by ten, where a node's "mesh"
   drawtype is authored one unit to the node. Verified on devtest
   (testentities:mesh, an .obj) and on VoxeLibre (a summoned cow, a .b3d):
   the cow is a cow.
4. **Particles**: ADD_PARTICLESPAWNER and SPAWN_PARTICLE_BATCH. Every game
   sends them -- digging, explosions, smoke, rain -- and Urho3D has a
   particle system already, so this is mapping one description onto another.

   DONE (2026-09-10). What it came to:
   - `extensions/luanti_client/particles.lua` reads both packets. The wire
     format is three nested shapes -- a value, a range (min, max, bias), and
     a tween (style, reps, offset, start range, end range) -- so a spawner's
     position is fifteen floats. Protocol 42 and up only; before that the
     tweens are not on the wire and a spawner is dropped rather than read
     wrong. It stops at the node fields, the way Luanti's own reader stops
     when the stream runs out, so drag, jitter, bounce, the attractors and
     the texture pool are not read.
   - client.lua handles SPAWN_PARTICLE (0x46), ADD_PARTICLESPAWNER (0x47),
     DELETE_PARTICLESPAWNER (0x53) and SPAWN_PARTICLE_BATCH (0x64, a zstd
     frame of length-prefixed single particles).
   - safe_classes.lua's ParticleEffect was a bare wrapper with no properties
     at all; it now has `new` and the twenty-odd setters an effect needs.
   - world.lua turns a spawner into a ParticleEmitter and a single particle
     into an emitter of one that fires once.

   **Corrected on 2026-09-10, after the weather work.** What is below was
   only half the story, and the half that mattered less. The user's report --
   "each one flying away from the player instead of doing their different
   motions" -- was mostly `minDirection`/`maxDirection` never reaching
   Urho3D at all: tolua++ generates no setter for a property whose type is a
   const reference, so the effect kept its default direction cube and every
   particle flew off at random. See the weather item in section 6 of the
   plan. The speed mapping below is still needed and still right; it was not
   the reason particles moved wrongly.

   **The thing that cost the most, and the lesson.** Urho3D takes a
   particle's velocity as a *direction and a speed*, and normalizes the
   direction, so pinning the speed to 1 -- which is what "a box of
   directions at unit speed" comes to -- makes every particle leave at one
   node a second whatever the game asked for. On screen that reads as all of
   them flying away from where they started, which is what the user reported
   after trying devtest's testtools:particle_spawner. A velocity *range* has
   to go over as the direction box plus the range of magnitudes that box
   holds: `particles.speed_range()`, with four cases in test.lua. The speed
   is then picked independently of the direction, which is the part that
   stays wrong, and is exact for a single particle.

   And a lesson about testing rather than about particles: I concluded from
   four screenshots that ParticleEmitter drew nothing at all, and wrote that
   up as needing a decision. It was drawing all along -- every one of those
   shots had the particle outside the frame, because a particle spawned at
   the pointed position lands at the player's own x,z when nothing is
   pointed at, and because `mouse_move` in the command sequence turns about
   0.15 degrees a pixel, so my "look straight down" moves were saturating
   the pitch clamp instead. The client also queues commands: the status line
   said "63 commands waiting" at one point, so a screenshot can be taken
   before the move ahead of it has happened. Wait for the queue, and check
   the status line's own numbers before believing a screenshot.

   The texture animation, which the user asked for, is DONE (2026-09-10):
   `particle_frames()` in world.lua turns Luanti's TileAnimationParams into
   Urho3D's texture frames -- the part of the image each frame is and how
   many seconds into the particle's life it is shown from -- for both a
   vertical strip and a sheet. How many frames a strip holds is the image's
   own shape against the aspect the game gave, which is Luanti's own
   arithmetic. Urho3D stops on the last frame rather than looping, so the
   frames are laid out again and again up to a cap of 64. The sandbox gained
   `Rect` and `ParticleEffect:AddTextureTime()` for it. Verified on the test
   game with testtools' particle spawner, whose test texture is a numbered
   sheet: the number changes.

5. **The pointed-node outline** around the node's own selection box rather
   than the whole voxel. DONE (2026-09-10): world.lua keeps the selection
   box per node id beside the collision box it already kept -- Luanti's
   selection box, falling back to the node box, and nothing for a node that
   has neither, which is the whole voxel -- turns it by param2 through the
   same `turn_boxes()` the collision goes through, and `set_pointed()` hands
   the union of the boxes to the `set_pointed_box()` 0d built for objects.
   simplified: the union rather than one frame per box, and the frame's bars
   scale with the box, so they are thicker on a big one.
6. **Two small honesty items**: DONE (2026-09-10), both of them.
   - The node-carried `formspec`: a right click on a node whose metadata
     has one opens it here, and the interact still goes out when the node is
     rightclickable, because that is what runs the game's on_rightclick.
     Two things it needed beyond that: TOSERVER_NODEMETA_FIELDS (0x3b), so
     a button in such a form reaches the node rather than the player; and
     "current_name", which is how a chest names its own inventory in a
     `list[]` and which resolves to the node the form came out of, both when
     the slots are read and when a move or a drop names the inventory.
     Verified on devtest's chest:chest: the form opens with the node's
     thirty-two slots, and a stack moved into one made the server's own
     chest mod log the put.
   - PRIVILEGES (0x41) is read into `client.privileges`, and K says
     "the server has not given you the \"fly\" privilege" rather than
     letting the server's movement check pull the player back in silence.
     Verified by revoking the privilege on a running server.

## 1. Loading, on a server whose game is not the test one -- DONE

Committed as "ask for all the media at once, behind a loading panel". The
discover-ask-rebuild loop is gone: everything the announcement lists and the
cache lacks is asked for in one go, the registry is built once when that has
arrived, a panel covers the screen with the media count until it is done, and
the build gets 50 ms of the frame instead of 4 while the panel is up.
A modifier texmod.lua does not implement is logged once with an example.

Measured on the test server with an empty cache (`-C` at a fresh directory):
announcement at 20:32:37, all 3406 files asked for in eighteen requests inside
0.3 s, one build at 20:33:14 -- 2492 voxel types, 577 compositions, 1082 ms of
work over 1458 ms of wall clock. Before this it was three builds of 15 s and
a world of placeholders throughout; the 646 voxel types the public server got
textures for are 2492 here, because every file the definitions reach is now
there. Walking afterwards: 592 blocks received, 346 us to hand over, no
further builds.

Still to do, and no longer urgent:

- **Creating an atlas is 22 ms**, three times during a load (one per texture
  resolution): two 2048x2048 images allocated and one uploaded with its mip
  levels. The segments themselves are only 60 us each now. All of it is
  behind the loading panel now.
- **Connecting has three frames of 170, 370 and 760 ms**: the announcement of
  3400 files, and the store hashing every cached file. The third of them was
  `plan_media()` walking every texture expression, which is gone. Both of the
  others are behind the panel.
- **An idle frame still spends 4.5 ms in Lua**, most of it the objects and
  the counters.
- **Seen once and not reproduced**: a furnace placed on a hillside was drawn
  for a second as a hole, then as a cube with a flat white front, then
  correctly.
- The loading panel does not cover the chat lines at the bottom of the
  screen. That is information rather than the world, so it stays for now.

## 2. Two things wrong with the sky -- DONE

Committed as "the sun keeps its own colour, and fewer stars". The red sun was
two things: the shader drew the disc in `cSunTint` -- Luanti's `fog_sun_tint`,
orange -- at every hour, and `set_sky()` called `set_daylight()` with no time
of day, whose default is noon, so any SET_SKY in the night put the orange disc
back overhead. The disc now takes the tint only as far as the tint's own
horizon band reaches, and the time the sun was last placed at is kept. The
stars went from a density of 0.06 to 0.004 and from white to grey.

Verified with `BUILDAT_LUANTI_FORCE_TIME`: at 9000 the sun is pale cream, at 0
the moon is white and the starfield reads as stars.

Also done, out of order because it was asked for: a form that asks for no
`background[]` or `background9[]` of its own is drawn over a dark grey panel
covering the whole form, so a label over a sunlit hillside can be read.

## 3. The inventory the player actually uses -- DONE

- **Dragging a stack**: the stack in hand is drawn under the cursor and
  follows it, letting go over another slot puts it there, over the same slot
  or over nothing it stays in hand.
- **A tooltip on a slot**: "Oak Door" and "[mcl_doors:wooden_door]" under it,
  the first line of the item's description and the name it is known by.
- **Inventory voxel cubes**, through a new `shear` operation in
  `compose_image` that maps a source image onto a parallelogram. Three tiles,
  three parallelograms, the sides darkened with a `[multiply`, composed and
  cached on disk like any other composed texture. Render to texture was the
  other way and is now step 12.

## 4. Voxel meshes -- DONE

`objmesh.lua` reads the corner of Wavefront .obj a node mesh uses -- `v`,
`vt`, `f`, `usemtl` -- into `VoxelDefinition.shape` quads: corners already in
the voxel's -0.5...0.5 cube, the second texture coordinate turned over, a
triangle as a quad with its last corner twice, a material per tile. Wired in
through `options.read_mesh`, cached by model name and the scale asked for, so
282 definitions sharing 30 models read each once; `visual_scale` multiplies
the corners. The registry's line says how many models were read.

All 42 of this game's models parse, 2338 quads. The winding is pinned in
test.lua against `shapes.box_quads`: both want the cross product of two
consecutive edges pointing out of the shape (a box's +Y face gives +Y).

Seen working on the test server: a placed `mcl_flowerpots:flower_pot` is a
terracotta pot with its open top and its inner walls drawn, which is the
double-sided shell a node mesh wants.

`.b3d` came later, with the objects that are not boxes -- see 0f item 3.

Left, and in the plan:
- A node mesh may reach outside its own voxel -- of this game's models the
  flowerpot with a flower reaches 1.49 before its 0.5 scale, the sunflower
  1.43 -- so a chunk's bounding box wants to allow for that or such a voxel
  gets culled early. Not seen going wrong yet.
- The same isometric projection the inventory cube uses would draw a
  **nodebox** item icon as its boxes rather than as a flat tile, which is
  what Luanti does for anvils and stairs. Three parallelograms per box; the
  `shear` operation is already there.

**A testing note that cost most of a session.** Two things near a placed
voxel are not the voxel: an object is drawn as a voxel-sized box wearing a
texture, so a dropped item looks like a cube of its inventory image and one
with no texture yet wears `unknown_object.png`, which is
`res/placeholder.png` -- a grey checkerboard. And placing puts the voxel one
step from the face pointed at, which at a 25-degree depression is close
enough to fill a quarter of the frame well off to one side: crop from the
whole screenshot, not from where the crosshair is.

## 5. Liquids -- DONE

A flowing liquid is a box with a lowered top: `shapes.liquid_top(range, p2)`
does Luanti's own arithmetic from `getLiquidNeighborhood` -- the level is the
low three bits of param2, a range shorter than eight puts the levels it does
not have on the floor, and the surface stands at `-0.5 + (level + 0.5) /
range`. One voxel per level, through the same (definition, param2) machinery
a facedir goes through; on the test server that is 42 pairs. Drawn from both
sides, so the surface is there when the camera is under it.

A liquid at the top level gets no shape at all, so it stays a cube whose
faces against the next one are culled: a waterfall, the middle of a lake and
a source are cubes, and only the fringe costs a shape. That is also what
stands in for `top_is_same_liquid`, which Luanti reads off the node above and
a single voxel cannot know -- a flowing node at the top level is nearly
always one with liquid above it or a source beside it, both of which Luanti
draws full height.

The slope and the transparency were both done later, with the rest of water
and the connecting voxels -- see 0e and 0f item 1. The special tiles are
still in the plan.

## 6. The presentation the game asks for -- mostly DONE

In the order this game leans on it:

- **HUDADD and friends** -- DONE. hud.lua reads HUDADD, HUDRM, HUDCHANGE,
  HUD_SET_FLAGS and HUD_SET_PARAM and does Luanti's placement arithmetic;
  formspec_ui.lua draws the images, the text and the statbars. The flags
  matter more than they look: VoxeLibre turns this client's own health bar
  off because it draws its own hearts, and a game's HUD is only right once
  the flags are honoured. Also the version split is handled: a size is v2s32
  below protocol 52 and v2f from there.

  Tested against two games, and worth remembering: VoxeLibre's own bars are
  created hidden and only appear on the first change, so its HUD looks empty
  until something happens, while Exile (port 30002 on the test machine) puts
  its health, thirst, hunger and temperature on the screen as text at once.
- **Sounds** -- DONE. PLAY_SOUND, STOP_SOUND and FADE_SOUND, with the
  announced media sorted into groups the way Luanti groups it
  ("name.<digit>.ogg" and "name.ogg" are group "name") and one of a group
  played at random. A positioned sound is a node with a SoundSource3D and
  the listener rides the camera. A sound attached to an object starts where
  the object is and follows it (2026-09-10), which is what a mob's own
  noises want; the object table had to move above the sounds in world.lua
  for that, because a Lua closure only sees a local declared before it.
- **The digging animation** -- DONE. res/crack_anylength.png is Luanti's own
  (CC BY-SA 3.0, listed in res/LICENSE), the strip is cut into frames by
  texmod's [verticalframe and how many frames there are comes out of the
  image's shape. It is drawn as a cube just outside the voxel rather than as
  a second layer on the voxel's own tiles, so the crack around a stair is a
  cube; the faithful way is a voxel per (definition, frame) through the pair
  machinery, which is five more voxel types per definition.

  A gotcha worth keeping: a Material made in Lua lives only while something
  in the engine holds it, so one node per frame enabled one at a time rather
  than one node whose material is swapped. Caching materials in a Lua table
  and putting them back later segfaults in RefCounted::AddRef.
- **The sky the game describes** -- DONE. SET_SUN, SET_MOON, SET_STARS and
  CLOUD_PARAMS: the sun's and the moon's size (zero for one turned off), the
  star count and colour, and the cloud coverage are shader uniforms rather
  than constants. The sun's and the moon's own textures are DONE
  (2026-09-10; see section 7).

  The cloud speed is DONE (2026-09-10), fudged, **by the user's call**: the
  clouds here are not a layer at a height -- the sky shader divides the view
  direction by its own y to fake a flat plane -- so a speed in nodes a second
  has nothing exact to become. It goes through a factor picked so that
  Luanti's own default (0, -2) drifts at the rate the shader had baked in
  before a game could ask for anything, which makes a game asking for twice
  that twice as fast. That is what the field is for: the amount and the speed
  of the clouds are visible, and the numbers are not Luanti's.

  The height and the thickness have nothing to become and are dropped. **The
  exact Luanti cloud look is decidedly not implemented (2026-09-10, the
  user's call)**: a real slab of cloud at a height, which the player can fly
  above and through, wants the camera's position in the sky shader and a
  plane intersection, and it is bigger than the fields it would honour. It is
  in section 13 with the rest of what is not being built.
- **What else a server says** -- OVERRIDE_DAY_NIGHT_RATIO and PLAYER_SPEED
  are DONE. Still unhandled, in the order the sweep counted them across the
  installed games: UPDATE_PLAYER_LIST and PRIVILEGES and
  CSM_RESTRICTION_FLAGS (all fourteen games; none of the three changes what
  is on screen -- PRIVILEGES is worth reading only to say why flying was
  refused), LOCAL_PLAYER_ANIMATIONS and SET_LIGHTING (five and four games),
  EYE_OFFSET, MINIMAP_MODES. PRIVILEGES and the particle commands are both
  DONE (2026-09-10); see 0f item 4 for what the particles came to.
- **Object visuals** -- the sprites are DONE. A visual of sprite,
  upright_sprite, item or wielditem is a BillboardSet turned to the camera
  about Y; the two item visuals carry an item name where a texture would be,
  so a dropped item wears its inventory picture -- the isometric cube for a
  node, which is what Luanti's wielditem is.

  The mobs are DONE (2026-09-10; see 0f item 3): a "mesh" visual is drawn as
  the model the game names, in its rest pose.

  Two sandbox bugs came out of this: `castShadows` was declared on
  StaticModel and on Light rather than on Drawable where Urho3D has it, so a
  BillboardSet did not have it, and StaticModel's wrapper said it inherited
  from Octree. Both fixed in extensions/urho3d/safe_classes.lua.
- **FOV** -- DONE. TOCLIENT_FOV, in degrees or as a multiple of the client's
  own, with the transition time honoured. It does not change the field of
  view the client claims to the server, which decides which blocks it is
  sent; that is more blocks than a zoomed-in player wants, never fewer.
  TOCLIENT_CAMERA is a restriction on which camera modes are allowed rather
  than a change, and this client is always in the first person, so there is
  nothing to do with it.
- **DEATHSCREEN** -- nothing to do. 0x37 is LEGACY from 5.12 on and this
  server is 5.17: VoxeLibre's own death screen is a formspec, and it already
  comes up and its Respawn button already works.
- **The metadata fields that are text.** `infotext` is DONE: it is drawn
  under the chat while the node is pointed at, which is where Luanti draws
  it, cut at six lines.

What is left of this section -- the waypoints' world-to-screen path, a
sound's start_time, the commands still unhandled, the object animation and
nametags, and a sign's `text` -- is in the plan.

## 7. The sun's and the moon's own textures -- DONE

The sun's and the moon's own textures are DONE (2026-09-10). `Body()` in
LuantiSky.glsl already worked out where inside the body's square a pixel
is, so it now returns that as well and the shader samples the texture
there, with the texture's own alpha as the coverage -- which is what makes
a sun drawn as a disc in a square image come out a disc. The two units a
material has are the sun's and the moon's, and world.lua resolves the names
through the same `media_texture` the objects and the formspecs use, once
per sky update, so a texture that has not arrived yet is picked up when it
does. Verified on exile, which ships its own sun.png and moon.png: both are
round.

The rest of section 7 -- the PBR mode, the tonemaps, the sunrise texture
and the `skybox` sky type -- is open, in the plan.

## 7b. Nearest-pixel rendering -- DONE

Asked for by the user (2026-09-10): a Luanti game's assets are pixel art and
the objects were being interpolated. The voxel atlas had said FILTER_NEAREST
in the engine all along (`src/impl/atlas.cpp`), but every other place a
game's texture went on a material took Urho3D's default: the objects, a
dropped item's cube, a mob's model, the crack overlay, the sun and the moon.
They now all go through one `game_texture()` in world.lua, and the sandbox
exposes `Texture.filterMode` for it. Verified on VoxeLibre: a cow's face is
pixels rather than a blur.

What is left of it -- the UI's own images -- is in the plan.

## 9. Older servers: 5.11.0 to 5.17.0 -- mostly DONE

Mostly done (commit "speak to Luanti 5.11.0 as well as 5.17.0"): the world
draws, the player walks, the creative inventory opens and the chat works
against 5.11.0 (protocol 47) and against 5.17.0-dev (52). What that took:
definitions and media are zlib below protocol 48 and zstd from there, the
media announcement below 48 is a plain list of names with base64 hashes, an
item's image carries an animation only from 51, and the inventory is the rest
of its packet below 52. ContentFeatures, ItemDefinition, NodeBox, TileDef and
the sounds are byte-for-byte the same across the range.

HUD_ADD and HUD_CHANGE's version split is DONE too (hud.lua's read_size),
and DEATHSCREEN is nothing to do.

What is left -- the version-dependent commands that are still unhandled, and
the 5.12 and 5.15 builds to test against -- is in the plan.

## 10. What the client tells the server about itself -- DONE

INIT carries serialization 29, the protocol range 37...52 and the player
name; INIT2 carries the language code, which is **empty** and which this game
actually reads (`get_player_information().lang_code`, in the craft guide, the
creative inventory and the doc mod); CLIENT_READY carries a version of
5.15.0, a full version string of "buildat" and formspec API version 8.

DONE: the version is 5.17.0, which is the newest that speaks protocol 52;
the string beside it is "buildat luanti_client"; and the language code comes
out of LANGUAGE, LC_ALL, LC_MESSAGES or LANG, cut to the two letters a mod
expects, with "C" and "POSIX" meaning no language rather than "c".

Left: nothing here needs doing until a game is found that branches on the
version in a way this gets wrong.

## Moved out of the plan when it was frozen (2026-09-12)

### 7c. What PBR is still missing -- BUILT (2026-09-12)

With the checkbox in, the PBR render looks very nearly like the vanilla one.
Two reasons, both outside the shader:

- **Every node gets the same surface numbers.** `world.lua`'s `add_cube()`
  sets `roughness = 0.95`, `spec_strength = 0.2`, `bumpiness = 0.3` on all
  six tiles of every node, and never sets `translucency`, `spots` or
  `static_spots`. So VOXELSPOTS and VOXELTRANSLUCENCY are compiled in with
  nothing to do, and water is as matte as dirt. The atlas already derives the
  normal and spec maps from those six numbers per segment: the machinery is
  finished, it is being fed a constant.
- **There is no light in the scene at all.** All PBR adds over unlit today is
  the IBL cube map, which is dim and skyvis-attenuated. No direct light means
  no sun specular, no shadow map, no facets -- the direct half of PBR is off.

Also `zone.ambientColor` is `sunlight_color(factor)`, a warm white, so the
skylight term is untinted and lit and shadowed surfaces differ in brightness
but never in hue.

**Step 1: per-node surface parameters.** No shader change. Derive the six
numbers from what NODEDEF already carries, as one table with a fallback
heuristic, in a file of its own so a game can be argued with later:

| source | what it decides |
| --- | --- |
| `drawtype` LIQUID / FLOWINGLIQUID | roughness ~0.25, high `spec_strength`, `spots` ~0.1 animated, no bumpiness |
| `drawtype` PLANTLIKE / ALLFACES | `translucency` 0.5..0.8, `spots` ~0.15, roughness 0.8 |
| `alpha_mode` BLEND and not a liquid (glass, ice) | roughness 0.1, spec 1.0, `static_spots` |
| `groups.crumbly` (dirt, sand, gravel) | roughness ~1.0, spec ~0.1, high bumpiness; sand gets `static_spots` |
| `groups.cracky` (stone, ore, metal) | roughness 0.7, spec 0.4; ore names get `static_spots` |
| `groups.snappy`, wool, cloth | roughness 1.0, spec 0.05, no spots |
| `waving` 1 / 2 | whether the spots animate or hold still |
| `light_source > 0` | left matte; the point lights already carry it |

Name-substring fallback (`ice|glass|crystal|gem|metal|steel|water|sand|snow`)
for games whose groups say little.

Not doable: **per-node metalness.** The spec map's four channels are full (r
roughness, g spec_strength, b translucency, a spots) and `cMetallic` is a
per-material uniform, so per-block. Metal nodes read as very glossy
dielectrics. The upgrade path is a fifth channel or a second material, both
larger than this is worth.

**Step 2: sky-blue ambient.** One line: `zone.ambientColor` becomes the sky's
own colour -- already known, it is what feeds `cSkyColor` -- instead of
`sunlight_color()`. Since the shader's ambient is
`cAmbientColor.rgb * color.a + color.rgb`, that alone gives three distinct
tints: open sky blue-white, an overhang the same blue lower, a cave only the
warm `rgb` of torches. This is the "different tint per shadow type" item and
it costs almost nothing.

**Step 3: the sun as a real light -- the answer to the open question.** The
resolution is to make node lighting answer only *"am I underground"*, which
is the one question a shadow map cannot answer, and hand the canopy to the
shadow map.

The curve goes in `LIGHT_MAP` (world.lua), the 256-byte lookup from Luanti's
`param1` to buildat's `(lamp<<4 | sky)` nibbles. Built a second time for the
PBR path only: no C++ mesher change, and the vanilla path stays identical.

    sky' = 15 * smoothstep(2, 11, sky)

| Luanti sky | situation | remapped |
| --- | --- | --- |
| 15 | open sky | 1.00 |
| 11..14 | under a leaf canopy, under an overhang | 1.00 |
| 8 | a doorway, a window | 0.72 |
| 5 | a few nodes into a cave mouth | 0.26 |
| 0..2 | cave | 0.00 |

The knee at 11 is the tuning knob and lives next to the table as a named
constant.

With that curve in, the sun gate needs no thresholds of its own -- the
remapped `vSkyVisibility` *is* the gate, under a `VOXELSUNGATE` define so the
`builtin/voxel_shading` copy stays in step apart from the two lines it
already differs by:

    #ifdef DIRLIGHT
        diff *= vSkyVisibility;
    #endif

Full sun under the canopy (the shadow map does the work), no sun in a cave
(no light through rock), a smooth handover in the doorway band. One multiply;
all the numbers stay in the lookup table.

A `DirectionalLight` at `sun_direction(daylight_time)`, coloured
`sunlight_color(daylight)`, becoming the moon at night -- dim, blue, the same
gate; `sun_direction` already covers the whole 24000.

Shadow settings, picked biased for performance because there are to be no
graphics settings beyond the PBR checkbox itself:

- 2 cascades, split at about 24 and 96 voxels, fading from 0.8
- 1024x1024, `SHADOWQUALITY_SIMPLE_16BIT` (single-tap PCF)
- shadow distance about 96 voxels, well short of `far_clip`; past it the
  world is ambient-lit, which at that range reads as haze rather than as a
  missing shadow
- `biasAutoAdjust` on plus a slope bias -- voxel faces at grazing sun angles
  are the classic acne case

Two cascades over 96 voxels is roughly a quarter of the fill of the usual
four-over-far-clip. Too coarse means move the split, not the count.

Falls out of step 3 for free: sun specular on water and ice, facet sparkle on
snow and sand (`static_spots` are only visible under a direct light), and
leaves reading yellow-green against the sun (VOXELTRANSLUCENCY is dead code
without one).

Two details that bite if they are not planned for:

- **The shadow pass needs `ALPHAMASK` too.** `PBRVoxel.xml` declares it for
  the base pass; without it on the shadow pass every leaf casts a solid cube
  shadow, which under this design is the most visible thing on screen. Same
  for rooted plants and rails.
- **`PBRVoxelAlpha.xml` has no shadow pass**, so water, glass and ice cast
  nothing. That is the right default -- transparent things casting opaque
  shadows looks worse than them casting none -- but it means a glass roof
  lets full sun through. An accepted ceiling, not a discovery to make later.

`Light` and its `shadowBias` / `shadowCascade`, `CascadeParameters`,
`BiasParameters` and `castShadows` are all already in
`extensions/urho3d/safe_classes.lua` (checked 2026-09-12). What is missing is
on `Renderer`: `shadowMapSize`, `shadowQuality` and `drawShadows` are not
whitelisted, and a property missing there fails silently. That is the
whitelist work, and it is small.

Not proposed: SSAO (the mesher's baked AO is already in the vertex colours),
per-node metals, screen-space reflections, a second indoor cube map (the
shader's own header argues against it).

Order: steps 1 and 2 are independent of the rest and immediately visible.
Steps 3's three pieces -- the remap, the light, the gate -- only make sense
together; splitting them gives a world that is either flat-lit or
double-darkened at every intermediate commit.

#### What it turned out to be, against the plan above

Built as planned: `surface.lua` (step 1, with its own load-time checks and
`BY_NAME` covering water, lava, ice, glass, crystal, gem, diamond, mese, the
metals, snow, sand and ore), the sky-coloured ambient (step 2), `PBR_LIGHT_MAP`
with the knee at 2..11 and `VOXELSUNGATE` in both shader copies and both
technique XMLs, the sun with two cascades over 24 and 96 nodes at 1024x1024
`SHADOWQUALITY_SIMPLE_16BIT`, the `ALPHAMASK` shadow pass on `PBRVoxel.xml` and
none on `PBRVoxelAlpha.xml`, and `shadowMapSize` / `shadowQuality` /
`drawShadows` on the `Renderer` whitelist.

What the plan did not say:

- **A drawable casts no shadow unless it is told to, one by one.** Urho3D's
  `Drawable::castShadows_` defaults to false, so the shadow map rendered
  nothing at all and the sun lit the world flatly. `apply_to()` in world.lua
  now sets `cg.castShadows = pbr` where it sets the technique -- that is the
  one place every chunk's geometry passes through. The whitelist note in the
  plan said `castShadows` was already whitelisted, which it was; nothing was
  setting it.
- **A brightness of 2 is nowhere near enough.** Urho's PBR divides direct
  light by pi, multiplies by an albedo well under 1, and nothing tone maps
  afterwards. Measured on a grass field: at 2.0 the sun added about a sixth
  of what the sky ambient already gave, so neither the sun nor its shadow was
  visible. `SUN_BRIGHTNESS` is 18.0, which puts a lit face at about two and a
  half times a shadowed one.
- **The acne wanted a normal offset, not a bigger bias.** A voxel face is flat
  and wide, so slope-scaled bias alone leaves it striped. `BiasParameters`
  took only two arguments in the sandbox; it now takes Urho's third, the
  normal offset, and the sun uses `(0.00005, 0.8, 0.002)`. The offset is
  scaled by the cascade's ortho size inside Urho, so it is small: 0.6 there
  moves the lookup fourteen nodes and loses every shadow.
- **`BUILDAT_LUANTI_PBR`** starts the connect dialog with the checkbox
  ticked. A scripted run otherwise has to hit the box by pixel coordinates,
  and a miss looks exactly like the shader not working.

- **The sun and the sky had to be told apart.** `sunlight_color()` is Luanti's
  colour for sun and sky together, because together is the only way Luanti has
  them, and it is faintly blue. Used as the sun's colour with the sky already
  the ambient, the blue is applied twice and the whole world reads as being
  under water. The sun now has its own warm colour -- the same numbers the sky
  shader draws the disc with -- going the colour of the horizon tint as it
  comes down, and the ambient is the sky desaturated by half and taken at 0.7,
  because a surface sees the whole dome and not only the zenith.
- **The sun disc had to be allowed to clip.** It is brighter than anything
  else in the frame by orders of magnitude and nothing tone maps, so the only
  way to say so is to multiply the texture past one and clamp: the core comes
  out white and the texture's colour survives at the edges. Scaled back to
  nothing as the sun comes down, because a low sun is a dim one and its colour
  is the point of it.

- **It wanted HDR and a tone curve**, which the plan did not ask for and which
  is the thing that makes the rest work. In a frame that clips at one there is
  no sun brightness that is both visible and not flattening, so the sun stayed
  weak, its shadow stayed shallow and the sky's blue stayed half the light on
  a lit face. The PBR path now renders in HDR with bloom, the Uncharted2 tone
  curve and gamma correction -- the chain games/voxel_lighting already uses --
  and with it the sun is fifty times the sky, lit surfaces take the sun's own
  warm colour, and the tone curve lifts a shadow under full skylight back to
  shade. HDR and the render path are the renderer's rather than the
  viewport's, so the world hands them back when it goes away.

- **The spot fractions were an order of magnitude too high.** surface.lua asked
  for 0.15 of a plant's surface to be a spot at any moment, 0.20 of sand and
  0.30 of snow, against games/voxel_lighting's 0.03 for leaves, 0.05 for water
  and 0.04 for rock -- the same shader with the same constants behind it. A
  spot reflects at full strength whatever the rest of the surface does, so at
  those fractions a field of grass read as glitter paint. They are now scaled
  to voxel_lighting's, and the plants' translucency with them, which was 0.65
  against its 0.11.
- **Three things spread the sparkle away from the light, not one.** The tilt
  is the first: a spot turned up to 32 degrees off its surface catches the sun
  from anywhere within that angle of the mirror direction. The second is that
  the gloss was faded in linearly with the spot's own fade, so the half open
  cells -- which at any moment are most of them -- were wide dull highlights
  rather than small turns, a sheen following the light across a whole field;
  the fade belongs in the tilt, which already carries it. The third is the
  light through a leaf, whose forward lobe was a sixth power, wide enough to
  glow over a quarter of the sky: light coming through a leaf is light going
  the way it was already going. Measured on the dawn view, those three take
  the speckle count from 21120 to 2880, and what is left is gathered where the
  sun is. All three are about the moving kind of spot. The still kind's tilt
  was narrowed with them at first and had to be put back: a facet is a chip of
  rock that is flat and stays turned, so narrowing it takes the speckle off
  sand and gravel altogether rather than gathering it anywhere, which
  games/voxel_lighting's cave mouth view shows plainly.
- **The shader had to stop being one file in two places.** The plan said to
  keep `res/PBRVoxel.glsl` in step with the `builtin/voxel_shading` copy apart
  from the lines it already differs by, and that held while the differences
  were mechanism. It stopped holding the moment the constants were tuned: a
  good half of what is in there is an art style, and a Luanti world -- ground
  that is plants the whole way across, every one of them a spot candidate --
  wants different numbers from voxel_lighting's few sparsely spotted surfaces.
  Tuning through the shared file retuned voxel_lighting, which is how its rock
  lost its speckle without anybody asking. The two are a fork proper now: the
  built-in one is back to exactly what it was, both files say at the top what
  the other is and what differs, and a fix to the machinery is carried across
  by hand while a number that decides how something looks is not.
- **SPOT_TILT was what spread the sparkle away from the light.** A spot turned
  up to 32 degrees off its surface catches the sun from anywhere within that
  angle of the mirror direction, which put glints over a whole field instead
  of in the band where the light is actually being reflected; it is 0.18 now,
  and the still kind 0.15. Checked against voxel_lighting's own check.txt,
  whose look does not move: its spots are sparse enough that the tilt was
  never what was showing.
- **A glint coming out yellow means the light is yellow.** The sun had been
  warmed to 1.0/0.92/0.78 to make the daylight read golden, and a spot
  reflects the light as it is, so the spots came out the colour of the sun.
  What makes sunlight read as golden is the blue ambient beside it, not how
  warm the light is on its own, so the sun is games/voxel_lighting's
  1.0/0.96/0.88 and the glints are neutral again. The light also takes only
  half of the horizon's tint when the sun is down among it: sun_tint is the
  colour a band of sky is painted, which is deeper than the light painting it,
  and at the old full share a sun seven degrees up shone orange.
- **The moon is a fiftieth of the sun**, with a shadow map of its own, so that
  a night has moon shadows in it without being lit like a day. It keeps a day
  of its own rather than the sun's turned inside out: going by 04:30 and gone
  by 05:30, with the sun then half up, and back at 18:30, which is nine hours
  at full against the sun's twelve and means the two never overlap while
  either is making much light.

- **The weather had to reach the sun**, which the plan did not think of. A
  directional light does not know there is cloud between it and the ground,
  and the ambient does, because a game darkens the sky colours it sends; the
  sun was then the only thing left insisting on a clear day, and rain looked
  like sunshine with grey clouds painted over it. Two things say overcast and
  a game uses one or the other -- the density, of which only what is above
  Luanti's own 0.4 counts, and the cloud colour, which is the one VoxeLibre
  uses -- so both are read. What its server actually sends, and what those
  come out as, is checked where the reading is written. And a third, plainer
  than either: a game that turns the sun off has said there is no sun, which
  VoxeLibre does the moment the weather turns and a dimension with no sky does
  for good, so a hidden body's light goes out rather than being dimmed.
  Looking up wanted the same treatment: the density was being scaled by 0.85
  before it reached the sky shader, so at Luanti's own default this client
  covered a sixth of the sky where Luanti covers a quarter. It goes through as
  it came, because it already is a coverage -- Luanti fills a cloud cell where
  its noise falls below the density and the shader here fills where its noise
  rises above one minus the coverage, and both being value noise even about a
  half, the quantile carries straight across. Sampled over two hundred
  thousand points the two agree to within two parts in a hundred from nothing
  to a full sky. The cloud colour's alpha, which Luanti draws its clouds at,
  was being dropped on the way in and now is not; and the edge of a cloud is
  drawn thin rather than a darker grey, so that it blends into the sky.
- **Dawn and dusk are a window rather than an angle.** The sun's light took the
  horizon's tint by its own elevation, which is a band a couple of hours wide
  and reads as a very long sunrise. It is the half hour either side of the
  crossing now, at each end of the day, and the clouds take most of the sun's
  colour across the same window -- at that hour the sun is the only thing
  lighting them and it is lighting them from below, which is what makes a
  sunrise a sunrise rather than a sky that has got brighter.

Verified against VoxeLibre with the sun at time 8000: plants and trees cast
shadows on the ground, trunks and terrace faces are lit directionally, the
shadow map is clean of acne, and the sun reads as a light rather than as a
yellow patch. At time 5800 the world is a dim blue dawn with nothing blown
out.


### 15. A pause menu, and the key bindings in one place -- DONE

Asked for by the user (2026-09-10) and done before the merge, because it is
what makes the client usable by somebody who has not read its source.

What it came to: escape with nothing else up opens a menu with **Continue
playing** (a `button_exit`, which closes a form by itself -- asked for by the
user, because a menu whose only way back to the game is a key nobody was told
about is a menu that traps people), **Mute sound / Unmute sound** (Urho3D's master gain, so it covers the sources that
do not exist yet), **Key bindings** (the list, with Back) and **Exit** (the
disconnect and the window, the same path the window's own close button
takes). Escape no longer ends the session by itself.

Both are formspecs drawn by this client's own formspec code rather than
dialogs built by hand -- `open_local_form()` opens one whose fields reach a
function here instead of the server, which is four lines in
`send_form_fields()` -- so escape closing them, the styling and the button
hit-testing all came for free. That is worth remembering for the next
client-side dialog.

The bindings are one `BINDINGS` table at the top of init.lua that `move()`,
the key handler and the list all read; a key cannot now be in the code and
missing from the list. Not saved to disk and not editable yet. Two things
came out of writing it down: the movement keys are W/A/S/D only (the
`luanti.KEY_UP` names in `move()` are the protocol's own bit names for the
movement mask, not arrow keys -- an earlier draft of this plan had that
wrong), and the mouse and the hotbar number range needed entries of their own
because they are not looked up by key.

**And the debug lines start hidden** (the user's call): a player who opens
this wants to play, not to diagnose, and F5 brings them up -- which the key
list says. What this client has to say *to the player* -- that flying was
refused, that noclip is on -- now goes to the chat log instead of into those
lines, so hiding them costs the player nothing. A scripted run that wants to
read the counters presses F5 like anyone else.


**Found while comparing two builds (2026-09-10): a plant near water draws
as magenta and cyan stripes.** On VoxeLibre, at a shoreline south of a
mushroom island, the plants standing in the shallow water -- seagrass or kelp
by their shape -- are drawn as vertical magenta and cyan bars instead of
their own texture. It is in the build without any of the day's changes too,
so it is not new. Magenta and cyan bars are what an image read as the wrong
format looks like, and the shape of the bars says a texture modifier this
does not handle came out as something else rather than as nothing.

**Narrowed (2026-09-11), and the first guess was wrong.** texmod already
records every modifier it does not implement and init.lua logs each one once
the world is up; a full VoxeLibre session logs **none**. So whatever this is,
it is not an unhandled texture modifier.

What it is much more likely to be, found while looking: **`plantlike_rooted`
is drawn as a plant and nothing else.** Luanti draws that drawtype as a cube
of the node's own `tiles` -- the seafloor -- with the plant above it from
`special_tiles[1]`. This client maps drawtype 17 to `plant_quads` in
shapes.lua and `tile_expression()` only ever reads `def.tiles[i]`, so the
sea bed under kelp or seagrass is replaced by crossed quads wearing the
*ground* texture, and the plant's own texture is never used. Kelp's plant
tile is animated vertical frames, which is what a stripe would come from if
it were reached at all.

**Done for now**, and it is half of it: `plantlike_rooted` draws as a
**cube** of the node's own tiles, so the sea bed is a sea bed and the plant
is missing rather than the ground being missing.

**BUILT (2026-09-11), both halves.** `plantlike_rooted` draws its cube with
the plant standing on top of it, in the node above, out of `special[1]`; the
plant's quads wear tile 7, which is the definition's first extra texture.
The engine change is step 7 of `doc/plan/master_plan_history.md`.

**CONFIRMED ON VOXELIBRE (2026-09-12)**, at (-420, -7, -380) on the user's
own server, and it took three more fixes to get there:

1. The water around the base drew a surface, because the cube was part of
   the shape and a shaped voxel's neighbours draw their faces against it.
2. The fix for that carried its flag *inside the quad list*, and
   `VoxelDefinition.shape` walks every key of that table and throws on
   anything that is not a quad -- so all forty rooted definitions were
   thrown away and drawn as the placeholder cube. The sandbox caught the
   exception and logged "pcall(): Runtime error" with nothing else, which is
   why it read as a rendering fault rather than a registry one. The flag is
   a return value of `shapes.for_node()` now, and the test asserts the shape
   carries no key that is not a quad.
3. The base was then brighter than the sand beside it. Not a light value: a
   shape gets one flat light for the whole voxel, a face gets the light of
   the voxel in front of it with the occlusion of what stands around it. So
   `rooted_quads()` returns **only the plant**, and the cube is the voxel's
   own six faces -- `face_draw_type` stays `ON_EDGE` and the six tiles are
   resolved for it. The plant, which stands in the voxel above, is lit from
   there: `VoxelDefinition::shape_lit_from_above`, format version 12.

The lesson for the rest of this file: **a shape is for what is not the
voxel. Anything that fills the voxel should be its faces**, or it will be
lit and occluded unlike everything around it.

