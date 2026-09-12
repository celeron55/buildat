# Plan: a Luanti client in buildat

**FROZEN (2026-09-12).** Parked, not abandoned: the focus is `builtin/luanti`
until further notice, and this comes back **once that reaches feature parity
and the client half is what needs doing**. At that point the module's client
-- forked from this one -- and this one are the same problem and are worth
looking at with both on the table; working on it before then would mean
improving code the fork is about to copy. Meanwhile it is kept compiling and
working as the engine changes. See "Frozen" and "What is next" in
`doc/plan/master_plan.md`. What is still missing is below and stays accurate; nothing in it
is scheduled.

Working notes. Goal: `bin/buildat_client -m luanti_client`
against an unmodified Luanti server is a playable client of that server's
game — the world drawn the way the game means it to look, the player walking
in it, digging and placing, an inventory, and the presentation the game asks
for.

## The test server

Start it yourself; do not use one of the worlds that were already there, and
do not edit the games. A world is made by creating its directory under
`~/projects/luanti/worlds/` and writing a `world.mt` in it -- there is no
command that makes one -- and its name goes under a `buildat_test_` prefix.
What is there now:

    ~/projects/luanti/worlds/buildat_test_mcl/world.mt
        enable_damage = false
        creative_mode = false
        mod_storage_backend = sqlite3
        auth_backend = sqlite3
        player_backend = sqlite3
        backend = sqlite3
        gameid = mineclone2
        world_name = buildat_test_mcl
        server_announce = false

and it is started with the config in the job's tmp directory, which is what
turns damage off and hands every new player the privileges a test wants:

    cd ~/projects/luanti && ./bin/luanti --server \
        --world worlds/buildat_test_mcl --port 30001 \
        --config $CLAUDE_JOB_DIR/tmp/server.conf \
        --logfile $CLAUDE_JOB_DIR/tmp/server.log

`--worldname` will not create a world, only find one, so pass `--world` with
the path. The games are in `~/projects/luanti/games`: `mineclone2` is
VoxeLibre, which is what most of this was built against, and `exile` is worth
a second world -- it puts real text on the HUD where VoxeLibre's own bars
start hidden.

**Try every installed game, not only VoxeLibre.** There are twenty-five in
`~/projects/luanti/games` and most of them should work on the Luanti side, so
each is a free test of a different corner: `devtest` exercises every draw type
and every param2 kind on purpose, `exile` puts real text on the HUD,
`nodecore` and `realtest` are built out of node boxes and meshes,
`capturetheflag` and `repixture` lean on formspecs and HUD elements,
`dreambuilder_game` is a very large media set. What each one turns up is
content to implement rather than a bug to chase.

What the first full sweep said (2026-09-10), for a baseline to compare
against: fourteen games came up and drew their world -- devtest, exile,
extra_ordinance, mineclone2, minetest_game, nodetopia,
nonsensical_skyblock, pmb_core, prang, realtest, repixture, score, void,
voxelgarden, Wasteland -- and eight failed before a client ever reached
them, all on the Luanti side: capturetheflag and Eden2 on mod dependencies,
dives_ruris, dreambuilder_game, regnum, tutorial and whynot_game on Lua
errors while loading, nodecore on its own nc_doors passing a table where Luanti now wants a
string (twice, so it is not a race), and
Dungeontest on its own mapgen asking for a node it never registered. Those
eight are the games' business, not the client's.

One more thing the sweep found in the harness rather than the client: Luanti
refuses a player name longer than twenty characters, and "sw" plus a long
game name is longer than that, which reads as the game failing.

The heaviest game of the lot is nonsensical_skyblock: 3080 media files, 516
composed textures and 12399 voxel types, which the registry builds in 12.3
seconds of work. That is the number to watch if the build is ever made
faster.

Two lessons about the sweep itself. The pid of the shell that starts a
server is not the server's, so killing the wrong one leaves the old server
serving the new game's client -- the whole first sweep was invalid that way
and the giveaway was two games reporting exactly the same media count.
And do not rebuild the engine while a sweep is running: a client that starts
against a half-built binary fails engine_test and is counted as a failure of
the game.

`tmp/sweep.sh` in the job directory does the sweep: a world per game (created
the same way, `buildat_test_<game>`), the server started on 30001, the client
connected once, a screenshot and the client's log kept under `tmp/sweep/`, and
then both stopped. Run it, then read the screenshots and grep the logs for
what was not handled and which texture modifiers were not implemented -- those
two lines are what say where the next piece of work is.

**Damage off matters more than it sounds.** A driven client stands still
between commands, and at the VoxeLibre spawn that means a skeleton shoots it
dead inside half a minute: three sessions were lost to that before the
server was started with `enable_damage = false`.

The server logs at info level to the `--logfile` given above, which is where
to look when the client's own log does not say why something did not happen.

## How this gets tested

