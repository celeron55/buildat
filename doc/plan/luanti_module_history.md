# builtin/luanti: what is finished

Moved out of `doc/plan/luanti_module_plan.md` so that it holds only what is
open and the rules that still govern it. Nothing here is a to-do; it is kept
for the reasoning behind what was built.

## M2 in detail: a world exists (2026-09-12)

M1 left a Lua environment that loads devtest and records every registration,
with the environment half of the API as stubs that log once
(`builtin/luanti/lua/bootstrap.lua`, `STUBS_NIL`). M2 is where the stubs
start being answers, and it is the milestone that decides the module's
shape, so it was worked out in full before any of it became code.

What follows is that work: what M2 is, the twelve things that are settled
and should not be re-argued, and the six steps that are left. Each settled
item says what was decided and why, because the why is the part that stops
it being reopened by whoever reads the code in six months.

### What M2 is

`core.set_node` and `core.get_node` against `voxelworld`, a singlenode
world, skylight running, and a buildat_client seeing a floor a mod placed.
Everything else in `STUBS_NIL`'s "environment" group follows from the same
two, and the ones that do not (`find_nodes_in_area`, VoxelManip) are the
same seam applied to a region instead of a voxel.

### Settled at M2 and closed with it

- **No fork at M2; the stock voxelworld client draws it (answered
  2026-09-12).** The client half is already written and it is not the Luanti
  client: `builtin/voxelworld/client_lua/module.lua` takes the registry and
  the chunk volumes, builds geometry with `set_voxel_geometry` and handles
  LOD and physics distance. Every voxel game in the tree drives it and none
  has a mesher of its own; the smallest driver is
  `games/voxel_physics/main/client_lua/init.lua` at 219 lines. That, minus
  the physics, is M2's client.

  So the question is what the nodes look like, and at M2 that is one solid
  colour per node, hashed from its name -- deterministic, distinct per type,
  and enough to see that `default:stone` and `default:dirt` landed where the
  mod asked.

  **Not via `VoxelVariant::color`.** That tints light and not albedo
  (`src/interface/voxel.h:89`), so a colour applied there shows in shade and
  washes out in sunlight, which is backwards for telling node types apart
  under skylight. M2 generates one small solid PNG per node through the
  stb_image_write encoder M1 already put in `luanti.cpp`, and serves them
  over `client_file`. 390 devtest nodes at 16x16 is nothing for the atlas.

  **The fork waits for M3** because M2's point is the server seam -- ids,
  the write-behind buffer, skylight, singlenode generation -- and a forked
  4500-line `world.lua` in the middle makes every failure ambiguous: the
  floor is missing because `set_node` did not write it, because the chunk
  did not replicate, or because the fork's mesher did not draw it. Against
  the stock client two of those three are code a dozen games exercise.
  Nothing is thrown away by waiting: M2's client work is camera and scene
  setup, which the fork keeps, and what the fork brings is exactly M3's
  list.

  When it comes, it lands in `builtin/luanti/client_lua/` -- a module can
  ship client Lua, as voxelworld does -- with
  `games/luanti_launcher/main/client_lua/init.lua` staying the thin
  game-side part. The module draws Luanti nodes; the game picks a save.

  M2's success criterion restated: **a screenshot of a coloured floor a mod
  placed, with skylight on it**, drawn by a client containing no
  Luanti-specific code at all.

- **The fixture: a minimal game first, then devtest (answered 2026-09-12).**
  Two files -- a `game.conf` and one mod that places a floor -- committed
  under `builtin/luanti/test/games/<name>/` and pointed at by path. One node
  type, one mod, no dependencies, so when the floor does not appear there is
  one place it can have gone wrong. This is **M2's runnable check**, and it
  stays useful for the rest of the project.

  Then devtest, which is the realistic scale: 390 nodedefs through the id
  allocation, 390 generated PNGs through the atlas, 35 mods of load-time
  surface, and it already passes its own `unittests` mod. devtest tells you
  *whether* something broke; the minimal game tells you *what*.

  **devtest on singlenode generates nothing** -- an empty world and an
  endless fall through air -- so our copy gets a mod that places something
  to stand on. That is allowed and expected: `cache/luanti/games/devtest`
  (later `user/luanti/games/devtest`) is our copy to modify, and the changes
  are ours to keep. Test saves take the `buildat_test_` prefix, the same
  convention as the client's test worlds.

### How M2 is built

Everything above is settled, so this is an order of work rather than a set
of choices.

**Built 2026-09-12: all six steps.** What M2 said it would end with -- a
buildat_client seeing a floor a mod placed -- is on the screen. What is left
over from it: the clock is not persisted, because that waits on the launcher
opening a save, and the fixture is buildat's own minimal game rather than
devtest with a mod, because a fixture somebody has to install is a fixture
that is different on every machine. devtest itself loads and registers its
390 node types; it places nothing, having no mapgen to place it from.

What the build settled beyond the list:

- **The module owns the scene and the voxelworld instance.** It is what
  knows the world's node ids and its light, so it is what owns them, and it
  announces the scene with `luanti:game_loaded` -- which is how whoever
  started the game finds out where to put its peers. The alternative, the
  launcher creating the scene and handing it in, puts the registry's
  ordering rule in the wrong place: the ids are allocated while the mods
  load and the definitions are built straight after, both inside the module.
- **A write emerges the section it lands in**, the way Luanti's `set_node`
  emerges the block it writes into. Without it the first flush raced
  `voxelworld`'s own first tick and silently wrote nothing -- the check
  caught it, twice, before this was understood.
- **The vendored `constants.lua` is modified**, not wrapped: it hardcodes
  125/126/127 and would overwrite the ids the module allocates. First use of
  the fork rule, and the file says so where the numbers were.
