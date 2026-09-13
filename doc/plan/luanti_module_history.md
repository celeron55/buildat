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
 A Lua state, the vendored `builtin/`
  loaded, devtest's mods loaded in dependency order, every
  `core.register_*` accepted and recorded. Success is the server logging the
  node and item counts devtest registers and not dying. No client involved.
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


