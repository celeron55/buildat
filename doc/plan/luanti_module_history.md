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