- *simplified, and the diagnosis was wrong:* the region reads are written in
  Lua over the two C functions, so a 5x5x5 box is **125 separate
  `access_module()` calls** -- 125 module-lock acquisitions and 125
  lock-hierarchy validations. The commit each one pays on the way out is
  nearly free, because `commit_chunk_buffer` early-outs on `!dirty`
  (`voxelworld.cpp:1877`) and `update_skylight()` returns at once with an
  empty seed list. **So the cost is the Lua boundary, not voxelworld**, and
  the fix is to move the loop to the C side inside one `access()`: a change
  in this module, no engine change, 125 lock acquisitions down to one. That
  is the next thing to do to these three functions.
- **The fixture is bundled.** `builtin/luanti/minimal_game` is a Luanti game
  of buildat's own -- one mod, two node types, a floor and a marker -- so the
  module can be run and looked at with nothing installed, and so the visual
  check is the same on every machine. `BUILDAT_LUANTI_GAME=minimal`.
- **The launcher takes the scene from `luanti:game_loaded`** and assigns it
  to each peer as its files arrive, with a `client_lua` that looks at the
  world from outside it. No player and no digging; that look is M3's.
- *simplified:* `EDGEMATERIALID_EMPTY` is one test doing two jobs in buildat
  -- a face is drawn against it and light passes through it -- and Luanti
  splits them. Until the drawtypes arrive with M3, a node is transparent if
  it is airlike or `sunlight_propagates`.

1. **The node registry seam.** Nodedefs to `VoxelRegistry` in one pass after
   mod loading, ids allocated on first sight of a name, `CONTENT_IGNORE`,
   `CONTENT_UNKNOWN` and `CONTENT_AIR` as 0, 1 and 2. One generated
   solid-colour PNG per node, hashed from its name, served over
   `client_file`.
2. **The clock.** `time_of_day`, `game_time`, `day_count`, `time_speed`,
   stepped with the environment, persisted in the save. Nothing on the wire
   yet.
3. **The write path.** The write-behind buffer, flushed once per step inside
   one `voxelworld::access()`, with `core.get_node` reading through it.
   `set_node`, `add_node`, `swap_node`, `remove_node`, `bulk_set_node`
   on top of it, against `VoxelFormat::luanti()`.
4. **Singlenode and skylight.** The world is void, the only nodes are the
   ones a mod places, `set_skylight_enabled(true)`.
5. **The region reads.** `find_node_near`, `find_nodes_in_area`,
   `find_nodes_in_area_under_air` -- the same seam over a region.
6. **The fixture.** The minimal game places a floor; screenshot it. Then
   devtest with a mod that gives it something to stand on.

`run_game()` and `load_lua()` queue rather than execute throughout, and
every `voxelworld` call goes out from this module's own thread, never back
into it.

M3 then replaces the solid colours with the real atlas, drawtypes and
media, which is where the client fork lands.

## The milestones as they were finished

- **M0 -- the testbed. DONE (2026-09-12).** `cp -r ~/projects/luanti/games/devtest
  cache/luanti/games/devtest`, and a world directory beside it. Nothing runs
  yet; this is the fixture every milestone after is tested against.

  Built before the paths were settled, so it sits in the cache. It moves to
  `user_path/luanti/games/devtest` with step 1 of
  `doc/plan/world_persistence_plan.md`; installed content is not cache.
- **M1 -- the environment boots. DONE (2026-09-12).** devtest loads: 35 mods,
  390 nodes, 26 craftitems, 81 tools, 499 items, 26 aliases, and its
  unittests mod -- which asserts while it loads -- is satisfied. See
  doc/luanti_module.txt.

  Against the plan: **nothing had to be built at build time.** The vendor tree
  so far is Luanti's builtin/*.lua and nothing else, and the Lua state is
  Urho3D's Lua 5.1, which buildat_server already links and whose C API
  libUrho3D exports, so the module is still one runtime-compiled .cpp with no
  CMake step and no static library. The "first builtin that does not build
  from a clean checkout" is still ahead, at the milestone that vendors C++.

  Also not as planned: Lua 5.1 has io and os, so the C side is four functions
  -- a directory listing, the log, the clock and a PNG encoder -- and the rest
  of the C API is Lua beside the module. ItemStack, the inventory and the
  noise generators are written in Lua rather than vendored, marked where they
  are written, with the vendoring as their upgrade path.

  What it was, as planned: a Lua state, the vendored `builtin/` loaded,
  devtest's mods loaded in dependency order, every `core.register_*`
  accepted and recorded. Success is the server logging the node and item
  counts devtest registers and not dying. No client involved.
- **M2 -- a world exists. PLANNED to an order of work (2026-09-12).**
  singlenode mapgen, `core.set_node` working against voxelworld, skylight
  running, the clock, and one solid colour per node. Success is a
  buildat_client connecting and seeing a coloured floor that a mod placed --
  drawn by a client containing no Luanti-specific code at all. See "M2 in
  detail" below: every question it opened is answered and what is left is
  six steps.

## M4 and M5 in detail (2026-09-13)

Moved out of the plan when they were built. What follows is what each piece
turned out to be.