**A test game of its own (2026-09-10, the user's idea).** Pointing the client
at a fence corner or a rail crossing meant building one by hand, or hunting
for one in a world. So `games/buildat_testgame` in the Luanti tree is a copy
of Development Test with one mod added, `buildat_place`, that places what a
test needs:

    /bclear                   clear the air around you, floor under it
    /bnode <node> <x> <y> <z> one node, east, up and north of where you stand
    /bform [<name>]           a formation; with no name it lists them
    /bview <yaw> [<pitch>] [<x> <y> <z>]

The formations so far are rails (a run, a curve, a junction, a crossing), two
rail families side by side that must not connect, fences (the same five plus
one standing alone and one against stone), water two deep with a step in it,
and glass with something behind it. Add to them rather than placing nodes by
hand.

`/bview` is the one that changed how testing feels: the client turns with the
mouse and the harness's `mouse_move` is unreliable -- about 0.78 degrees a
pixel for the pitch against 0.1 for the yaw on this machine, and a big move
saturates the pitch clamp instead of aiming -- so the server sets the look
direction instead and the same frame comes out every time. It works because
the client honours MOVE_PLAYER's pitch and yaw.

The game is a copy and nothing depends on it: delete it and the tests that
use it stop, nothing else. The world is `worlds/buildat_test_testgame`, on
port 30004 in this session.


Nothing here is testable by looking at the code: the questions are whether the
server accepted what we sent and whether what came back looks right.

- **`lua extensions/luanti_client/test.lua`** runs the pure-Lua suites
  (serialize, connection, nodedef, media, player, texmod, inventory, formspec,
  objects). No engine, no server, a second to run; run it after every change.
- **`engine_test.lua`** checks the engine primitives the extension leans on
  against the engine's other way of doing the same thing, and `init.lua` runs
  it at boot, so a broken binding shows up before the connection does.
- **A driven client**: `bin/buildat_client -m luanti_client -c -` reads
  commands from stdin as they arrive, so a session can be steered from the
  shell — screenshot, look at it, decide the next command. The helper scripts
  live in the job's tmp directory:
  - `start.sh <name>` starts a client on the test server through a fifo,
    `stdbuf -oL` so the log is not block-buffered, and waits for `ready.sh`.
  - `ready.sh <log>` polls the log for the line the registry build writes,
    which is the last thing before the world is on screen. Do not sleep a
    fixed 25 seconds: with the media cached the world is up in under three.
  - `say.sh <line>...` feeds commands in, and refuses to write to a fifo
    nobody is reading any more.
  - `stop.sh` ends it. **`pkill -f buildat_client` also matches the shell
    running it** — use `pkill -x buildat_client`.
  - Writing to a fifo whose reader has gone blocks forever; that is what a
    hung shell command means.
- **Getting something to look at.** The server config's `default_privs`
  carries everything a test wants -- `give`, `teleport`, `settime`, `fly`,
  `noclip`, `privs` -- so a newly created player can help itself. An account
  that existed before a change to that keeps the privileges it had, so use a
  *new* player name after changing it.
  - `ADDR=127.0.0.1:30002 start.sh <name>` points the client at another
    server, and `NOENTER=1` keeps it from pressing Return on the connect
    dialog, which is what to do when the dialog needs clicking instead
    (`mouse_pos 640 434` then `mouse_click left` hits Connect).
- **How to place a voxel and then look at it**, which is most of a check of
  anything param2 does:
  1. `/giveme <item> [count]` in the chat dialog: `keypress T`, `delay 400`,
     `text /giveme mcl_furnaces:furnace`, `keypress Return`. The item names
     are in `~/projects/luanti/games/mineclone2/mods`; a wrong one answers
     "Cannot give an unknown item" in the chat lines at the bottom left.
  2. A number key picks the hotbar slot, and the status line names what is
     wielded, so a screenshot says whether the right thing is in hand.
  3. `/teleport <x>,<y>,<z>` to somewhere with room, then **K to fly**. Do
     not try to back away from what was just placed: the ground is a hillside
     and walking backwards goes down it and out of sight. Flying, `Space` to
     rise, is how to get a look at something from a few voxels away.
  4. `mouse_move 0 <dy>` pitches the view, 0.15 degrees a pixel, clamped to
     89 either way. **Aim by the counter line, which now says how many
     degrees down and round the player is looking**: saturate the pitch
     (`mouse_move 0 1500` is straight down) and come back a counted number of
     pixels, so `mouse_move 0 -427` from there is 25 degrees of depression --
     which points at the ground about three voxels ahead. Guessing at
     relative moves wastes runs, because where the pitch started depends on
     what the server saved for that player.
     Placing puts the voxel one voxel
     from the face that is pointed at, which is close enough to the camera to
     fill the screen, so rise and back off before the screenshot.
  5. `magick <shot>.png -crop WxH+X+Y -resize 300%` on the voxel itself. The
     status line says what is pointed at, which is how to tell that the voxel
     that was placed is the one being looked at.
  6. The server's log is the record of what was actually placed and where:
     `grep "places node" debug.txt`.
- **What is worth placing.** A furnace is a cube whose six tiles all differ,
  so it says whether facedir moved the right tile to the right face. A stair
  is a node box with a facedir. A ladder is a wallmounted node box, a sign a
  wallmounted quad. VoxeLibre's chests and torches are `mesh` nodes, so they
  are drawn as placeholders until mesh voxels work and are no use for a
  facedir check.
- **`magick <shot>.png -crop WxH+X+Y -resize 200%`** to read the counters or a
  corner of a form; the status text is two lines under the top left corner.
- **The counters on screen** are the fastest diagnosis there is: state,
  position, what is pointed at, objects, blocks received / in scene / to mesh,
  microseconds to hand a block over, param2 pairs, media files and how many
  are still to come.
- **`add_line()` goes on the screen, not into the log.** Anything a script has
  to wait for needs a `log:` line of its own.
- **The server's log** is `/home/celeron55/projects/luanti/debug.txt` at info
  level: it says whether the server accepted a dig, a place or a chat line,
  and complains when the client sends something wrong.
- **Compare against the real client.** A screenshot of Luanti's own client
  side by side settles what a form or the sky is supposed to look like.

## Decisions

- **Target Luanti 5.11.0 up to 5.17.0**, which is protocol 46 up to 52, with
  mapblock serialization 29 throughout. Written against the newest so far;
  see "Older servers" in what is next for what the rest of the range asks
  for. HELLO refuses anything that serializes mapblocks older than 29 rather
  than carrying a second parser.
- **Engine additions are generic, the Luanti shape stays in Lua.** So far:
  `buildat.compress`, `pack_voxel_volume`, `add_resource_dir`,
  `compose_image`, `VoxelDefinition.shape`, the `UIMouseClick` event. The rule
  to keep: if a primitive can only be described in Luanti's terms, it is in
  the wrong place.
- **The extension does not need buildat's own voxelworld.** That is a
  server-driven module; this is a client talking to somebody else's server.
  `voxel_shading` is a different matter: its PBRVoxel technique is what the
  "Enable PBR" option draws with, so the parts of it that do not depend on
  voxelworld have to be usable on their own.
- **Ask the server for all of its media at once**, the way Luanti's own
  client does, rather than working out which files the definitions need.
  Wasteful in theory; in practice what costs is inserting definitions and
  media, and asking as you go turns that into a rebuild per batch. See step
  1.
- **The Luanti-native look is the default and PBR is an option.** The player
  turns it on in the connect dialog; the client then pays for the atlas's
  normal and surface maps, which the default look does not build at all.
- **Rendering does not have to match Luanti's.** Buildat-isms and more modern
  techniques are fine as long as the textures (texture modifiers included) and
  the voxel shapes are respected. Lighting may be fancier and its curves need
  not match.
- **Buildat terminology.** A Luanti "node" is a *voxel*. In buildat a node is
  a scene node (or a graph node in an algorithm). Engine documentation says
  voxel; the Luanti extension may say node where it is quoting the protocol.

## Decisions (continued)

- **The inventory cube is a shear, not a render target.** `compose_image` got
  one operation that maps an image onto a parallelogram; the cube is three of
  them. Measured against the alternative: composing a PNG is 0.37 ms and the
  file persists, so a whole game's cubes are about a second once and nothing
  afterwards, while a render target needs a readback stall per item and no
  disk cache. Render to texture stays on the list as the general primitive,
  after the more important steps -- see step 12.

## What is done

The finished work is in `doc/plan/luanti_voxels_history.md`, with the reasoning
that went into each piece. What is left is what this file holds.
## Facts worth keeping

Protocol and formats, all checked in Luanti's source:

- Mapblock at ser 29: `v3s16 pos`, then one zstd frame holding
  `u8 flags | u16 lighting_complete | u8 content_width (2) |
  u8 params_width (2) | 4096 u16be param0 | 4096 u8 param1 |
  4096 u8 param2 | node metadata`, then a `u8` outside the frame.
- Voxel index order is x fastest, then y, then z, which is PolyVox's order.
- `param1` is light: **day in the low nibble, night in the high one**.
- `param2` is whatever `paramtype2` says: a palette index, a facedir, a
  level, a wallmounted direction.
- Fixed content ids: `CONTENT_UNKNOWN = 125`, `CONTENT_AIR = 126`,
  `CONTENT_IGNORE = 127`.
- Positions on the wire are in BS units (BS = 10): MOVE_PLAYER is three f32 of
  `voxels * 10`, PLAYERPOS three s32 of `voxels * 1000`.
- **Acceleration crosses the wire pre-multiplied by BS and Luanti multiplies
  it by BS again** (`handleCommand_Movement`, then `LocalPlayer::move`), while
  speeds get BS once. In voxel units the effective acceleration is therefore
  ten times the wire value.
- Luanti's yaw is degrees with 0 towards +Z, growing **counterclockwise seen
  from above** (Irrlicht's `rotateXZBy` is right-handed) where Urho3D's grows
  clockwise; its pitch is positive looking **down**, which Urho3D's euler
  pitch is too. The server only sends the blocks it thinks the player can see
  (`GetNextBlocks` builds a cone from the reported angles), so a wrong angle
  is a hole in the world.
- **A block is acknowledged as soon as it arrives and the server never sends
  an acknowledged block again.** Dropping one loses it for the session.
- The server sends no light with TOCLIENT_REMOVENODE; Luanti's own client runs
  a light flood there. This one takes the brightest neighbour and dims it by a
  step, which is right for digging into the light and lags behind otherwise.
- `serializeString16Array` is `u32 count | every u16 length | every string's
  bytes` — not a list of length-prefixed strings.
- ContentFeatures is versioned (13 now) and each definition sits inside its
  own length-prefixed wrapper, so reading the front and skipping the rest
  survives a newer server.
- The tile order is `+Y, -Y, +X, -X, +Z, -Z`, which is buildat's
  `VoxelDefinition.textures` order too.
- Formspec layout: units are inventory slots;
  `imgsize = min(min(w,h)/15, padded/size)`; real coordinates are on iff
  `formspec_version >= 2` or `real_coordinates[true]`; legacy spacing is
  `imgsize*(5/4, 15/13)` and padding `imgsize*3/8`.

buildat and Urho3D:

- A buildat voxel and a Luanti node both occupy the cube centred on their
  integer coordinate, so Luanti coordinates are Urho3D world coordinates one
  for one.
- The vertex colour contract of `set_voxel_geometry(use_skylight = true)` is
  in `src/interface/mesh.h`: the shader computes
  `ambient = cAmbientColor.rgb * vColor.a + vColor.rgb`. **No technique is
  set** by the mesher; whoever asks for skylight supplies one.
- Urho3D 1.7.1's CoreData has no alpha-masking technique and its Lua bindings
  expose no `ResourceCache::AddResourceDir` — hence `buildat.add_resource_dir`
  and `client/data/Techniques`.
- **A Urho3D UI element is disabled until told otherwise, and a disabled
  element is not hit by a click** — no element under the mouse means no click
  event at all, not merely no target.
- `CustomGeometry` has no index buffer and `DefineVertex` is a sandbox call
  per vertex, so real amounts of geometry have to be built in the engine.

What this server asks for, counted from its 2582 voxel definitions:

- Draw types: 1373 nodebox, 709 normal, 277 mesh, 102 plantlike, 40
  plantlike_rooted, 22 airlike, 19 allfaces_optional, 17
  glasslike_framed_optional, 7 raillike, 4 liquid, 4 flowingliquid, 3
  signlike, 3 firelike, 2 glasslike.
- Texture modifiers by tiles using them: `colorize` 1226, grouping 717,
  `multiply` 408, `transformR90` 375, `hsl` 300, `combine` 293, `opacity` 282,
  `transformFX` 260, `resize` 156, `mask` 96, `transformFY` 89,
  `transformR180` 75, `transformR270` 53, `verticalframe` 39, `transform46`
  24, `noalpha` 10, `brighten` 6, `lowpart` 1.
- Palettes: grass, foliage and water are a greyscale texture plus a palette
  (`mcl_core_palette_grass.png` and friends) indexed by `param2`.

## What is next

In order. Each step is a commit that leaves the client working.

**Found while playing and since fixed:** the light not following a node
change, and a public server's world loading around the wrong place. Both are
in the history file; the second one is worth reading before touching the
position the client reports or the fields a form sends back.

**POSSIBLY FIXED (2026-09-12); deprioritised.** The `plantlike_rooted` work
below is the most likely cause and it is built and confirmed on VoxeLibre, so
the original symptom has probably gone with it -- but nobody has stood at the
shoreline since to look. Worth one glance next time a VoxeLibre session is
running anyway; not worth a trip of its own.

The diagnosis, and the `plantlike_rooted` work that came out of it, are in
the history file.

**The engine change, as it was decided (the user's call, 2026-09-11): a
definition gets a variable-sized list of extra textures.** The argument for it is the general one -- an empty list costs
nothing, and a definition that has one is a definition that needed it -- and
the shape of it is a refinement rather than a replacement of what is there:

- `VoxelDefinition::textures[6]` **stays exactly as it is**, so the cube
  mesher and its inner loop do not change and pay no indirection. Six faces
  are six faces.
- A new `sv_<AtlasSegmentDefinition> extra_textures` beside it, for quads
  that want a texture of their own. Empty is the common case and is a
  pointer, a size and no allocation.
- `VoxelQuad::tile` is already a `uint8_t` and the mesher already writes
  `quad.tile < 6 ? quad.tile : 0`. That clamp becomes the dispatch: 6 and
  over is `extra_textures[tile - 6]`.
- `CachedVoxelDefinition` gains the matching `sv_<AtlasSegmentReference>`,
  and the registry's serialization gains a count and a version bump.

**It unblocks two recorded items, not one**, which is what settles it:

1. This one -- a rooted plant's cube plus the plant from `special_tiles[1]`.
2. **Liquids** (section 5): Luanti draws a liquid from its *special* tiles,
   the animated ones, and this client draws it from the ordinary six, so
   VoxeLibre's water wears its still texture where it should wear the
   flowing one. Same change, same reason.

Luanti's own `special_tiles` is six, so six is the natural first size, but
nothing here should assume it.

**Frame smoothness (2026-09-10, the user's ask), and what the log says it
is.** The world loads reliably now; what is left of "it does not feel right"
is the stutter. So the client logs a line for every frame whose Lua time or
whose block hand-over is more than three times the running mean of it --
`slow_frame_check()` in init.lua, rate limited to five a second and counted --
with what else that frame was doing: the blocks it meshed and the worst single
one, how many param2 pairs it registered, how long the commands took and
**which command was the worst, by name and size**, the dirty and waiting
counts, and the previous frame's own length.

Measured on VoxeLibre, walking at the spawn. Three causes, and the biggest
one is not the mesher:

1. **ACTIVE_OBJECT_REMOVE_ADD, up to 613 ms in one command.** 3795 bytes took
   613 ms; 1559 took 282; 455 took 147; 363 took 122. That is the objects
   arriving, and each one is built the instant its packet is read: parsed,
   its model read (a .b3d parsed in Lua the first time each model turns up),
   its geometry built, its textures resolved. A crowd of mobs coming into
   range is a half-second freeze.

   **DONE (2026-09-10)**, in two parts, and the second one is where the time
   actually was.
   - An object that arrives is read and remembered, and its visual is built
     by `flush_objects()` in init.lua on a 3 ms budget, a few a frame, with
     at most one model read per frame -- reading a .b3d is tens of
     milliseconds of Lua with nothing to spread it over. The `visual_stale`
     rebuilds go through the same queue. With that, the command itself is
     down to the 4 ms the rest of a frame's packets cost.
   - That moved the cost rather than removing it: one object was then 250 ms
     of its own frame. A "slow object" line -- which object, which visual,
     which model, and whether the model had to be read -- said why: a
     skeleton took 250 ms *with its model already read*, so what cost was
     building the geometry, which is `CustomGeometry:DefineVertex` once per
     vertex through the sandbox, twelve of them a quad. And every skeleton
     in the world paid it again.

     So the first object of a kind -- one model with one set of textures --
     now builds a template node that is not drawn, and every other object of
     that kind is `Node:Clone()` of it, which Urho3D copies through the
     component's attributes inside the engine. The materials are not
     attributes it can copy (a Material made in Lua has no resource name),
     so they are set on the copy and shared with the template, which is also
     what keeps them alive. `Node:Clone` is new in the sandbox.

     Measured on VoxeLibre, walking the spawn: eleven slow-object lines for
     the eleven kinds in range instead of one per mob, frames settling at
     12-20 ms, and four objects built in one 43 ms frame. Verified drawn with
     `/bentity testentities:mesh 4` in the test game -- a row of four, all
     wearing their texture, of which three are copies.

   What is left of this item: the **first** object of a kind still costs its
   frame -- 250 to 440 ms for a mob with a big model -- because the model
   read and the template build are one lump each. Splitting them wants either
   a budget inside the .b3d reader or the geometry built in the engine, and
   the second is the one that ends it: the mesher already builds voxel
   geometry there, and an object's quads are the same shape of data.
2. **One mapblock costing 22 to 36 ms** while the mean hand-over is 2 to 6.
   The frames that do it are the ones registering new param2 pairs (4 and 7
   of them in the two worst), which is a voxel definition and an atlas
   segment -- a texture upload -- each. And MESH_BUDGET_US is only checked
   *between* blocks, so one expensive block overruns the 4 ms budget by a
   factor of nine. Two fixes: register pairs on their own budget rather than
   inside the mesh loop, and count the overrun against the next frame.

   **Asked by the user (2026-09-10): could the param2 nodes move to the
   flexible mesher instead, so that nothing has to be registered when a new
   param2 turns up?** Half of them could, and it is not the expensive half.
   What param2 does splits three ways:
   - **Geometry** -- a facedir or wallmounted shape turned, a flowing
     liquid's level. The second mesher already works a liquid's corner
     heights out per voxel, and a rotation of four corners is the same kind
     of work, so this could be per voxel and per definition instead of per
     pair. Turning the shape in the mesher is the right way to do it rather
     than a shape per facedir at registration: 1373 nodebox definitions
     times 24 rotations is tens of megabytes of quads, and the rotation is
     twelve multiply-adds a quad.
   - **Which tile a cube's face wears, and how far it is turned in it** --
     a facedir on a cube. This is a permutation of the six atlas segments
     the definition already has, so the polyvox fast path could apply it
     from the voxel itself and keep its face culling; nothing new is
     registered either way, because `find_or_add_segment()` gives a variant
     with the same resource names the segments the parent already has.
   - **A palette colour** -- and this is the expensive one, because a tint
     is a *texture*: a composed image (0.37 ms each, measured) and an atlas
     upload. The mesher cannot help with it at all; a tint would have to
     reach the shader as vertex data, and the vertex colour is already the
     baked light with no channel to spare.

   And there is a blocker under all of it: **param2 has nowhere to travel**.
   `VoxelInstance` is one `uint32_t` with the id in bits 0...20 and the two
   light nibbles in 24...31, which leaves three free bits where a facedir
   wants five. Making room means widening VoxelInstance (which is what the
   volumes serialize, so buildat's own saved worlds change format), shrinking
   VOXELTYPEID_MAX, or narrowing the light -- an engine-wide change for the
   cheap half of the problem.

   **So what to do instead**, and it is smaller than either: keep the pair
   registry, and (a) do the registering off the mesh path with a budget of
   its own, which is the fix above, and (b) for a definition whose param2 is
   a palette index, register the palette's distinct colours when the
   definitions arrive, behind the loading panel that is already up. The count
   is known up front -- the palette's entries, for the handful of definitions
   that have one -- so no tint is ever composed mid-frame, and what is left to
   turn up while playing is a facedir or a liquid level, which costs a
   registry entry and no texture work. If the hitch survives that, the
   measurement to make first is *which* pairs cost: the slow-frame line
   counts them but does not say what they were.

   **Then measured (2026-09-10), and it moves the answer.** (b) was written
   and run against VoxeLibre: the palette pairs registered at load, 5701 of
   them, and the slow-frame lines came out saying "0 new param2 pairs" -- and
   the block spikes did not go away. One block still cost 32 ms with no pair
   registered at all, and the same spikes are there in the build without the
   change. Composing the tints is not what costs either: a cold texture cache
   composed 407 of them and the whole registry build was 3678 ms against 3607
   warm, so the composition is under a tenth of a millisecond each. What the
   change did cost is 2.6 s of loading time, for 5701 voxel definitions of
   which a world uses a handful.

   So it was **reverted**, and the diff is kept in
   a `tried_eager_param2_pairs.diff` outside the repo rather than thrown
   away. What the
   measurement points at instead: a block's spike is the **first sight of a
   node type**, whose six textures are then loaded from disk and drawn into
   an atlas -- `find_or_add_segment()` inside the mesher's `get_cached()`,
   which is 3406 files for this game. That is why it happens on the frames
   that mesh a block full of nodes nobody has seen yet, whatever their
   param2. The fix that would actually move it is an **eager caching pass at
   load**: walk the registry's ids and call `get_cached()` with the atlas
   registry on each, on a budget, behind the loading panel. That wants one
   new binding -- the registry's `get_cached` is not in the sandbox -- and it
   is the same shape as the registry build itself. Carrying the mesh
   overrun into the next frame is worth having beside it, but it moves the
   spike rather than removing it.

   **Done (2026-09-10), on the `voxel-format` branch.** The engine grew a
   voxel format a game chooses, and this client now uses Luanti's own cut:
   a 16-bit id, param1 as two light nibbles, param2 as the param. What
   param2 says about a voxel's *shape* -- a facedir, a 4dir, a wallmounted
   direction, a flowing liquid's level -- is now variants of one voxel
   definition rather than a voxel type per (definition, param2) pair, so a
   facedir costs 23 variants of one type instead of 24 types. A palette
   colour still costs a voxel type with its own composed textures, because a
   tint is a texture and the vertex colour is the baked light with no
   channel to spare, exactly as the third bullet above says. So the split in
   the three bullets held up; the middle two are gone and the expensive one
   is not. See `doc/plan/voxel_data_model_plan.md`.

   What this does **not** fix, and the measurement above already said so:
   the block spikes, which are the first sight of a node type and its
   textures going into an atlas. The eager caching pass is still the fix
   worth making, and it is still unwritten.

   **The follow-up the user asked (2026-09-10): Luanti's node is 32 bits --
   16 of id, 8 of param1, 8 of param2 -- and a VoxelInstance is 32 bits too,
   so if everything param2 does moved into the flexible mesher, could this
   client's voxels simply use Luanti's own bit allocation?** Nothing
   fundamental prevents it. What it touches, and what has to be decided:

   - **The bits are there.** A VoxelInstance today is the id in bits 0...20
     (VOXELTYPEID_MAX is 1398101), the sky light in 24...27 and the lamp
     light in 28...31, which leaves three free bits -- not the five a facedir
     wants. Luanti's layout instead is id 16, param1 8, param2 8, exactly 32.
     So the change is a re-cut of one word rather than a wider one.
   - **16 bits of id is enough, and that is worth saying plainly**: this
     game has 2582 node definitions, and the (definition, param2) pairs that
     turn up in play were measured at 5701 when every palette colour is
     registered. Eight thousand of 65536. Even keeping a voxel id per palette
     colour -- which is the one thing the mesher cannot take over, because a
     tint is a texture rather than a shape -- the id space is not the
     constraint. What forces more than 16 bits today is nothing; the pairs
     were never the reason.
   - **What the mesher has to gain**, and it is the real work: a shape turned
     by a facedir or a wallmounted direction per voxel (twelve multiply-adds
     a quad, the same kind of per-voxel work `liquid_corner_top()` already
     does), a flowing liquid's level per voxel, and -- for the cube fast path
     -- the tile permutation and the quarter turn a facedir gives each face,
     read from the voxel rather than baked into a definition. The last one is
     what keeps facedir cubes on polyvox with its face culling instead of
     turning them into shapes.
   - **What has to move with it**: `VoxelInstance`'s accessors and
     `VOXELTYPEID_MAX` (src/interface/voxel.h), the mesher's light reads
     (src/impl/mesh.cpp), `pack_voxel_volume`'s `field` values, which are a
     documented Lua-facing contract naming the bit ranges
     (doc/client_api.txt: id 0...20, skylight 24...27, lamplight 28...31,
     and a new one for param2), and the LOD paths that read the same bits.
   - **Two things to decide rather than write.** First, buildat's own
     `module/voxelworld` serializes volumes to disk as raw words
     (`serialize(VoxelInstance)`), so a re-cut invalidates any saved world of
     its own -- either a version byte or an accepted break. Second, the
     palette colours: keeping an id per colour is the cheap answer and fits,
     but it leaves the (definition, param2) map machinery in place for them,
     so the *simplification* this change promises is partial.
   - **What it is worth.** Not the stutter: the measurement above says the
     block spikes are a node type's textures being loaded and put in an atlas
     the first time it is seen, not the pairs. What it does buy is that the
     block ingest becomes a straight copy of Luanti's three arrays into one
     word with no map compiled per (id, version) and no Lua scan for pairs,
     that nothing has to be registered while playing, and that the client's
     voxel word says what a Luanti node says -- which is the honest shape for
     a Luanti client. That is a good change to make deliberately, and a poor
     one to make in a hurry.

   **And the user's constraint (2026-09-10): buildat's native system is not
   to be modified -- can the *game* decide which bits are id and which are
   parameters?** Yes, and it comes out better than re-cutting the constants,
   because nothing existing changes its meaning. Three ways, in the order
   they are worth:

   1. **Make the split an argument rather than a constant.** The two places
      that decide what a word means are the writer and the mesher's decode:
      - `pack_voxel_volume()`'s `field` is today a fixed enum naming bit
        ranges ("id" 0...20, "skylight" 24...27, "lamplight" 28...31,
        "light", "raw"). Give it a general form -- a shift and a mask the
        caller passes -- and the game writes whichever bits it has decided
        are its own. The existing names stay as they are, as shorthands.
      - `generate_voxel_geometry()` and `generate_voxel_shapes()` gain two
        trailing arguments with defaults, an id mask and a param shift/mask.
        Default: mask 0x1fffff and no param, which is exactly what happens
        now. The mesher's internal `v.get_id()` reads go through one
        accessor that applies them.
      `VoxelInstance` keeps its accessors, the registry keeps its array
      (indexed by the masked id, so a 16-bit game gives it at most 65536
      entries and it never sees a param), and no other game's behaviour
      moves. **This is what I would do.**
   2. **A parallel param plane.** The mesher takes an optional byte per
      voxel alongside the volume, and the game fills it with Luanti's param2
      array as it arrives. Nothing about the voxel word changes at all, not
      even in an argument. It costs a second buffer and a second copy per
      block, and it means two things to keep in step instead of one.
   3. Re-cutting `VOXELTYPEID_MAX` and the light bits, which is what the
      paragraphs above worked through. Ruled out by the user's constraint,
      and it was the most invasive of the three anyway.

   One piece of luck worth writing down: **the light needs no thought at
   all.** Luanti's param1 is a day nibble and a night nibble, and this
   engine already keeps the sky light in bits 24...27 and the lamp light in
   28...31 -- the top byte, in the same shape. So Luanti's 16 + 8 + 8 falls
   out as id 0...15, param2 16...23, param1 24...31 with the light bits and
   the vertex-colour contract untouched.

   What none of the three changes is the work: a definition still has to say
   what its param *means* (a facedir, a wallmounted direction, a liquid
   level, nothing), the mesher still has to turn a shape or pick a level per
   voxel and permute a cube's tiles, and a palette colour is still a texture
   rather than a shape, so those keep an id each.

   **Generalised, on the user's cases (2026-09-10): a physics game with
   eight voxel ids and three 8-bit parameters, or a node painter using the
   whole word as a palette index or as 8-bit RGBA.** Those are the right
   cases to design against, and they turn "an id mask and a param" into a
   **declared word layout**, which is barely more work and is where this
   should land:

   - **The declaration lives on the registry**, not in the mesher's
     arguments: a registry is what says what a world's voxels are, the
     mesher is already handed one, and it can read the layout once per chunk
     into locals. So the mesher's signature does not change at all -- less
     invasive than the two arguments sketched above -- and the layout travels
     with the registry when it is serialized to a client (a version byte in
     voxel_cereal.h). Shape of it: a field per role, each a shift and a
     width, with today's layout as the default.
   - **The light has to be part of the declaration**, and this is the first
     thing the general case forces. `use_skylight` reads bits 24...27 and
     28...31 today as constants; a painter that spends all 32 bits on colour
     has no light bits at all, so the layout needs a light field that can be
     absent -- and the mesher has to hoist "is there light?" out of the
     per-voxel loop rather than testing it per face.
   - **An id field of zero bits is a case worth supporting**, because it is
     what the painter is: every voxel is the same definition -- one painted
     cube -- and everything that differs between voxels is parameters. It
     also keeps a game honest about the registry: with three bits of id the
     registry holds eight entries, and nothing else in the engine has to
     know.
   - **A per-voxel colour wants a home in the vertex data**, and this is the
     second thing the general case forces -- the one real design question.
     The mesher writes light into the vertex colour (rgb the bounced and lamp
     light, alpha the sky factor: see the contract in interface/mesh.h), so a
     game's own RGBA has nowhere to go as things stand. Two ways:
     multiply it into the light-derived rgb, which is exactly what an unlit
     voxel shader wants and is what Luanti does with its palettes, or give it
     a channel of its own -- CustomGeometry has a second texture coordinate
     and a tangent going spare -- which keeps light and colour separable for
     the PBR path. **DISCUSSION NEEDED**: the first is a few lines and is
     right for this client; the second is the general answer and costs a
     vertex attribute and a shader that reads it.
   - **What this buys the Luanti client specifically**: if a declared colour
     field can reach the vertex colour, then Luanti's palette param2 stops
     needing a voxel id per colour -- which is the one thing I said above the
     mesher could not take over. Then the 16 + 8 + 8 layout really is one
     voxel id per node id, and the (definition, param2) pair machinery goes
     away entirely rather than being kept for the palettes.
   - **A general accessor for the game's own reads.** A physics game reading
     its three parameters wants them from Lua and from its own C++: one
     registry-aware accessor (`layout.field(v, i)`) rather than each game
     shifting by hand, and `pack_voxel_volume`'s `field` resolving names
     through the same layout, so the writer and the reader cannot disagree.

   The cost of the whole thing is a shift and a mask from a local instead of
   a constant in the mesher's inner loop, which is nothing, plus the
   discipline that every place reading a voxel word goes through the layout.
   The gain is that "what a voxel word means" stops being an engine decision
   and becomes the game's, which is what buildat says it is about everywhere
   else.

   **Two larger generalisations the user raised (2026-09-10): a
   game-chosen word width -- 8, 16, 32, 64, even 128 bits -- and auxiliary
   parallel volumes carrying the extra parameters.** They are alternatives to
   each other, and the second is the better one.

   - **The width.** PolyVox is built for it: `pv::RawVolume<VoxelType>` is a
     template, so a narrower or wider *scalar* is its natural way. The
     friction is all on buildat's side, where `pv::RawVolume<VoxelInstance>`
     appears in 51 places across the interface, the mesher and the bindings,
     none of them templates. Making the width a game's choice means either
     templating the mesher (moving a large body of code into headers and
     instantiating it per width -- 8/16/32/64 is four copies of it) or
     reading the word through a runtime stride, which puts a branch in the
     hottest loop in the engine unless the loop itself is specialised per
     chunk. Worth having at the narrow end for its own reason: a painter with
     eight ids in an 8-bit word is a quarter of the memory and a quarter of
     the bandwidth of the same world at 32 bits, and the mesher reads a
     voxel's neighbours six to twenty-six times over, so that is the axis
     that pays. **128 bits is where the scalar model breaks** -- there is no
     native integer, so it becomes a struct and every shift and mask becomes
     multi-word -- and that is exactly the case the planes below do better.
   - **The parallel volumes**, and this is what I would build. One plane per
     kind of thing, all over the same region: the id-and-light word the
     mesher reads for every voxel and every neighbour stays narrow and hot,
     and a parameter only some code cares about -- physics, an RGBA colour,
     metadata -- lives in a plane of its own that only that code touches.
     That is structure-of-arrays against array-of-structures, and this access
     pattern is the one where SoA wins. It also lets a game add a parameter
     without changing the type everything else was compiled against, and
     "128-bit voxels" becomes four 32-bit planes with no new integer type.
     What it costs: a pointer and an index per plane read, an allocation and
     a copy per plane per block, and the ray casts and physics helpers have
     to be told which plane holds what -- which the declared layout above
     already exists to say.
   - **How they fit together.** The layout declaration is the part that has
     to come first either way: it is what names a field, whichever plane and
     whichever width the field lives in. `pack_voxel_volume()`'s destination
     spec gains a plane, and then ingesting a Luanti mapblock is three
     straight copies -- param0 through a map into the id plane, param1 into
     the light plane, param2 into the param plane -- with no read-modify-
     write per voxel per source, which is what it does today.
   - **What this client needs from it: nothing beyond 32 bits.** Luanti's
     node is 16 + 8 + 8 and fits the word that already exists. So the planes
     are the engine's growth path and the honest place for them is a
     buildat design note rather than this plan; what this plan wants is the
     declared layout, and to not have to fight it later.

   **Then the user asked (2026-09-10): is the gain for a game that wants
   maximum voxel mass with little per-voxel information enough to make a
   plane 16 bits deep, even though luanti_client would then need two or
   three planes?** The gain is real but it is not in the mesher's inner
   loop, and the answer is to make the depth **per plane** rather than to fix
   it at 16.

   Where a narrower plane pays, and where it does not:
   - **Not in one chunk's meshing.** A padded 18x18x18 block is 5832 voxels:
     23.3 KB at 32 bits, 11.7 KB at 16. Both fit in L2 with room to spare,
     and the mesher walks x-fastest so a voxel's x-neighbours are the same
     cache line and a z-slice is 1.3 KB. The sliding window is a few
     kilobytes either way.
   - **Yes in how much world there is.** A game whose point is voxel mass
     doubles what fits in RAM, halves what it copies between threads and
     halves what it serializes before compression. That is a first-order
     win and it is exactly the case the user named.
   - **And yes, a little, in the neighbour scans.** The id plane is the one
     read six to twenty-six times per voxel -- face culling and the
     definition lookup -- so halving *that* plane is the part of the mesher
     that would notice. Which is an argument for splitting rather than
     against it.

   What splitting costs this client: nothing much, and possibly less than
   nothing. Three planes for a padded block are 11.7 KB of id, 5.8 KB of
   param1 and 5.8 KB of param2 -- the same 23.3 KB in total as one 32-bit
   word, with the hot stream at half its present size and three sequential
   streams instead of one, which a prefetcher handles. Ingest gets cheaper,
   not dearer: three straight copies instead of a read-modify-write per
   voxel per source.

   Two things to write down before anyone builds it:
   - **A voxel change stops being one store.** Today a word is written
     atomically; with planes an id and its param are two writes, and a
     reader can see one without the other. The mesher works on its own
     padded copy, so it is safe as things stand, but anything that reads a
     live volume from another thread has to be told this.
   - **A 16-bit id plane caps the registry at 65536 definitions**, which is
     fine for Luanti and for a mass game and not for everyone -- which is
     the argument for per-plane widths (8, 16, 32) over one fixed depth. If
     a single depth had to be picked, 16 is the better default than 32; but
     fixing it would push Luanti's param1 and param2 into a 16-bit plane
     where an 8-bit pair is what they are, and deny the 8-bit planes to the
     games that want them.

   **And, staying at 32 bits: how big can a volume be and stay cache
   friendly?** (the user's question, 2026-09-10). Measured sizes on the test
   machine, an i7-11850H: `sizeof(VoxelInstance)` 4, L1d **48 KB a core**,
   L2 **1280 KB a core**, L3 24 MB shared by sixteen threads, 64-byte lines.
   The mesher walks x fastest and reads a 3x3x3 neighbourhood, so what has
   to be resident is three z-slices of the padded volume, not the whole
   thing. For a chunk of edge S the padded edge is S+2:

   | S | padded | volume | 3-slice window | ~output geometry | padding |
   |---|--------|--------|----------------|------------------|---------|
   | 16 | 18^3 | 23 KB | 3.8 KB | ~230 KB | x1.42 |
   | 32 | 34^3 | 154 KB | 13.5 KB | ~940 KB | x1.20 |
   | 48 | 50^3 | 488 KB | 29 KB | ~2.1 MB | x1.13 |
   | 62 | 64^3 | 1024 KB | 48 KB | ~3.5 MB | x1.10 |
   | 90 | 92^3 | 3.0 MB | 99 KB | ~7.4 MB | x1.07 |
   | 128 | 130^3 | 8.6 MB | 198 KB | ~15 MB | x1.05 |

   (Output geometry taken as three quads per S^2 of surface at
   `sizeof(CustomGeometryVertex)` = 52 bytes and six vertices a quad, which
   is the order terrain comes out at.)

   Reading it off:
   - **The neighbour window fits L1d up to S = 62** (48 KB), which is the
     limit that would matter if the volume were the only thing in cache.
   - **The whole padded volume fits one core's L2 up to S = 66.**
   - **But the volume is not what fills the cache.** Two other things do:
     `sizeof(CachedVoxelDefinition)` is **368 bytes** and this game has 2493
     of them -- **918 KB**, hit at random by id, which on its own is three
     quarters of one core's L2. And the *output* grows as S^2 and passes the
     volume at S = 16 already. Beyond S = 32 the definitions plus the output
     no longer sit beside each other in L2 whatever the volume does.
   - **So the cache answer is S = 32, and S = 16 is not leaving much on the
     table.** 62 is the number if the volume were alone; 32 is the number
     once the definition table and the vertex buffers are in the room.
   - **And cache is not the binding constraint anyway.** Work per chunk goes
     as S^3: a 32-chunk is eight times the work of a 16-chunk in one
     indivisible go, which is exactly the stutter the frame-smoothness
     section is about (`MESH_BUDGET_US` is 4 ms and one 16-chunk already
     overruns it). What gets better with a bigger S is the padding waste
     (x1.42 at 16 against x1.20 at 32) and the number of drawables. That is
     the real trade: draw calls against latency, with cache putting a
     ceiling somewhere around 32 to 62 rather than deciding it.

   **Moved out of this plan (2026-09-10).** The user's point: luanti_client
   is one sample point for what buildat has to support, not the thing that
   should decide the shape of it. So the whole of this discussion -- the
   declared layout, the planes, the widths, the roles, the cache numbers --
   is written up at the engine's level in
   `doc/plan/buildat_voxel_data_model.md`, against six other shapes of game
   beside this one. What this plan needs from it stays small and is stated
   there too: a param that reaches meshing, and not to be built in a way
   that fights planes later. Nothing in this section blocks anything else in
   this file.
3. **ITEMDEF, 191 KB, 175 ms**, once at login while the loading panel is up,
   and DETACHED_INVENTORY at 231 KB for 8 ms which is fine. The itemdef parse
   is a one-off behind a panel that says "loading", so it is the least of the
   three; slicing it is the same shape as the registry's own slicing.

   **And it is much worse on a public server** (the user's log,
   /tmp/clientlog6.txt, 2026-09-10): NODEDEF 170 KB took **1486 ms**,
   ANNOUNCE_MEDIA 136 KB **1154 ms** and ITEMDEF 142 KB **734 ms** -- three
   and a half seconds of frames that do not run, at login, behind the loading
   panel. The panel is why this is still third, but a player watching a
   window that does not repaint for a second and a half is being told the
   client has hung. All three are one Lua parse of one big string, and all
   three want the same slicing the registry got: read a slab a frame, keep
   the reader where it was, and let the panel draw in between.

   That log also has the objects item's own before-and-after in it: the same
   chest mesh built again for every chest (20 to 32 ms each) and a skeleton
   built again for every skeleton (437, then 206, then 189 ms). Those are
   what the template copies above remove.

**The decisions waiting, as of 2026-09-10.** Everything else in this file is
either done or one of these; each is marked DISCUSSION NEEDED where it lives,
with what was established and what I would do.

1. **A per-frame world-to-screen path** (section 6, HUDADD), which the HUD
   waypoints, the compass and object nametags all want and none of them can
   have alone.
2. **The PBR mode** (section 7): a day's work for an option, and what the
   shadow items and SET_LIGHTING wait on.
3. **A turned node box's texture coordinates** (section 11): the arithmetic
   is small, but which tile a rotated face wears wants a side-by-side look at
   the official client first.
4. **Older Luanti builds to test against** (section 9): the machine has one.
5. **Nearest filtering for the UI's own images** (section 7b): the world is
   done; the HUD's images and a formspec's item pictures are not, and Luanti
   smooths those at non-integer scales.

Off this list since it was written: the particles, which were drawing all
along -- what was wrong was the velocity mapping, and 0f item 4 has the
testing lesson underneath it; the connected node boxes, built on the 32-family
bitmask (0f item 2); and the clouds, fudged by the user's call, with the exact
Luanti look moved to section 13 as decidedly not implemented.

### 0. The next round (2026-09-10), in the order to do it

These come before the numbered steps below. 0a and 0b are bugs whose cause is
found, 0c and 0d are missing features that games rely on, and 0e is the design
the rest of the world work hangs off.

#### 0a...0e -- DONE

The tRNS decode, the mesher's double free, usable items, pointing at objects
and dropping them, and the whole of water -- the alpha pass, the faces inside
a body of it, and the corner heights -- are in the history file.

What was left of that round -- **a node's own alpha mode** -- is DONE.
`use_texture_alpha` sits past the three node boxes, three sounds, two legacy
flags, the dig prediction and the maximum level, which is further than
nodedef.lua read; the reader goes that far now and a node whose mode is
"blend" is translucent, so its faces go in the pass the water already uses.
Checked against VoxeLibre 5.17.0-dev with red stained glass, which tints
what is behind it instead of being solid.

One thing learned on the way, worth keeping: **a reader cannot skip a node
box whose type it does not know** -- the type is what says how much of it
there is. The nodedef test fixture wrote forty bytes of filler for the three
boxes, which was harmless only while the reader stopped at them; it writes
three real boxes now.
#### 0f. What is left of the round of 2026-09-10

The round itself -- water, connected node boxes and rails, objects that are
not boxes, particles, the pointed-node outline, the node-carried formspec and
PRIVILEGES -- is DONE and in the history file under these same numbers. What
it left behind:

1. **Water**: `post_effect_color_shaded`, which dims the camera's tint by the
   light where the camera is, and which sits past the fields read out of
   ContentFeatures.
2. **Connected node boxes**: the `disconnected_<direction>` boxes, which are
   rarer than the rest and would each be another tag; and the tags are not
   turned with a facedir, so a connected node box that also faces a direction
   has its rails pointing the way they were built. Nothing in the games
   looked at does both.

   **Rails**: the slope only looks at the four horizontal neighbours' own
   level and one step up or down, which is Luanti's rule, but Luanti also
   draws the straight tile on a slope rather than the curve, and nothing here
   checks that against the official client side by side.
3. **Objects**: the animation. BONE, KEYS and ANIM are still not read, so
   every mob stands in its rest pose, and SET_ANIMATION says which frames it
   would be playing. That is the rest of the .b3d format plus skinning in
   Urho3D, and it is the next thing on this item.
4. **Particles**: the per-texture alpha and scale tweens in Luanti's
   ParticleTexture, which are past where this reader stops; the spawner
   tweens (one that grows or shrinks over its life), the collision flags (a
   particle that stops at the ground, which is what keeps Luanti's rain out
   of the ground and would put a third of the drops back in the air), the
   glow, the drag, the jitter, the bounce and the attractors, all of which
   Urho3D has no field for; the `vertical` flag is honoured but has not been
   compared against the official client side by side; and the cap of 128 live
   single particles, which is a guess. Attachment is DONE -- see the weather
   item in section 6.
5. Then the numbered steps that are left: 7 lighting and PBR as an option,
   9 older servers, 11 the rest of param2, 12 render to texture, 14 the
   documentation pass. As of 2026-09-10 each of those is either marked
   DISCUSSION NEEDED where it lives and listed at the top of this section, or
   -- 14 -- kept up as the extension grows rather than saved for the end.

### 1...3 -- DONE

Loading against a game that is not the test one, the sky's two faults, and
the inventory the player actually uses. All three are in the history file.

### 4. Voxel meshes -- DONE for .obj and .b3d

In the history file, with the testing note that cost most of a session. What
is left:

- A node mesh may reach outside its own voxel -- of this game's models the
  flowerpot with a flower reaches 1.49 before its 0.5 scale, the sunflower
  1.43 -- so a chunk's bounding box wants to allow for that or such a voxel
  gets culled early. Not seen going wrong yet.
- The same isometric projection the inventory cube uses would draw a
  **nodebox** item icon as its boxes rather than as a flat tile, which is
  what Luanti does for anvils and stairs. Three parallelograms per box; the
  `shear` operation is already there.

### 5. Liquids -- DONE

In the history file; the slope and the transparency came with the rest of
water. What is left:

- The **special tiles**. Luanti draws a liquid from `special_tiles` -- the
  animated ones -- and its six ordinary tiles are what the item and the
  particles wear. nodedef.lua reads both and the liquid wears the ordinary
  ones, which on this game is the still texture rather than the flowing one.

  **Waiting on the same engine change as the rooted plants** (section 0a):
  a variable-sized list of extra textures on a `VoxelDefinition`, which a
  shape's quads can name. Do the two together; they are one change and two
  users of it.

### 6. The presentation the game asks for -- mostly DONE

The HUD, the sounds, the digging animation, the sky and the clouds, FOV,
`infotext` and the object sprites and static mobs are in the history file.
What is left:

- **The HUD's waypoints, and object nametags.** **DISCUSSION NEEDED
  (2026-09-10)**, and one item rather than four because they share one
  missing piece: the waypoint, the image waypoint, the compass and a
  nametag all need a world position turned into a screen one every frame.
  What that takes: `Camera::WorldToScreenPoint` exposed in
  extensions/urho3d/safe_classes.lua (it is in Urho3D's tolua bindings
  already, returning a Vector2), a behind-the-camera test in Lua, which the
  camera's own forward direction gives, and a per-frame update path for the
  handful of HUD elements that have one -- the HUD is otherwise rebuilt only
  when the server changes it, which is what keeps it cheap. The question is
  whether that per-frame path is worth having for waypoints alone, or
  whether it should be built once for waypoints and nametags together, which
  is what I would do. The minimap and the inventory and hotbar elements are
  separate and lower: the slots this client already draws its own way.
- **A sound's start_time**, because seeking is not in the sandbox's
  SoundSource.
- **The rest of the object visuals**: the animation, which is BONE, KEYS and
  ANIM in the .b3d plus skinning in Urho3D and is 0f item 3's next step; the
  nametags, which want the world-to-screen path above; and attachments,
  which want a scene node parented to another object's.
- **What else a server says.** Still unhandled, in the order the sweep
  counted them across the installed games: UPDATE_PLAYER_LIST and
  CSM_RESTRICTION_FLAGS (all fourteen games; neither changes what is on
  screen), LOCAL_PLAYER_ANIMATIONS and SET_LIGHTING (five and four games),
  EYE_OFFSET, MINIMAP_MODES.

  SET_LIGHTING is **DISCUSSION NEEDED (2026-09-10)** rather than work: it
  carries a shadow intensity, a saturation, an exposure curve, a volumetric
  light strength and a bloom, and this client draws the world unlit with no
  post-processing at all, so there is nothing for any of them to change
  until the PBR mode of section 7 exists. Reading it and dropping it, which
  is what happens now, is the honest state.
- **A sign's `text`.** In VoxeLibre a sign's face is an entity wearing a
  texture the server generates, so what makes signs readable is entity
  textures rather than this field.
- **Rain and thunder** -- DONE (2026-09-10), asked for by the user. Four
  things were in the way, and the fourth was a bug in the sandbox rather than
  in the particles:
  - mcl_weather attaches its rain to the **player's own object**, so a
    spawner's positions are relative to the object it is attached to and the
    spawner has to follow it. It does now, and for the player's own object it
    follows the camera, because the server sends no position for it.
  - **Sizes are in Luanti's scene units**, ten to the node, and Urho3D's
    particle size is half of one side: a drop's size of 4 is four tenths of a
    node, not four.
  - **A spawner's particles have to outlive it.** Luanti's particles are not
    owned by the spawner that made them, and mcl_weather deletes and re-adds
    its rain about twenty times a second: an emitter per add lives in
    fifty-millisecond bursts. Now a deleted spawner stops emitting and its
    node goes when its last particle has expired, and a spawner added again
    with the same description picks its own emitter back up.
  - **tolua++ generates no setter for a property whose type is a const
    reference**, and Urho3D's ParticleEffect declares its vectors that way:
    the generated binding is `tolua_variable("minDirection", getter, NULL)`.
    So `effect.minDirection = ...` wrote nowhere *and read back what was
    assigned*, which is why it looked right. The effect kept Urho3D's
    defaults, so every particle in this client had been flying off in a
    random direction at the default size. The sandbox now exposes
    SetMinDirection, SetMaxDirection, SetMinParticleSize,
    SetMaxParticleSize, SetConstantForce and SetEmitterSize and marks the
    matching properties read-only. A sweep of the generated bindings says the
    other const-reference properties are ones nobody assigns -- bounding
    boxes, frustums, world transforms -- and that Zone's ambientColor does
    have a setter.

  Two smaller ones came with it: the effect and its material are kept alive
  for as long as the emitter, because an Urho3D object made in Lua belongs to
  Lua and is destroyed when Lua drops it; and a particle's texture is
  filtered with nearest magnification and mipmapped minification, which is
  what Luanti's own particle material asks for -- a rain drop is one pixel
  wide in its image and point sampling loses it at a distance.

  Verified on VoxeLibre: drops fall inside the 30x30 box around the player
  (measured x -14..16, z -161..-131 with the player at 1,-146) and read as
  streaks against the sky, 1606 drop-coloured pixels in a frame against 8
  before, and `/weather thunder` is denser than `/weather rain` the way its
  900 particles against 500 says it should be. `/weather snow` draws nothing
  in the official client either, so it was not chased.

### 7. Lighting: the game's look, and PBR as an option

The Luanti-native look is what the client draws now and what it keeps by
default. What to add:

**BUILT (2026-09-12).** All four decisions below, as decided, on the
`luanti-pbr` branch: `res/PBRVoxel.glsl` and its two techniques (cut out for
the world, blended for the water the mesher puts on the chunk's alpha child),
`skyvis.lua` with the marching, `zone.zoneTexture` on the copied cube map,
and the checkbox. What the forked shader changed from the original is one
uniform, `cSkyColor`, which the sky multiplies the reflections by.

Three things worth keeping from doing it:

- **The volumes had to be built lazily.** 64 voxels of reach around the
  camera is 729 mapblocks, and packing them at once every time the player
  crosses a block boundary is a hitch. What it does instead is build eight a
  sweep, within 32 voxels, and lean on what the engine already does with a
  ray that runs out of data: it keeps the skylight of the last air it was in,
  so a block that is not built yet reads as whatever is around it rather than
  as a wall.
- **The sandbox's globals are not the module's.** `skyvis.lua` is a dofile of
  an extension, and neither `buildat` nor `require("buildat/extension/urho3d")`
  there is what `builtin/voxel_shading`'s module.lua gets: both had to be
  handed in by world.lua. Two crashes, both of the "attempt to call a nil
  value" kind, both fixed by a parameter.
- **The counter is what proves it.** `sky 1.00 up over 90 blocks` in the air
  and `sky 0.00 up over 88 blocks` at y = -30 is the whole chain -- packing,
  deserializing, marching, the buffer, the render path -- said in one line.

The decisions, as they stood:

The shader's contract is already the one this client meets: the same mesher
writes both worlds' vertex data, `rgb` is bounced light and `a` is how much
sky the surface sees, and `vSkyVisibility = iColor.a` already scales the
reflections -- so a cave reflects nothing before anything is marched. What
was decided:

- **Fork the shader into `luanti_client/res/`.** `builtin/` is not on a
  client's resource path (only `share/client/data`, `cache/tmp`,
  `share/extensions` and the Urho3D dirs), and a Luanti client has no buildat
  server to deliver it. A copy of our own is also a copy we may edit.
- **Port the marched `cSkyVis[54]`.** The vertex skylight covers the cave;
  the marching is what lets a tunnel's mouth reflect sky while its walls do
  not. Needs a Volume per block near the camera, which this client does not
  keep today -- `buildat.deserialize_volume()` on the packed data it already
  builds is the way in.
- **The reflections are the static cube map times a colour uniform**, fed
  the sky colours the server sends, so sunset and biome and being underwater
  follow. Three lines in the forked shader; no baking.
- **A checkbox in the connect dialog**, chosen before anything loads and
  fixed for the session: the atlas's surface maps have to be on from the
  first texture.
- **Not in this: sun shadows.** The technique carries the passes; turning
  them on is its own step, after this looks right.

- **An "Enable PBR" checkbox in the connect dialog.** DONE. Was **DISCUSSION
  NEEDED (2026-09-10)**: this is the largest single item left in the plan and it is
  a look, not a fix -- the client draws the Luanti-native look correctly
  today. It also spends the loading time the atlas work deliberately took
  back (the surface maps), needs a sky cube map baked and rebaked from the
  sky colours, and needs `builtin/voxel_shading`'s SkyVis marching rewritten
  against this client rather than against `buildat/module/voxelworld`. Worth
  saying out loud before starting: it is a day's work for an option, and it
  is the thing SET_LIGHTING and the shadow items below wait on. When it is on, the
  world is drawn with `builtin/voxel_shading`'s PBRVoxel technique instead of
  VoxelUnlit: normal maps, roughness, reflections of the sky, and the sun as
  a real directional light. What that needs, in the order it bites:
  - the atlas's normal and surface maps, which are exactly what the loading
    work turned off (`atlas_reg:set_surface_maps(false)`): the checkbox has
    to turn them back on, and the load cost comes back with them. That is
    the honest trade and it is the player's choice.
  - a sky cube map as the zone's `zoneTexture`, baked from the same colours
    the skybox shader uses, rebaked when they change.
  - the SkyVis marching that module does, which is what keeps a cave from
    reflecting a sky it cannot see. The module is written against
    `buildat/module/voxelworld`, which this client does not use, so the
    parts worth having have to work without it.
- **The sun, the moon and the skybox as the textures the game asks for**, in
  both modes: `SET_SUN` and `SET_MOON` carry texture names, tonemaps and
  scales, `SET_STARS` the star count and colour, and a `type = "skybox"`
  sky carries six textures.

  The sun's and the moon's own textures are DONE (2026-09-10); how, and what
  it verified against, is in the history file.

  What is left of this bullet: the tonemaps (a colour grade of the body by
  the time of day), the sunrise texture (a band of its own along the horizon,
  where the shader paints the sky colours instead), and the `skybox` sky type
  with its six textures -- which wants either a TextureCube built at runtime
  or six quads, and is the reason it is not done here.

### 7c. What PBR is still missing -- BUILT (2026-09-12)

In the history file, with what it turned out to be: the plan did not foresee
that a drawable casts no shadow unless told one by one, that a sun brightness
of 2 is nowhere near enough, or that the whole thing wants HDR and a tone
curve to work at all. Nothing is left of it.

### 7b. Nearest-pixel rendering -- DONE

In the history file. The UI's own images were the open half of it and the
user's answer (2026-09-10) was nearest for those too: a form's image[], the
item picture in a slot, the stack under the cursor and the HUD's images all
go through one `game_texture()` in formspec_ui.lua now. Luanti's own client
smooths GUI images at non-integer scales; this one does not, by choice --
what it draws is pixel art and it reads as pixel art.

### 8. What the world is still missing

- Waving leaves and plants, which the definitions already carry a flag for.
  **DISCUSSION NEEDED (2026-09-10)**: the mesher bakes a chunk's voxels into
  one geometry per atlas and there is no per-vertex room left to say "this
  one waves" -- the vertex colour is the baked light. The way that fits what
  is now there is a third geometry on a child node of the chunk, exactly as
  the translucent pass got one, with a waving technique on it; that is
  cheap to build but it splits every chunk with leaves in it into another
  drawable, and a waving liquid would want to be in two passes at once.
- A torch on a wall stands straight rather than leaning out of it, because
  its selection box does. **DISCUSSION NEEDED (2026-09-10)**: Luanti leans a
  torchlike node by drawing it as its own mesh rather than from the box, so
  this is not a rotation of what is there -- it wants the torchlike quads
  built the way Luanti builds them, which is a shape of its own in
  shapes.lua and a comparison against the official client to get the angle
  and the offset right.
- Nothing casts a shadow from the scene lights a light-giving voxel gets.
  Point-light shadows are six shadow maps each; it wants a much lower cap.
  Not worth doing before the PBR mode exists, which is where a real light
  budget belongs.

The connected node boxes and the pointed voxel's outline, which this section
used to argue about, are DONE; see 0f items 2 and 5. Neither of the two
routes argued out here is what happened: the mesher does look at the volume
itself, but what "connects" means stays Luanti's business, because the game
hands over families and a bitmask and the mesher only tests a bit. No
neighbour mask in `pack_voxel_volume()` and no voxel id per mask.

### 9. Older servers: 5.11.0 to 5.17.0 -- mostly DONE

In the history file: 5.11.0 (protocol 47) and 5.17.0-dev (52) both work.
What is left:

- The commands not handled yet whose payload depends on the version: the
  particle commands (42 and 52), SET_LIGHTING (54 bytes on 5.11, 66 on 5.17)
  and SPAWN_PARTICLE_BATCH (5.17 only). Section 6 says why SET_LIGHTING is
  not work, and the particle commands are read from protocol 42 up.
- Only 5.11.0 and 5.17.0-dev have been run against. The interesting ones in
  between are 5.12 (protocol 48, where the compression changes) and 5.15
  (51, where the item animation appears). **Blocked (2026-09-10)**: the test
  machine has one Luanti build, 5.17.0-dev; running against 5.12 and 5.15
  means building or fetching them first, which is the thing to decide rather
  than a thing to write.

### 10. What the client tells the server about itself -- DONE

In the history file. Nothing here needs doing until a game is found that
branches on the version in a way this gets wrong.

### 11. param2, the rest of it  (lower priority now)

Done: a voxel id per (definition, param2) pair, the palette colour param2
picks, the tile a facedir moves to each face of a cube, the texture turned
inside that face, a shape turned by a facedir, and the wallmounted boxes and
quads. That is good enough for now. What is left:

- A turned node box's texture coordinates. `box_quads()` does take each
  face's uv from the part of the tile the box covers, so an unturned box is
  right; what is wrong is that `turn_quads()` rotates the corners and keeps
  the uv, so a turned stair's texture is not what Luanti draws.
  **DISCUSSION NEEDED (2026-09-10)**: recomputing the uv from the rotated
  corners is arithmetic and small -- the rule is the one `box_quads()`
  already encodes per face -- but which tile a rotated box face wears is
  Luanti's own convention and I could not settle it from the source without
  a side-by-side comparison, which is the next item here. Getting the uv
  right and the tile wrong would look worse than what is there now, so this
  wants the comparison first.
- A look next to the official client. The turn direction is Luanti's own
  arithmetic and the tables regenerate to what is already there, but nothing
  has been compared side by side. An observer is the node for it: its top
  texture carries an arrow.

### 12. Render to texture  -- **DISCUSSION NEEDED**: deliberately deferred

The general primitive the inventory cube did not need: a `Texture2D` with a
render surface, a scene and a camera, rendered on demand. What would want it
is a picture a shear cannot draw -- an object preview, a minimap, a mirror, an
item whose voxel is a `.b3d` mesh.

Why it is here rather than earlier: the pixel cost is nothing but the shape is
wrong for bulk. Anything that has to reach the atlas needs a GPU-to-CPU
readback per item, which is a stall of the same order as composing the whole
image (measured: 0.37 ms per composed PNG, from 577 compositions inside a
1082 ms registry build against 870 ms warm) and with no disk cache to make the
second run free. Urho3D renders viewports once per frame inside its render
pass, so doing many in one frame wants engine code driving render targets out
of band. And a render target dies on a screen mode change exactly as the atlas
textures do today. Size it for tens of previews, not thousands.

### 13. Kept low, and decidedly not implemented

**Decidedly not implemented**, which is different from not yet done:

- **Luanti's own cloud look** (2026-09-10, the user's call): a slab of cloud
  at a height with a thickness, seen from above and from inside. The sky
  shader fakes a flat layer instead and the game's density and speed are
  fudged onto it, which shows the amount and the speed of the clouds without
  any of the arithmetic. See section 6.

Kept low: damage effects; privileges; the player list; the minimap modes; mod
channels. Also: `dropdown`, `scrollbar`, `scroll_container` and `hypertext`
in a formspec -- this game uses no dropdown and no hypertext at all, five
scrollbars and two scroll containers -- and the pressed and hovered states of
a style.

### 14. Documentation and terminology

- `doc/client_api.txt` says what a voxel is and what a node is up front, and
  its own text was already using "voxel"; keep it that way.
- `doc/luanti_client.txt` follows the extension as it grows.

### 15. A pause menu, and the key bindings in one place -- DONE

In the history file. Escape opens a menu with Continue playing, mute, the key
bindings and Exit, drawn by this client's own formspec code rather than by
hand.

## Risks

- **Building the voxel registry.** 2492 voxel types take about a second of
  work, and it is a slice a frame now rather than one long frame. On a game
  with more definitions than this one it is still the biggest single cost of
  connecting, and the loading dialog is what makes that honest rather than
  fast.
- **Media volume.** Asking for everything announced means a modded game's
  whole media set over our own reliable UDP -- tens of megabytes, thousands
  of files -- on the first connection. The on-disk cache keyed by the
  announced sha1 is what keeps the second one quick. If that turns out too
  slow, the next thing Luanti has and this does not is the remote media
  server over HTTP.
- **Mesh cost per block.** 16³ blocks are small and a view distance is
  hundreds of them. Handing one over costs the frame about 500 us with the
  map caching in place; if that stops holding, group 2×2×2 blocks into one
  volume.
- **Atlas size.** One atlas per texture size, 2048 px, so 16×16 tiles give
  4096 slots and this game needs about 1500. Mixed sizes make several
  atlases and therefore several materials per block, and creating one costs
  22 ms.
- **The engine additions are the long poles.** They have to come out generic
  or they do not belong in buildat; a Luanti-shaped interface is the signal to
  think again about where the boundary is. The two that step 1, 5 and 8 want
  are a neighbour mask in `pack_voxel_volume()` and rendering to a texture.
- **PBR doubles the atlas work.** The normal and surface maps are two thirds
  of what adding a texture to an atlas costs; the option has to be a choice
  made before the media arrives, not a toggle mid-session.