- **M4 -- it plays. The node half is built (2026-09-13).** Digging and
  placing, inventory, item definitions, craft, formspecs. Success is digging
  a node in devtest and getting it.

  **Built:** `add_node`, `remove_node`, `swap_node`, `bulk_set_node`,
  `bulk_swap_node`, and the three a player's actions come to --
  `place_node`, `dig_node`, `punch_node`. Each makes the pointed thing a
  player's action would have made, hands it to the vendored builtin with a
  nil actor, and lets that run the callbacks: `can_dig`, `after_dig_node`,
  `on_construct`, `on_destruct`, `after_place_node`, the drop list and the
  registered `on_dignodes` and `on_placenodes` are the builtin's own and
  behave as they do in Luanti rather than being written again. That is
  Luanti's own `l_dig_node`, `l_place_node` and `l_punch_node`.

  Node metadata came with them, because the builtin reaches for
  `core.get_meta()` on every dig of a node whose definition has an
  `after_dig_node`. In memory for now; the save is step 5c of
  `doc/plan/world_persistence_plan.md`.

  **Built: node inventories (2026-09-13).** The inventory class and the
  detached ones were already there; what was missing is the one a position
  has. `core.get_meta(pos):get_inventory()` and
  `core.get_inventory({type = "node", pos = ...})` are the same inventory,
  which is what a chest is, and `set_node` takes it with the rest of the
  metadata because it was the old node's. An item stack's metadata has none,
  which is the difference between the two in Luanti as well.

  **Built: the recipes (2026-09-13).** `core.register_craft` recorded what a
  mod wrote and nothing read it; `lua/craft.lua` is the half that is C++ in
  Luanti. All five kinds: shaped, whose pattern is trimmed of its empty
  border so that it matches wherever in the grid it sits; shapeless, which
  is a multiset and tries the plain names before the groups so that a group
  does not eat the item a name was going to match; cooking and fuel, which
  are one item each; and toolrepair, whose two worn tools make one with
  their uses added. `get_craft_result` answers with the output and the
  decremented input, and `get_craft_recipe`, `get_all_craft_recipes` and
  `clear_craft` stop being stubs.

  simplified: no crafting hash, so a craft walks every recipe. devtest has
  around 200 and nothing crafts in a loop; the upgrade path is the table
  Luanti keys by the first item.


  Two things the check found, both Luanti's own behaviour rather than bugs
  here: a registered definition refuses new keys -- `register.lua` sets
  `__newindex` to ignore them, so a callback cannot be bolted onto a def
  afterwards and a check for one has to be where the node is registered --
  and `node_dig` reads a node's metadata whenever the def has an
  `after_dig_node`, whether or not anything ever wrote any.
- **M5 -- it lives. The globalsteps and `core.after` run (2026-09-13).**
  ABMs, LBMs, entities, `core.after`. Success is `testabms` and
  `testentities` behaving.

  **Built:** a Luanti step runs the registered globalsteps. `core.after` is
  one of them -- the vendored `builtin/common/after.lua` keeps its queue in a
  globalstep of its own -- so that is what makes it fire at all, and it is
  what every mod that does anything on a timer is written around. A callback
  that errors is logged and the rest still run, where Luanti stops the
  server: one mod's bad frame should not stop the clock, which is the posture
  the module already takes one level up.

  Turning them on made devtest's `testhud` throw twelve times a second,
  which was the honest thing to find: `core.get_connected_players()` was a
  stub answering nil where Luanti always answers a list, so the `ipairs()`
  every caller writes blew up, and the error named the mod rather than what
  was really missing. The stubs that Luanti documents as always returning a
  list return an empty one now, and `object_refs` and `luaentities` are
  tables rather than functions, because indexing a function is an error and
  a mod that only looks should not be broken by a stub.

  **Built: ABMs (2026-09-13).** A rule that runs on every node of a kind,
  forever, which is what a game's growing and burning and decaying are made
  of. Per-rule interval accumulators in the step; the sweep is over the
  sections that are loaded, which is Luanti's active block list under another
  name since there are no players yet. `nodenames` (groups included),
  `neighbors`, `chance`, `min_y` and `max_y` all decide, and the action is
  called with the two object counts at zero.

  The match is on content ids and happens in the module --
  `__luanti_find_ids()` reads a box and returns the positions in it that are
  of a kind, for up to 32 sets of ids at once -- so what crosses into Lua is
  the handful of voxels a rule is about rather than the section. The first
  cut read each section into a Lua table of names and matched there: a sweep
  of a 3x3x3-section world took 3.8 seconds and devtest, where nine rules
  each read every section, saturated a core. It is 0.35 seconds and a third
  of a core through the module, and the rules no longer pay per rule.

  A mutex around every entry into the module's Lua came out of this. Two of
  the module's handlers can be inside Lua at once -- a queued `core:tick` on
  the module thread while `core:shutdown` is emitted synchronously from
  another, which `ModuleThread::handle_event` does not serialise against
  `emit_event_sync` -- and one `lua_State` under two threads is a crash. It
  was always there; a step that does real work is what made it happen every
  time. The engine is where it should be fixed, and then the mutex can go.

  What the fixture checks: `minimal_game` registers a rule that turns a seed
  into a sprout, and three seeds -- one on the floor, one off the edge of it
  and one above the rule's `max_y` -- of which exactly the first grows.
  Registered in the game and not in `lua/check_map.lua` because the
  registries freeze once the mods have loaded, which is what `core.__game_check`
  is for: check_map calls the game's own check with the map flushed.

  **simplified:** no time budget, no catch-up, and every loaded section is
  read for every step that has a rule due. Luanti spends at most a share of a
  step on ABMs, skips ahead when a block comes back after a long time away,
  and keeps a per-block list of which node kinds are in it so that most
  blocks are never read. All three are about a map bigger than the sections a
  mod can reach here; they belong with M6's map.

  **Built: LBMs (2026-09-13).** The same idea on a section rather than on a
  timer, over the same sweep: a rule that runs over the nodes of a kind when
  the part of the map they are in is loaded, which is how a game fixes up
  what it saved before it changed its mind about it. `action` and
  `bulk_action` both. devtest has none, so what checks it is `minimal_game`,
  where an LBM counts the six torches the fixture places and the check asks
  for all six.

  **simplified:** the whole world is loaded before anything steps and nothing
  unloads it, so "on load" is once, at the first step that has a section to
  look at -- and `run_at_every_load` and Luanti's record of which blocks are
  older than which rule have nothing to be different about yet. Both belong
  with M6's map, where a section stops being loaded for the whole run.

  **Built: the objects (2026-09-13).** Everything in a Luanti world that is
  not a node. `core.register_entity` was already the vendored builtin's;
  `lua/entity.lua` is the other half, which in Luanti is C++: `add_entity`,
  the luaentity as a per-object copy of the prototype, ObjectRef, the step
  that moves an object and tells it what it ran into, and
  `get_objects_inside_radius` / `get_objects_in_area`, which stop being
  stubs. An object is a position, a velocity, an acceleration and a box.

  The collision is axis by axis against the voxels the box overlaps, with no
  stepping up and no sliding along a corner, and it answers with the
  `moveresult` the builtin's own entities assert on -- `collides`,
  `touching_ground` and the collisions with the node each was against. That
  is what makes `__builtin:item` work, and with it `core.add_item`, and with
  that M4's loose end: what a dig drops is now an item lying on the floor
  rather than a list nothing is done with.

  **simplified:** nothing draws them, nothing saves them, and there are no
  players and no attachments. The client half of the module is what would
  show an object; `static_save`, `get_staticdata` and the `dtime_s` an
  `on_activate` is given have nothing to be different about while the world
  is loaded whole for the run, which is M6's map again.

  What the fixture checks: an entity that falls from six voxels up comes to
  rest exactly on the floor -- box bottom against the top of the node -- and
  its `on_step` saw `touching_ground`; `remove()` makes the handle invalid
  and empties `core.luaentities`; and digging a stone leaves one
  `__builtin:item` holding `floor:stone` within two voxels of where it was.

  **Built: node timers (2026-09-13).** A timer per position, which is what a
  furnace burning down and a plant growing on its own are written on.
  `core.get_node_timer(pos)` with `start`, `set`, `stop`, `is_started`,
  `get_timeout` and `get_elapsed`; a timer that runs out is stopped before
  its `on_timer` is called, so the callback is free to start it again, and
  the same timeout comes back when it returns true. `set_node` drops the
  timer with the metadata, because both were the old node's. In memory, with
  the same ceiling and upgrade path as the metadata beside it.

  That and the objects together are what `core.check_for_falling` needed:
  `falling.lua` is the vendored builtin's own and has worked since the
  objects did, so the fixture digs what holds a `falling_node` up and checks
  that it comes down and is a node again where it lands.


## M7 in detail: the importer (2026-09-13)

- **M7 -- an existing Luanti world opens. The map is read (2026-09-13).**
  The importer: read a Luanti world directory -- `map.sqlite`,
  `map_meta.txt`, `env_meta.txt`, the player and mod storage databases -- and
  write a buildat save. One direction.

  **Built: the map.** `builtin/luanti/mapblock.h` is the MapBlock reader,
  serialization versions 25 to 29, which is every world written since 2013.
  The two shapes are the whole of the version difference: at 25 to 28 a
  block is two zlib streams with the name-id mapping at the back, behind the
  static objects, and at 29 it is one zstd frame with the mapping in front.
  Both schemas a `map.sqlite` has are read -- the older one keys a block by
  one integer, the newer by three columns. `luanti::import_world()` reads the
  blocks into the running game's world, clipped to what that world has room
  for, and `games/luanti_launcher` calls it for `BUILDAT_LUANTI_IMPORT`.

  Every block carries the name-id mapping it was written with, which is what
  makes a world readable by a game that registers its nodes in another
  order: the ids are translated through the names, through whatever alias
  the game registers, and a name the game does not register becomes
  "unknown" and is counted in a warning rather than making a hole.

  **How it was checked.** `check_mapblock()` builds a block in each of the
  two shapes and reads it back, which proves the reader against the spec it
  was written from. That it agrees with Luanti was checked by importing real
  worlds at versions 25, 28 and 29 and comparing the node histogram with an
  independent decode of the same database: a fresh devtest world (343
  blocks, 524800 nodes) matched name for name and count for count, as did a
  2011 world at version 25 (266 blocks, 1089536 nodes).

  **Built: the clock.** `env_meta.txt` is lines of "key = value", and three
  of them are the clock: `time_of_day` out of Luanti's 24000-unit day,
  `game_time` and `day_count`. A world opens at the hour it was left at.




## M3 to M7 as they stood when the client half was finished (2026-09-13)

Moved out of the plan's Milestones section, which now says only the status
of each and what is left of it. This is the fuller account and the later
one: the drawtypes and the engine machinery they gave a first user to, the
client half piece by piece, the launcher's menu, and the importer. The two
sections above it are earlier snapshots of M4 and M5 and of the importer,
kept because each says what was known at the time.


**M0 the testbed, M1 the environment boots, M2 a world exists -- all built
2026-09-12.** devtest loads its 35 mods and registers 390 node types, and a
buildat_client sees a floor a mod placed. What each turned out to be, and the
two things M1 disproved about the build, are in
`doc/plan/luanti_module_history.md`.

- **M3 -- it looks like the game. The fork's shape is settled (2026-09-12);
  the media and the plain tiles are built (2026-09-13).**
  Nodedefs to `VoxelRegistry` with texmod strings for texture names, media
  over client_file, drawtypes through **buildat's own mesher** (settled
  2026-09-12, see below), and the client resolving textures into its own
  atlas. Success is devtest's `testnodes` mod looking like it does in Luanti.

  **Built so far:** every mod's `textures/` goes to `client_file` under the
  basename, which is how Luanti names media and what a tile string says; and
  a node whose tile is a plain shipped file name gets it on that face, in
  Luanti's own tile order, which is buildat's own tile order -- so they map
  one to one, and the shorthand of fewer than six copies the last over the
  rest as Luanti does. devtest: 417 files from 20 directories, and 279 of its
  390 node types wear their real tiles. The other 111 keep the generated flat
  colour, and which 111 is the measurement that sizes what is left:

  **Four drawtypes are built as shapes:** `nodebox` of type `fixed`,
  `plantlike`, `plantlike_rooted` and the liquids -- `VoxelQuad`s the
  server puts in the
  definition, the first thing in this tree to build one. A box's faces show
  the part of the node's texture they cover, the way Luanti's `makeCuboid`
  does, so a slab is not a whole texture squeezed into half a voxel.

  A liquid is a full box with a `shape_group` of its own, so the mesher drops
  the faces inside a body of it; a source and its flowing form share the
  group because they both name the source. A flowing liquid's eight param2
  levels are eight `VoxelVariant`s, each a box with its own `liquid_top`, and
  the engine's `liquid_corner_top` averages the four columns around each
  corner -- Luanti's `getCornerLevel` -- so a slope is a slope and not a
  flight of steps. It wears its `special_tiles` rather than its `tiles`:
  the first is the surface, the second the sides, and `tiles` is what the
  item looks like in a hand.

  `plantlike_rooted` is the one whose shape is drawn *as well as* its cube
  faces rather than instead of them: the cube is ground the cube path draws,
  and the plant stands in the voxel above it wearing the first of the
  definition's `extra_textures`, which is `special_tiles[1]`. It is lit by
  the voxel it stands in and not by the ground it is rooted in -- which is
  what `shape_lit_from_above` was built for, and had no user until now.

  **And a node turns with its param2.** `facedir`, `4dir` and `wallmounted`
  -- and the `color*` kinds of each, which put a palette index in the high
  bits and the direction in the same low ones -- are a `VoxelVariant` per
  direction, permuting the definition's own six textures with `tile_order`
  and turning each inside its face with `tile_turns`. That is what those two
  fields were for and they had no user. The tables are Luanti's own
  `dir_to_tile[24][8]` read at the six directions buildat's faces are in,
  taken from `extensions/luanti_client/shapes.lua` which read them out
  first. devtest: 56 node types.

  **A shaped node turns its shape too**, which is Luanti's
  `transformNodeBox`: a step facing the other way is the same quads rotated,
  and the tile each quad names travels with it. The rotation matrices are
  derived *from* the tile table rather than from Luanti's handedness
  conventions -- the table says which local face ends up in which world
  direction, and three of those give the columns -- so the two check each
  other, and `check_shapes()` asserts each comes out a proper rotation.

  simplified: the texture is not turned inside a shape's quad. `tile_turns`
  does that for a cube's faces and the mesher does not apply it to a shape,
  so a turned node box wears its textures straight. And a rooted plant's
  shape is not turned at all: it stands in the voxel above its own, and
  rotating it would take it sideways out of that voxel.

  **`firelike`, `torchlike` and `signlike`** are single quads.
  `firelike` is the crossed pair a plant is. The other two are the one
  drawtype family whose shape is *built* per wallmounted direction rather
  than turned from one base: a torch on the floor leans and a torch on a
  wall lies flat against it, and Luanti picks a different tile for each --
  the definition's first on a floor, its second on a ceiling, its third on a
  wall. `drawSignlikeNode` and `drawTorchlikeNode`, by way of the
  extension's `sign_quads` and `torch_quads`.

  **`fencelike`** is a post that is always drawn and a pair of bars towards
  each direction that has something to reach -- another fence of any kind,
  or anything solid, which is Luanti's rule. The bars carry `connect_dir`,
  so the mesher draws each pair only when that direction connects: that is
  what `connect_dir` is for, the header names a fence as the case, and it
  had no user.

  **`raillike`** is one quad, and which of four tiles it wears and which way
  it is turned is what its neighbours say -- so it is a shape per mask of
  the four horizontal connections rather than a shape: sixteen flat ones and
  four that climb, which is what the mesher's `shape_masked` is for and it
  had no user either. Luanti's own `rail_kinds` and `rail_slope_angle`
  tables, by way of the extension. A rail reaches other rails of its own
  `connect_to_raillike` group and nothing else.

  devtest: 155 of 390 node types have a shape, 83 of them liquids.

  **And the blended pass, which is what makes water water.** A liquid, and
  anything a game asked to be blended rather than alpha masked with
  `use_texture_alpha = "blend"`, is `VoxelDefinition::translucent`. The
  mesher already put those faces on a child node of the chunk so that Urho3D
  sorts them against the other chunks' translucent geometry rather than
  against the opaque geometry they are mixed with -- but nothing gave that
  child a technique, so it was invisible rather than see-through.
  `builtin/voxel_shading` has `PBRVoxelAlpha.xml` now, the same shader
  blended instead of cut out with culling off, and `apply_to_node()` reaches
  the child. It is a builtin rather than the module's, because it is the
  mesher's own child node and every game with water in it wants the same
  thing.

  **And four more are built as cubes that are drawn differently**, which is
  what they are: `glasslike` and its framed variants get an edge material of
  their own per node type, so a face is drawn against anything except more of
  the same glass; `allfaces` and `allfaces_optional` get
  `FaceDrawType::ALWAYS`, so a clump of leaves draws its inside faces too.
  devtest: another 40 node types, and they were invisible before -- glass
  took `EDGEMATERIALID_EMPTY` to let light through, which also stopped
  anything drawing a face against it.

  That is the split this plan called for: `VoxelDefinition::transmits_light`
  says light gets past a voxel that is nevertheless something, and the edge
  material is left to say only which faces are drawn. It is an addition
  rather than a substitution -- an empty voxel still transmits light by being
  empty -- so a game that says nothing keeps the behaviour it had.

  The bundled `minimal_game` has one node of each of the four so the visual
  check shows them without a Luanti installation.

  **What is left, in the order it matters:**
  - **The drawtypes that are left**, and there is not much: the frame of a
    `glasslike_framed` (5 in devtest, drawn as a plain cube, which is what
    it looks like without its frame); the node box kinds that are not
    `fixed` -- `connected` is the same `connect_dir` a fence uses and
    `wallmounted` and `leveled` are a `VoxelVariant` on the param, and
    devtest has none of the three to check an implementation against, which
    is a reason to wait for a game that does; and `mesh` (18), which stays
    client-side or waits. See "Which mesher draws the drawtypes".

    Every other drawtype is built, and with them every piece of the engine's
    shape machinery that had no user: `VoxelQuad`, `shape_lit_from_above`,
    `is_liquid` with the corner levels, `tile_order` and `tile_turns`,
    `connect_dir`, and `shape_masked`.
  - **Palettes**, one voxel type per used index, registered at load.
  - **The client fork.** What is on screen now is
    `games/luanti_launcher`'s viewer, which is a camera and a HUD line. The
    client half is `init.lua` splitting three ways -- 3321 lines, and the
    largest unknown left in the milestone. How the fork is made, what
    survives the move to voxelworld, and who resolves textures are in "The
    protocol, and the client" above.
- **M4 -- it plays. The node half, the inventories and the recipes are built
  (2026-09-13).** Digging and placing, inventory, item definitions, craft,
  formspecs. Success is digging a node in devtest and getting it.

  `place_node`, `dig_node` and `punch_node` hand the pointed thing to the
  vendored builtin with a nil actor, so every callback around a dig is the
  builtin's own; node metadata came with them, a position's inventory is
  what a chest is, and `lua/craft.lua` answers `get_craft_result` for all
  five kinds of recipe. What a dig drops is an item lying on the floor, once
  M5's objects existed for it to be. `doc/plan/luanti_module_history.md` has
  what each turned out to be.

  **Built: a click is a dig (2026-09-13).** The first piece of the client
  half, and the one M4 was waiting for. `games/luanti_launcher`'s client
  marches a ray from the camera, draws a wireframe box around the node it
  hits and sends that node's position on a left click; the launcher hands it
  to `luanti::Interface::dig_node()`, so can_dig, after_dig_node, the drops
  and every other callback around a dig are the vendored builtin's own.

  **Built: the other button places and uses (2026-09-13).** A right click
  sends the node pointed at and the empty voxel in front of it, and the
  module hands both to `core.item_place()` -- the vendored builtin's own --
  so the pointed node's `on_rightclick` wins if it has one and the player's
  wielded item is placed otherwise. What is placed comes out of the
  inventory, which is the loop M4 is named for closing: dig a node, get it,
  put it back.

  simplified: no sneaking, so a node with an `on_rightclick` cannot be built
  against. Luanti's client sends whether the player was holding sneak, and
  this is where that flag would go.

  **Built: the digger is a player, and the drops are theirs (2026-09-13).**
  The dig carries the name the client connected under, and
  `core.handle_node_drops()` puts what it drops in that player's inventory
  rather than on the floor. `core.dig_node(pos)` stays Luanti's own -- it
  takes no digger, and it is the dig nobody did -- so the one with a digger
  is `core.__dig_node(pos, digger)` beside it.

  What it needed was `core.get_dig_params()`, which was a stub: a dig with
  no digger never reaches it and a dig by a player does, so until it
  answered, a click dug nothing. It is the walk over a tool's groupcaps from
  Luanti's `src/tool.cpp`, with the cases it decides asserted at every
  start.

  Two things the engine needed for it, both because a client reasoning about
  voxels could not: `VoxelRegistry:id_of(voxel)`, since `VoxelInstance`'s own
  id is the legacy layout of the word and a Luanti world says otherwise --
  its id is sixteen bits with the light above them -- and a `get_by_id` that
  takes a number, since luabind will not bind a Lua number to the `const
  VoxelTypeId&` the old binding wanted and the call had never been made from
  Lua before.

  **What checks it:** the client harness, which is what can click.

      bin/buildat -s localhost -w 1024x768 -c "@script"

  with a script that flies to the floor, screenshots, clicks and screenshots
  again; the server says `main:dig (x, y, z): dug` and the second click
  lands on a different node, which is the client's own map having caught up.

  **Built: the client is sent the player's inventory (2026-09-13).** The
  module sends it to that one client whenever it has changed -- an inventory
  counts its own changes, so a step sends the ones that have -- and the
  module's client half hands the lists to whoever is drawing.
  `games/luanti_launcher` draws a line of text saying what the player is
  carrying, which is what says that digging a node put the node somewhere.
  The packet is what a formspec's `list[]` will read.

  **Built: the formspecs (2026-09-13).** `core.show_formspec()` and
  `core.close_formspec()` send the form to that one client;
  `formspec.lua` and `formspec_ui.lua` are copied from
  `extensions/luanti_client` and draw it, and what was pressed comes back as
  `luanti:fields` into `core.registered_on_player_receive_fields`. A
  player's `set_inventory_formspec()` is sent when it changes, so the
  inventory key opens it without a round trip -- that is what `I` does in
  `games/luanti_launcher`.

  The four things `formspec_ui.new()`'s ctx asks for: the textures are the
  composer the texture modifiers already are, the inventory is the packet
  above, an item's image is the expression the server sends for each
  registered item (`core.__item_images()`), and the style is `__menu`'s.

  **Built: a stack is picked up and put down (2026-09-13).** A click on a
  slot picks the stack up -- the whole of it with the left button, half with
  the right -- and the next click puts it down, which is when the move is
  sent: Luanti's own client does the same, so what is held is a drawing and
  a highlight on the slot it came from. The server moves it, and what a form
  shows is redrawn when the inventory comes back. The arithmetic -- merging,
  swapping onto a different item, what does not fit going back -- is checked
  at every start.

  **Built: a chest (2026-09-13).** A node with a `formspec` in its metadata
  opens it when it is right-clicked -- Luanti's own client does that itself,
  and here the server does, because the node metadata is the server's. The
  form remembers which node it is about, which is what `current_name` means
  in one; the node's lists are sent to that client and kept up to date the
  way the player's own are, the fields go to the node's `on_receive_fields`
  rather than to the global callbacks, and a move touching a node asks its
  `allow_metadata_inventory_move`/`_put`/`_take` first and tells its `on_`
  half afterwards.

  **What is left of M4:** a detached inventory, which is nobody's here and
  draws empty. And what is picked up is what is put down: Luanti puts a
  single item down with the right button and ten with the middle, which is a
  count on the way down as well as on the way up.
- **M5 -- it lives. Built 2026-09-13.** ABMs, LBMs, entities, `core.after`.
  Success is `testabms` and `testentities` behaving.

  The globalsteps run, and with them `core.after` and everything written on
  a timer. ABMs and LBMs sweep the loaded sections, matching content ids in
  the module rather than names in Lua. The objects are a position, a
  velocity, an acceleration and a box, with a collision that answers the
  `moveresult` the builtin's own entities assert on -- which is what makes
  the dropped item and the falling node work. Node timers are the last of
  the timers. `doc/plan/luanti_module_history.md` has the detail, including
  the mutex that a step doing real work turned out to need.

  **Built: the objects are on screen, wearing something (2026-09-13).**
  The first version put a node per object in the module's own scene and let
  `replicate` carry it, which answered whether `replicate` fits -- where an
  object is, it carries -- but a material is a resource file and a Luanti
  object's texture is not, so everything was a stone box.

  So the objects are the client half's now. Where they are is broadcast
  every step as a flat array of doubles; what they look like is broadcast
  when it changes, and a client that connects later asks for the lot with
  `luanti:get_object_props`. The client makes a node per object: a
  `BillboardSet` for a sprite and `Models/Box.mdl` for a cube, both wearing
  a material made at runtime with the composed texture on it, unlit --
  because the light a voxel game needs is bright enough to turn a lit sprite
  into a white blob.

  What an item lying on the ground looks like is the expression its
  inventory image is, which the item images already are: a dropped pickaxe
  is the pickaxe.

  simplified: one texture rather than six for a cube, and a mesh is a cube
  wearing its first texture. Luanti's two mesh formats are read by
  `b3dmesh.lua` and `objmesh.lua` in `extensions/luanti_client`, and putting
  them in is a milestone of its own.

  **Built: the players (2026-09-13).** A player is an object with somebody
  on the other end of it: it is in the same table as the entities, so
  everything that looks for objects finds it, and what is different is that
  nothing here moves it -- where a player is is what their client says, a
  few times a second. `games/luanti_launcher` makes one per connected
  client, named after the peer, and the join and leave callbacks a mod
  registers run on it. PlayerRef has what a mod asks of a player: the name,
  the inventory Luanti gives one, the metadata, the hit points with the
  hpchange callbacks and the difference they are told about, the look
  angles, the wielded item, the hotbar, and the HUD and sky calls as
  answers rather than as nothing.

  Two things it needed that were missing entirely: the vendored builtin's
  `core.registered_on_mods_loaded` callbacks were never run -- which is also
  why the item registries never froze -- and `core.auth`, the row per player
  the builtin's auth handler is written on, which is a table in memory here
  because nothing asks a player for a password.

  **What devtest's unittests say.** Reaching them is the point: the suite
  waits for a player and then runs eighteen more tests. It is 44 of 50 now,
  from 32 of 40 -- the player's hit points, metadata, position, hotbar and
  guid, the protocol version, the vector properties, and the map tests that
  needed somebody to stand in the world. The remaining six are the
  simplifications the plan names, and the suite stops at
  `test_mapgen_edges`, which wants a mapgen.

  **What is left of M5:** what an object looks like -- a sprite, a mesh, the
  item it is -- which is the forked client's, and the attachments and bones
  a scene node does not carry.

- **M6 -- the launcher. The menu is built (2026-09-13); the map is not.**
  `games/luanti_launcher` as described above.

  **The menu.** With no world chosen the server waits, and a client that
  connects is sent `main/menu.lua` rather than the world view: it asks for
  the list, draws it with `ui_utils.vertical_menu` and sends back either
  "open this save" or "make one called this, playing that game". The scan is
  the server's, because the server owns the filesystem. A save records the
  gameid it needs as a key in its own store, written whenever it is run, so
  the list says which game each save needs without opening any of them --
  the two facts Luanti's menu made one. The saves are listed by when each
  was last played.

  `BUILDAT_LUANTI_GAME` and `BUILDAT_LUANTI_WORLD` still run a world at
  start without a menu, which is what every check here does.

  simplified: the twelve most recent saves, because `vertical_menu` does not
  scroll and a list longer than the screen has saves nobody can reach. What
  it wants is a scrolling list.

  **What is left of M6: the map.** The world is 3x3x3 sections, which is why
  the importer drops most of a real Luanti world, and a map that loads and
  unloads around a player is what the mapgen seam was deferred until there
  was something to measure.
- **M7 -- an existing Luanti world opens. The map and the clock are read
  (2026-09-13).** Read a Luanti world directory -- `map.sqlite`,
  `map_meta.txt`, `env_meta.txt`, the player and mod storage databases --
  and write a buildat save. One direction.

  `builtin/luanti/mapblock.h` reads a MapBlock at serialization versions 25
  to 29, which is every world written since 2013, and
  `luanti::import_world()` puts the blocks into the running game's world and
  the clock into its clock. `doc/plan/luanti_module_history.md` has the two
  shapes the format has and how the reader was checked against Luanti.

  What hangs off the nodes comes too, now that step 5c of the persistence
  plan gives it somewhere to live: the metadata of every node that has any,
  as its fields and its inventory lists.

  What the mods remembered comes too: `mod_storage.sqlite`, per mod, into
  the files this module keeps a mod's storage in. A value the save already
  has is kept, so importing twice does not take a mod's memory back.

  The players come too, now that a player is something the save holds (step
  5d of the persistence plan): `players.sqlite` gives each name a position,
  a look, health, breath, metadata and inventory lists, and what the save
  already knows about a name is kept, so importing the same world twice does
  not undo what has happened since the first time. Luanti's position is in
  BS units -- nodes times ten -- and its angles are degrees.

  **What is left of M7:** `map_meta.txt`, which is the seed and the mapgen
  parameters and has nowhere to go until there is a mapgen; a world whose
  players are one text file each under `players/` rather than a database;
  and a block's node timers and static objects, which are walked past -- the
  objects want a `static_save` that means something here first.

  **The world is 3x3x3 sections**, so what fits is about 192 voxels a side
  around the origin and the rest of a Luanti world is counted and dropped.
  That is M6's map rather than the importer's problem; the importer clips
  per block and says how many blocks it left outside.

  **Not the other direction, and not a live format.** Writing Luanti's
  format would mean bit-compatible `MapBlock` writes forever and would force
  buildat's own world data into a pocket beside it -- and buildat's voxel
  word is extended by *planes*, which a Luanti MapBlock has nowhere to put.
  An exporter is the importer pointed backwards and can be written if anyone
  ever asks. See `doc/plan/world_persistence_plan.md`.

M1 to M3 is where the module's shape is decided; everything after is surface
area, and surface area is the part that can be added forever.

## The map, and how it streams (built 2026-09-13)

Moved out of the plan, which had it as a settled design before it was code.
Most of it turned out to be engine work with three callers rather than
Luanti work, and the reasoning below is why the interface is the shape it
is.

**The world is 3x3x3 sections no longer.** It was about 192 voxels a side
because `create_world()` asked `voxelworld` for that region and
`generate_world()` filled it; sections now come and go around the players.
Not a bigger fixed world -- the point of a Luanti world is that it goes on,
and a fixed one only moves the wall further away.

**What the instance region turned out to mean.** It was used in two places:
the loop that creates the initial sections, and one line of the skylight
that finds the top of the world. Sections outside it already loaded on
demand, so nothing enforced a barrier at the edge. So it kept both of its
meanings and residency became a layer on top: the region is the world's
**bounds and its sky height**, nothing outside it is ever loaded, and a
world that sets load points is not filled with it at the start. A Luanti
world asks for the map's limits, 484 sections each way; `infidigger` and
`bomber_drone` ask for as much as anyone will ever walk and three sections
of height, which is what they always had.

The consequence to remember: a section is lit by the sky only through the
column above it, so a newly loaded section would be dark if anything above
it were missing. Luanti answers that by lighting a block at generation time
from the mapgen's own heightmap; that is the answer here too, when there is
a mapgen. Until then the singlenode fill writes full sunlight into every
voxel it makes, which is what `MapgenSinglenode` does for the same reason.

**The streamer is `voxelworld`'s, not a game's.** `games/infidigger` and
`games/bomber_drone` each streamed server-side with the same 150 lines, one
copy-pasted from the other, and this module would have been the third copy.
Both deleted their copies when the engine version landed, which was the
check that the interface could express what they do: 268 lines out of the
two games for 116 in.

**A load point carries its own radii, and two of them.**

    struct LoadPoint
    {
        pv::Vector3DInt32 p;              // in voxels
        int16_t load_xz, load_y;          // in sections
        int16_t generate_xz, generate_y;  // load_* >= generate_*
        size_t peer;                      // whose it is, or zero
    };

Sections within the load radius are loaded if the save has them and left
alone if it does not -- what a player sees far away is the terrain that is
already there, and new terrain appears closer in. Within the generate
radius they are generated as well. A loaded section outside every point's
load radius is unloaded, so the gap between the two radii is also the
hysteresis that stops a player walking back and forth over an edge from
generating the same section twice. `load_section()` already split at exactly
that line, so "load it if the save has it" was the existing function minus
one call; what had to be added was a negative cache, because otherwise the
load radius asks the save about every section it does not have, every pass.

The radii are per point for two reasons rather than one. A player needs a
big radius and a machine that only has to keep working needs the smallest
one that does. And **two players need different radii from each other**: a
client on a weaker computer wants less sent to it, and loading more than
that client will look at is the server spending memory on nothing. A pinned
section -- one somebody has dug in, in a game that does not save -- is a
point with every radius zero, which fell out for free.

**Luanti's three ranges, and where each of them went.**

| Luanti's range | Where it went | Why |
| --- | --- | --- |
| `max_block_send_distance` (12 blocks) | `voxelworld`, per peer, declared by the client | only the client knows what its computer can take; the server caps it at the load radius, because it cannot send what it does not keep |
| `max_block_generate_distance` (10) | a load point's generate radius | the engine owns the section lifecycle |
| `active_block_range` (4 blocks, which is exactly one section) | `builtin/luanti` | `voxelworld` has no idea what an ABM is |

**The per-peer send range was a hole, not a refinement.** Every chunk went
to every peer on the scene; nobody noticed over 27 sections. The filtering
itself belongs to `replicate`, which is what decides what a peer has:
`set_node_filter()` answers per peer and per node, a node that stops being
wanted is removed from that peer the way a deleted one is, and
`refresh_peer_nodes()` is how a peer that moved gets asked about again.
Without a filter every peer still gets every node. `voxelworld` answers the
filter from the peer's own load point and the range its client asked for
(`voxelworld:set_send_distance`, from `M.send_distance` in its client half),
and it answers it behind a small lock of its own because `replicate` asks
during its own sync. Measured on infidigger: a client that asks for 130
voxels gets 571 chunk updates where one that asks for 1000 gets 8101.

**What the module owed the streamer, and what each turned out to be.**

- **`get_loaded_sections()`**, which the sweeps wanted anyway: they walked
  the bounds and skipped what was not there, and over a streamed world that
  walk is the cost.
- **The active range.** `__active_boxes()` is now the loaded sections within
  a section of a player rather than every loaded section, and the node
  timers and the objects ask the same list. That one was not only a cost:
  over a streamed world a furnace in a section nobody is near would fire,
  read nothing where its node is and stop being a furnace. A world with
  nobody in it is a world where nothing happens, in Luanti as well as here.
- **Node metadata per section**, which is the one piece that is left; see
  "The map, as it was built" in the plan.
- **Node timers that stop with their section**, which the active range gave.

The singlenode fill needed nothing: `on_generation_request()` already
answered a `GenerationRequest` per section, which is the path every streamed
section takes.

**What a game says now.** `infidigger` and `bomber_drone` keep a set of
pinned sections and a position per player, build the points once a tick when
anything has changed, and turn the streamer's budget down to nothing while
their generator's queue is long -- only the game can see that queue, so
`set_stream_budget()` is how it says so. Everything else about streaming is
gone from both of them.
