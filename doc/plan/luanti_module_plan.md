# Plan: builtin/luanti -- a Luanti game and world as a buildat module

Written 2026-09-12. M0 and M1 built the same day (PR #52). M2 is planned down
to an order of work with every question it opened answered, and M3's shape --
how the client is forked and who resolves what -- is settled too; only
`init.lua` is left unexamined there. Related:
`doc/plan/world_persistence_plan.md`, which came out of those answers.

## What it is

A buildat builtin server module that runs an unmodified Luanti *game* -- its
mods, its nodes, its items, its callbacks -- inside buildat_server, served to
an ordinary buildat_client. No Luanti network protocol anywhere: the game
logic is Luanti's, everything around it is buildat's.

A buildat game depends on `builtin/luanti`, tells it where a Luanti game and
world are, and from then on can extend that world through buildat's own
module interface -- and through Lua loaded into the Luanti environment, since
a developer using this is assumed to be willing to fork the game they are
running.

This is the opposite end of the telescope from `extensions/luanti_client`,
which speaks the real protocol to a real Luanti server. That client is where
half of this one comes from; see "The client" below.

## The decision that sizes everything

Luanti's server is not small. Rough counts from `~/projects/luanti`:

- `src/script/lua_api/` 17.5k lines of C++ (server, client and main menu)
- `src/mapgen/` 9.5k lines
- `builtin/game` + `builtin/common` -- the Lua layer that sits on top of the
  C API and implements a large part of what mods actually call
- plus nodedef, itemdef, inventory, craft, metadata, active objects, the map
  and its light propagation

Writing all of that again is not a plan, it is a career. So **parts of Luanti
are vendored into the module**, and the split is chosen deliberately:

- **Vendored: the leaf, data-shaped parts.** `MapNode`, `VoxelManipulator`,
  `NodeDefManager`, `ItemDefManager`, `Inventory` and `ItemStack`,
  `CraftDefManager`, `NodeMetadata`, `tool.cpp`, `noise.cpp`,
  `voxelalgorithms.cpp`, `settings.cpp`, `util/`, and in time the whole of
  `src/mapgen/` with its biomes, ores, decorations and schematics. These are
  the pieces that are expensive to rewrite, boring to get subtly wrong, and
  almost free to carry: they compute, they do not own the server.
- **Vendored: Luanti's `builtin/*.lua`**, pinned at a known version rather
  than read out of whatever the user happens to have installed. It is a
  large part of the API surface and it is already written.
- **Written against buildat: everything stateful.** The environment, the
  map's residency, active objects, players, networking, the main loop. These
  are what the module is *for*; vendoring `Server`, `ServerEnvironment` and
  `Map` would produce Luanti with buildat bolted to the side, which is not
  what is being asked for.

The Lua API bindings fall either side of that line. Where an `l_*.cpp` only
touches vendored data classes -- `l_item`, `l_craft`, `l_noise`,
`l_nodemeta`, `l_areastore`, `l_settings`, `l_vmanip`, `l_mapgen` -- it is
worth vendoring and adapting. Where it reaches into `Server` or
`ServerEnvironment` -- `l_env`, `l_object`, `l_server`, `l_auth` -- it is
written fresh against buildat, because that is where the two engines actually
differ.

Even so, the surface to write stays **discoverable rather than designed**:
load Luanti's builtin and the game's mods, run them, see what is nil, write
that. That is the estimating method for the whole plan and it should be said
out loud.

### Licence, and why this is allowed

Luanti is LGPL-2.1-or-later; buildat is Apache-2.0. This works because
buildat modules are **dynamically linked at runtime**: `src/server/rccpp.cpp`
compiles each module to its own `-shared` object and `dlopen`s it. The
vendored Luanti code lives in that object, which is LGPL; `buildat_server`
itself stays Apache and links nothing of Luanti's.

What that obliges, and what should be set up once at the start rather than
retrofitted:

- `builtin/luanti/` carries its own `COPYING.LESSER` and keeps every
  vendored file's licence header intact.
- Vendored files that are modified say so at the top -- which version they
  came from and what was changed -- the way `res/PBRVoxel.glsl` already does
  in the client.
- The vendor tree is kept separate from the module's own source
  (`builtin/luanti/vendor/`) so the boundary is visible in the file listing
  rather than only in headers.
- Code does not travel the other way: nothing under `builtin/luanti/vendor/`
  gets copied into buildat proper.

### How it gets built

Modules are compiled at runtime, one `.cpp` at a time -- and **the result is
cached**: `build_module_u()` (`src/server/state.cpp:655`) hashes the source,
its includes and the optimisation flags and skips the compile when nothing
changed. So a large module is compiled once per source change, not once per
server start, which is why this is a smaller problem than it first looked.

Two shapes are therefore both acceptable, and which one is chosen can wait
until there is vendored C++ to weigh:

- **One runtime-compiled `vendored_luanti.cpp`** that includes the vendor
  tree. Nothing new at all, at the cost of a long single-TU compile whenever
  the module changes.
- **A static library built at buildat build time** by CMake, linked by the
  module. `meta.json` already carries `cxxflags` and `ldflags`
  (`src/interface/module_info.h:17`), so this needs no new mechanism either
  -- only a README line, since `builtin/luanti` would then be the first
  builtin that does not build from a clean checkout without a step of its
  own.

What matters is not which: it is that the vendored code gets compiled
somehow and that it ends up **only in `builtin/luanti.so`**, which is
dlopened, so the licence boundary holds either way.

## The data model, and what buildat already gives us for free

| Luanti | buildat | state |
| --- | --- | --- |
| content id + param1 + param2 | one voxel word under a game-chosen format | `extensions/luanti_client` already defines this mapping; reuse it |
| 16x16x16 MapBlock | 32^3 voxelworld chunk, 64^3 section | settled below: nothing changes, and Luanti's mapgen chunksize becomes 4 so a mapgen chunk is one section |
| skylight in param1's low nibble | `voxelworld`'s own skylight propagation | **already implemented server-side** (`m_skylight_enabled`, the seed list and the commit in `voxelworld.cpp`) |
| lamplight in param1's high nibble | nothing | a build: voxelworld floods sky, not sources |
| NodeDefManager | `VoxelRegistry` + `AtlasRegistry` | the client fork already turns a Luanti nodedef into these |
| MapBlock serialization | voxelworld's own replication | buildat's, and better suited |

Two things stand out. The first is that **voxelworld already does skylight**,
which is the expensive half of Luanti's light and the half that decides
whether a world reads as a world. The second is that we inherit buildat's
mesher, atlas and PBR path, so a Luanti game rendered this way gets normal
maps, reflections and (once section 7c of the client plan lands) real
shadows, which Luanti itself does not give it.

## What has to be written: the C API surface

Grouped by how much is behind each, and in the order the first run will
demand them. This list is the actual work item; everything else in this plan
is arrangement.

**Cheap, because buildat or the C++ standard library already has it**
`core.log`, `core.get_us_time`, `core.settings`, `core.serialize` (Lua-side
already), `core.get_modpath`/`get_worldpath`/`get_gamepath`, the noise API
(vendored, so it matches Luanti's numbers exactly), `core.request_shutdown`, mod storage (a
store in the save; see `doc/plan/world_persistence_plan.md`),
`core.get_current_modname`.

**Medium: a real implementation, but self-contained**
`core.register_*` (they are mostly Lua-side already; what is needed is the
handful of C hooks under them), item and node definition registration,
inventories and `ItemStack`, the craft manager, node metadata, `core.after`
timers, chat commands and privileges, `core.get_player_by_name` and the
player object's methods, HUD, sounds, particles.

**Expensive, and where the schedule will actually go**
- **The environment**: `core.get_node` / `set_node` / `swap_node` /
  `bulk_set_node`, `find_node_near`, `find_nodes_in_area`, VoxelManip. All of
  it onto `voxelworld`. Straightforward but broad, and the performance floor
  of everything above it.
- **ABMs and LBMs**: Luanti's active block modifiers run over loaded blocks
  on a timer. buildat has no equivalent; this is a scheduler plus a spatial
  iteration, and devtest's `testabms` is a ready-made test.
- **Active objects**: entities, their serialization and their position
  updates to clients. Luanti's `ServerActiveObject` hierarchy is large;
  what a game actually needs is `core.add_entity`, the luaentity callbacks,
  and attachment. Players are an active object too.
- **Formspecs (built 2026-09-13)**: the server sends a formspec string and
  the client draws it with `formspec.lua` and `formspec_ui.lua`, copied from
  `extensions/luanti_client`. It was mostly protocol plumbing, as expected.
- **The mapgen seam**: vendored mapgen output translated into voxelworld
  chunks. Not large, but it is where a whole world is either right or
  visibly wrong.

**Not in this at all**: HTTP, IPC, the async environment, mod channels,
SSCSM, the main menu API, translations beyond passing strings through.
Stubs that log once and return nothing, so a mod calling them does not die.

## Mapgen

Vendored, not rewritten: `src/mapgen/` with its noise, biome manager, ores,
decorations, schematics and tree generator. It is 9.5k lines that nobody
wants to write twice and that has to match Luanti exactly to be worth
anything at all -- a world that is *nearly* v7 is a world that is nothing.

What it costs instead is a seam. Luanti's mapgens write into an `MMVManip`
over `MapNode`s, and buildat's world is `voxelworld` chunks of a game-chosen
voxel word. So the vendored mapgen runs untouched over vendored data
structures, and a translation step writes the result into voxelworld -- the
same translation `set_node` needs anyway, applied a chunk at a time.
`voxelworld`'s `GenerationRequest` event is the trigger, which is the shape
buildat already expects a generator to have.

Staged, because the seam is where the bugs will be:

1. **`singlenode` first, and it is a node and not a void (built
   2026-09-13).** Luanti's own `MapgenSinglenode` fills a generated block
   with whatever `mapgen_singlenode` names, or with air when a game names
   nothing, and sets the sunlight in it -- so what a mod reads out of a part
   of the world nobody has built in is "air", and only what is outside the
   world altogether is "ignore". Every mod that looks before it places is
   written against that, so the module does the same: `create_world()` fills
   the region's sections through `merge_volume()`, which is the generator's
   own priority -- anything a mod has already put there stays.

   It is done before the skylight is turned on, and the fill carries full
   sunlight itself. With the light running, every voxel going from nothing
   to air is a skylight seed: seven million of them, and eight seconds of
   startup to settle what the fill already knew. Before it, the same fill is
   287 ms, and the floor a mod places seeds its own shadow afterwards.

   A section that already holds the node is left alone -- one voxel of it
   says so -- which is what keeps a save from being walked again on every
   start, and what migrates a save written before there was a fill.

   What stands in the world comes from `core.set_node` and from the test
   mods. It proves the translation without 9.5k lines of terrain on top of
   it, and devtest is entirely usable this way. `voxelworld`'s
   `GenerationRequest` is subscribed to as well, which is what a section
   made after the world started goes through -- which is most of them now
   that the map streams, and which is the seam the next stage grows out of.
   See "The map, as it was built".
2. **The Lua mapgen path: `core.register_on_generated` with a working
   VoxelManip. Built 2026-09-13.** A section that has been filled runs the
   callbacks over the box it filled, and a mod writes terrain into it
   through a VoxelManip that really reads and writes the map -- three flat
   arrays read in one call and written in one, in the order `VoxelArea`
   indexes. `core.get_mapgen_object("voxelmanip")` hands a callback the
   section's own and writes back what the callback did to it. The noise a
   mapgen shapes a world with is bound to buildat's vendored copy of
   Luanti's value noise, so a mod's `NoiseParams` means here what it means
   there. See "The mapgen seam" in `doc/plan/luanti_module_history.md`.
3. **Then v7 and the rest**, which at that point is compiling code that
   already works and pointing it at the seam. Two things stage 2 measured
   are arguments for doing it in C++ rather than in Lua: a Lua mapgen over
   a section costs about 600 ms, of which 140 is the skylight and most of
   the rest is a quarter of a million voxels crossing the Lua boundary
   twice; and all of it is on the server's own thread, because this module
   has one Lua state and no thread to put it on. Luanti has an emerge
   thread. A vendored mapgen writes the volume without Lua in the middle,
   and is the point at which an emerge thread of some kind is worth having.

   **What stage 3 is, surveyed 2026-09-13.** `src/mapgen/` is 9.5k lines
   over sixteen files: `mapgen.cpp` (1166) and the eight generators, of
   which v6 (1113), v7 (574) and carpathian (556) are the largest, plus
   `cavegen` (912), `treegen` (888), `dungeongen` (658), and the four
   managers -- biomes, ores, decorations and schematics -- at about 2k
   together. What it includes outside itself is a short list: `map.h` for
   `MMVManip`, `voxel.h` for the `VoxelManipulator` under it (512 lines),
   `mapnode.h` (302), `nodedef.h`, `emerge.h`, `settings.h` and
   `util/numeric.h`.

   So the shim is the work, not the mapgen. Of `nodedef.h`'s 864 lines the
   mapgen uses four calls -- `getId(name)`, `get(content)`,
   `getLightingFlags()` and `pendNodeResolve()` -- and **the one thing that
   already lines up is the important one**: this module's registry id *is*
   the Luanti content id, which is what makes a vendored mapgen's output
   mean anything here at all. `MMVManip` is a flat `MapNode` array over a
   `VoxelArea`, which is what `interface::VoxelVolume` already is, so the
   seam is a translation of one buffer into the other -- the same
   translation `set_node` does, a whole section at a time.

   buildat already carries Luanti's noise in `src/interface/noise.h`, an
   older snapshot without lacunarity or flags; stage 3 wants the current
   one, which is 750 lines and the same file.

### Mapgen stage 3: how it lands (2026-09-13)

**`builtin/worldgen` is the seam, and it already exists.** Its
`GeneratorInterface::generate(scene, section_p, volume)` runs *in a worker
thread with no module held*, takes a padding so that a tree at the edge of a
section can be placed whole, and merges what it produced into the world
afterwards. That is exactly the shape a vendored mapgen wants, and it is
what `games/infidigger` and `games/bomber_drone` already generate through.
So the module creates a `worldgen` instance for its scene and hands it a
generator that is Luanti's `Mapgen` in a shim -- and the 600 ms a Lua mapgen
spends on the server's own thread stops being the server's problem.

**What the shim is.** `MMVManip` is a flat `MapNode` array over a
`VoxelArea`, and `interface::VoxelVolume` is a flat voxel word array over a
`pv::Region`; a `MapNode` is content, param1 and param2, which is exactly
what `VoxelFormat::luanti()` binds. So the translation is a loop, and it is
the same translation `set_node` already does. Of `nodedef.h` the mapgen uses
four calls, and **the registry id is already the Luanti content id**.

Nothing in the generator may touch a module, so what it needs is snapshotted
when the world is created: the content ids by name, the few node properties
the mapgen reads, the mapgen parameters and the seed. The registry is frozen
once the mods have loaded, which is what makes that safe.

**Staged, because the shim is the part that can be wrong.**

1. **3a: the seam itself. Built 2026-09-13, half of it.** The module
   creates a `worldgen` instance and fills its sections through a
   `GeneratorInterface` in worldgen's thread; `worldgen:section_generated`
   is what runs `core.register_on_generated` afterwards on the main
   thread. What the generator holds is given to it when the world is made,
   which is the rule the thread imposes and the shape the vendored mapgen
   needs. The generator's body is still the singlenode fill.

   What is left of 3a is the shim under that body, and it was sized
   2026-09-13 by reading what the mapgen tree actually touches:

   - **`nodedef.h` is a shim, not a vendoring.** Of its 864 lines the whole
     mapgen tree uses `NodeDefManager::getId(name)`, `::get(content)` and
     the node resolver, and of `ContentFeatures` exactly eight fields:
     `walkable` (9 uses), `is_ground_content` (5), `isLiquid()` (3), `name`
     (2), `drawtype` (2), `param_type`, `liquid_type`, `floodable`, plus
     `getLightingFlags()`. That is a thirty-line struct answered from this
     module's own registry, which is already frozen by the time a world is
     made. Vendoring the real one would drag in `itemdef.h`, `sound.h` and
     `tile.h`, which is the client.
   - **`voxel.h` is a vendoring**, because `VoxelManipulator` and
     `VoxelArea` are 512 lines that need only `MapNode` and a vector type.
     `MMVManip` derives from it and is what every mapgen writes into.
   - **`mapnode.h` is a shim**: content, param1, param2 and the handful of
     methods above, which is what `VoxelFormat::luanti()` already binds.
   - **A vector and integer-type header** for `v3s16`, `v3f`, `u16` and the
     rest of Irrlicht's names, which buildat does not use anywhere else.
   - **`noise.h` is the adapter** decided above: Luanti's calls onto
     buildat's own copy.
   - **`settings.h`, `emerge.h`, `gamedef.h`, `log.h`, `profiler.h`** are
     stubs of a few lines each -- what the mapgen reads out of them is
     `MapgenParams`, which the module builds itself.

   Then `mapgen.cpp` compiles, and `MapgenSinglenode` through it is the
   check that the translation is right before anything interesting is
   generated.

   **Where it stands (2026-09-13).** The whole tree is vendored into
   `builtin/luanti_mapgen/vendor/` and the shims above are written; what
   compiles of it is `voxel.cpp`, the noise adapter and the node
   definitions, with a check that a node written into the vendored
   `VoxelManipulator` comes back in voxelworld's own order. The module
   declares `-std=c++17` in its `meta.json`, which is how a module asks for
   its own flags; the rest of the tree stays C++11.

   `vendor/README.txt` says which files are Luanti's and which are shims,
   and where the next session starts: `util/serialize.cpp` wants Irrlicht's
   colour type, `core::clamp` and a name that collides with buildat's own
   `itos`, and after it `mg_schematic` wants zlib -- which buildat has as
   `interface::compress_zlib` -- and `MapNode::serializeBulk`, which lives
   in Luanti's `mapnode.cpp` and is a shim here.
2. **3b: `mapgen_v7` with its own noise, and no managers.** Terrain,
   caves and nothing else. This is the point at which a world looks like a
   Luanti world.
3. **3c: the managers -- biomes, then ores, then decorations with
   schematics and the tree generator.** These are what a *game* registers:
   `core.registered_biomes`, `_ores` and `_decorations` are recorded in Lua
   already and have been since M2, so this step is the translation of those
   tables into `BiomeManager`, `OreManager` and `DecorationManager`. It is
   the biggest of the four and the one a game's own look depends on.
4. **3d: the other generators** -- v5, v6, valleys, carpathian, fractal,
   flat. At that point each is a file that compiles against a shim that
   works.

**Decided 2026-09-13.**

- **Where it lives: a module of its own, `builtin/luanti_mapgen`**
  (decided 2026-09-13, after measuring). A runtime-compiled module is a
  *single* translation unit -- rccpp hands the compiler one `.cpp` -- and
  `builtin/luanti` already takes 9.7 seconds to compile. Vendoring 9.5k
  lines into it would mean every edit to `luanti.cpp` pays for the mapgen
  again, which is the wrong tax to put on the module that is edited most.
  A module of its own compiles once and stays cached.

  What crosses between them: the luanti module hands over the world's seed,
  the mapgen parameters and the content ids by name -- and later the
  biomes, ores and decorations the mods registered -- and gets back
  something that is a `worldgen::GeneratorInterface`. The luanti module
  keeps owning `worldgen`, the scene and the callbacks; the mapgen module
  owns nothing but the vendored code and the shim under it, which is also
  what keeps Luanti's C++ out of the module that does everything else.
- **How faithful:** a world that *looks like* a Luanti world -- biomes,
  caves, ores and decorations in the right places and the right shapes --
  and not one that reproduces upstream's terrain for a given seed. So the
  noise is the one buildat already carries (`src/interface/noise.h`), and
  what the shim adds is an adapter: Luanti's mapgen calls `Noise::
  perlinMap2D()` and reads `NoiseParams::lacunarity` and `::flags`, and the
  adapter maps the first onto `fbmMap2D()` plus `transformNoiseMap()` and
  accepts the other two without acting on them. One small file instead of
  vendoring a second copy of 750 lines and keeping it in step with
  upstream. A seed will not agree with Luanti's, and that is the trade.
- **Lighting stays `voxelworld`'s.** Luanti's mapgen calculates its own,
  which here would be work done twice, so the generator's lighting pass is
  skipped.
- **Settings** are the mapgen's own C++ defaults plus the world's seed;
  `map_meta.txt`'s per-world overrides are a later refinement.

**Still open: does anything want the other seven generators?** 3d is a day
of work for six worlds nobody has asked for yet, so it waits until somebody
does.

The staging is about order, not scope: a mainstream Luanti game is expected
to produce its real terrain, and stage 3 is a milestone rather than a
separate career.

### The region calls (built 2026-09-13)

`voxelworld` has `get_volume()` and `set_volume()`: a region read, and a
region write that overwrites where `merge_volume()` refuses to. They were
deferred until there was something to measure them against, and by the time
they were built there were three callers waiting -- this module's region
read, M5's ABM sweep, and M7's importer.

Both are chunk by chunk with a sampler per chunk, which is what
`merge_volume()` already was; `set_volume()` and `merge_volume()` are the
same walk with a flag, so that the difference between "overwrite" and
"generator priority" is in the name rather than in a parameter. They are in
terms of `VoxelVolume`, so a world of more than one plane keeps its planes.

**What it was worth**, measured against the same work through `get_voxel()`
and `set_voxel()`:

- the ABM sweep in devtest -- nine rules over twenty-seven loaded sections,
  seven million voxels a second -- went from 30% of a core to 24.5%;
- importing 343 mapblocks (524800 nodes) went from 243 ms to 193 ms;
- `minimal_game`'s startup checks, which are region reads end to end, went
  from 605 ms to 384 ms.

So the constant factor is real but it is not what a sweep costs; what a
sweep costs is reading a whole section to find the handful of voxels a rule
is about. Luanti's answer to that is a per-block index of which node kinds
are in it, and that is still the upgrade path -- see the ABMs in M5.

**What checks them:** `lua/check_map.lua` writes four nodes either side of a
chunk boundary and a section boundary and reads them back out of one region
read, because a region read is one read per chunk stitched together and the
stitching is the part that can be wrong. `set_volume()` is what the importer
writes with, and what checks it is the node histogram of an imported world
matching an independent decode of the same database.

## The map, as it was built (2026-09-13)

The world streams. `voxelworld` owns the streamer, a game hands it load
points, and this module puts one under every player and one at the origin;
a peer is sent only the chunks near its own point, as far out as its client
asked for; and the ABM sweep, the node timers and the objects run in the
active range, which is a section around a player. The world is the map's
limits -- 31000 voxels each way, the way Luanti's is -- rather than the
three sections it was. What each turned out to be, and why the interface is
shaped the way it is, is in `doc/plan/luanti_module_history.md`, "The map,
and how it streams".

**And what hangs off the voxels goes with them (2026-09-13).** Node metadata
is a blob per section, written when `voxelworld` says the section is about
to go and read back when it says the section is there --
`voxelworld:section_loaded` and `voxelworld:section_unloaded`, which are the
two events anything keeping something of its own per section wants. The
timers in a section leave with it too. `core.forceload_block()` works, which
is how a mod keeps a section loaded where nobody is standing; the vendored
builtin does the bookkeeping and the persistence and hands the engine a
block position.

**And the map is still singlenode.** Streaming is what a mapgen needs to
exist at all -- a generated world that cannot unload is a world with a wall
around it -- but it generates air, so `map_meta.txt`'s seed still has
nowhere to go and `test_mapgen_edges` still stops. See "Mapgen".

## The protocol, and the client

No Luanti protocol. Everything is a buildat packet, shaped for buildat:

- **Media** goes over `builtin/client_file`, which already exists and already
  caches. Luanti's media announce/request *protocol* is deleted, not ported;
  its **contract** is kept exactly. See "What gets sent" below.
- **Definitions** (nodes, items) are sent as cereal structures carrying only
  what the client draws, not Luanti's serialization format.
- **The world** goes over `voxelworld`'s own replication, which is buildat's
  and is already tuned.
- **Formspecs, HUD, chat, inventory, player state** are small cereal packets,
  one per kind.
- **Entities**: buildat's `replicate` module was the natural home and it
  did carry *where* an object is -- a node per object in the module's scene,
  which every client is already sent. It could not carry what one looks
  like, because a material is a resource file and a Luanti object's texture
  is composed by the client, so both halves are packets of the module's own
  now (answered 2026-09-13). Attachments and bones are still untried.

The client half is `builtin/luanti/client_lua`, forked from
`extensions/luanti_client`. The fork keeps the presentation and drops the
parsing -- but *how much* of the presentation survives contact with
voxelworld is a bigger question than the original table allowed, so both are
below.

### What gets sent, and what does not (settled 2026-09-12)

**Everything static is sent.** That is Luanti's contract and it is not worth
going against: everything a game ships goes to every client, except what the
game deliberately put behind one of the two escape hatches --
`core.dynamic_add_media()`, and ad-hoc texture modifiers, which can even
carry PNG data inline. Everyone who writes a Luanti game knows this and
splits their content between the three accordingly, so a game that is a
problem to serve is a game whose author already had the tools not to make it
one.

So the module does not try to be clever about *which* media to push. An
earlier idea here -- parse the registry's texmod strings, work out which
source files they name, and send only those -- is dropped. The sources are
what the client needs anyway and they are reused heavily, which is where the
saving already is; the set would not be much smaller once items, HUD and
entities are in; and a name built at runtime
(`"default_stone.png^[colorize:" .. x`) names a file nobody enumerated, which
is the hole `dynamic_add_media` exists to plug.

**This binds the Luanti half only.** A buildat game that extends a Luanti
game through `load_lua()` is not in Luanti's contract and can pick whatever
strategy it likes for its own content.

**And all of it is sent (2026-09-13).** Luanti makes no distinction between
a texture, a model and a sound: media is whatever sits in one of a mod's
media directories and ends in an extension the client knows, and what the
client makes of it is the game's business. So `serve_game_media()` collects
every mod's `textures/`, `sounds/`, `media/`, `models/`, `locale/` and
`fonts/` and the game's own `textures/` beside them -- Luanti's own list and
Luanti's own order, `ServerModManager::getModsMediaPaths` -- and keeps what
passes Luanti's whitelist: a name of `[A-Za-z0-9_.-]` ending in `.png`,
`.jpg`, `.tga`, `.ogg`, `.x`, `.b3d`, `.obj`, `.gltf`, `.glb`, `.tr`,
`.po`, `.mo`, `.ttf` or `.woff` (`Server::addMediaFile`). The first file
under a name wins, which is what a clash does in Luanti too. devtest: 450
files from 26 directories, of which 419 are the textures that used to be all
of it, 25 are models, 4 are translations and 2 are sounds.

What it costs is on the transport rather than here, and `client_file` wanted
four things before it could carry a game's whole asset tree: a file read
from disk when it is sent, one announce packet, bunched sends, and a
compressed payload. All four are built;
`doc/plan/master_plan_history.md` section 14 has what each turned out to be.

### What the extension actually is (read 2026-09-12)

20932 lines over 28 Lua files plus `res/`. The largest are `world.lua`
(4649), `init.lua` (3321), `test.lua` (2573), `client.lua` (1548) and
`formspec_ui.lua` (1070).

| taken | dropped |
| --- | --- |
| `shapes.lua`, `texmod.lua`, `surface.lua`, `light.lua`, `b3dmesh.lua`, `objmesh.lua`, `formspec.lua`, `formspec_ui.lua`, `inventory.lua`, `hud.lua`, `particles.lua`, `engine_test.lua`, `res/` | `connection.lua`, `srp.lua`, `serialize.lua`, most of `test.lua` (it checks those two), and the wire-format halves of `client.lua`, `nodedef.lua`, `itemdef.lua`, `media.lua`, `player.lua`, `objects.lua`, `sounds.lua`, `nodemeta.lua` |

`world.lua` and `init.lua` are in neither column, because neither survives
whole:

- **`world.lua` loses about a fifth of itself to `voxelworld`.** Its own
  header describes what changes: "A mapblock is 16^3 nodes... a block becomes
  an 18^3 volume holding the block itself plus a slice off each of the six
  neighbours." That apparatus -- `mark_dirty`, `volume_sources`,
  `mesh_block`, `vis_volume_of`, `collect_vis_volumes`,
  `update_sky_visibility`, `param1_at`/`param2_at` (~1418-1979) and the
  client-side light flood `light_changed`/`light_index`/`flood_light`
  (~3270-3535) -- is what `builtin/voxelworld/client_lua/module.lua` already
  does for chunks, with LOD and physics-distance handling the extension's
  version does not have. Roughly 900 lines replaced by code a dozen games
  exercise daily.

  What is worth taking is the half that was never about the protocol: the
  lighting maths and technique application (578-777), the definition building
  (`add_cube`, `build_variants`, `build_voxel`, the pair map), objects and
  item meshes, particles, and the whole PBR sun/sky/cloud/easing block
  (3535-3790).
- **`init.lua` splits three ways**: the connect and login UI and the status
  screen are dropped, the input, camera and player control are taken, and the
  wiring between world, hud, formspec and inventory is rewritten because its
  inputs become buildat packets instead of protocol commands.

  **What happened instead (2026-09-13):** none of it was taken. The wiring
  was written fresh in `builtin/luanti/client_lua/module.lua` against the
  packets, and the input, camera and player control are
  `games/luanti_launcher`'s own -- which is where they belong, since a game
  hosting a Luanti world decides how it is looked at. So the third of
  `init.lua` that was to be taken is the part nobody has needed; what it
  still holds that nothing here has is the HUD, chat, particles and sounds.

### What a module's client half is allowed to do (settled 2026-09-13)

**Answered: `compose_image` and `add_resource_dir` go into `buildat.safe` as
they are.** With that the texture modifiers are built (2026-09-13): devtest's
generated colours went from 112 to 2, and the client composes 131 textures
into `cache/luanti_res/luanti_texmod/`. What it is made of:

- the server names a tile with a modifier in it something of its own and
  sends the expression beside the registry, since a modifier is not a file;
- `texmod.lua` (550 lines, in the "copied verbatim" column below) turns
  Luanti's modifier language into `buildat.compose_image` operations, and
  `M.resolve(expr, ctx)` is the whole interface: `ctx.resource(name)` maps a
  media name to a resource and `ctx.compose(expr, ops, size)` writes one;
- `client_file` already serves a module's `client_lua/*` as
  `<module>/<file>`, so the module can ship its client half.

**How it runs.** The server names an expression `luanti_texmod/<hash>.png`
and puts that name in the voxel definition; the client asks for the
expressions with `luanti:get_texmods` and gets back name/expression pairs.
It asks rather than being sent them because the definitions arrive before
the module's client half has subscribed to anything -- and because they
arrive first, the textures they name are not there yet, which one
`voxelworld.remesh_all()` after composing settles. An expression that
`texmod.lua` cannot build gets a flat colour of its own hash, so a tile is
never a missing file.

`[png:<base64>` carries a whole file in the expression, so a blit takes
`src_data` (the bytes) as well as `src` (a resource name); the bytes are
read length-first, since a PNG's second byte is already a zero. That was the
last of devtest's 131 expressions.

**What the decision costs, and what was done about it.** Both calls confine
themselves to the cache path, so what sandboxed code gains is "write files
under the cache and make them loadable", which a server can already do
through `client_file` -- it ships whatever files it likes into the same
cache. What changes is that the confinement is now load-bearing for the
sandbox rather than a sanity check. So the rule is one function --
`interface::fs::is_inside_path(path, dir)` -- both of them call, it takes a
path that merely starts with the directory's name (`/cache_evil` for
`/cache`) as outside, and it leaves a self-test behind naming the cases that
matter. **Anything added beside them writes under the cache through that
same call, or it does not go in the sandbox.**

It is lexical: `..` is collapsed, and a symlink under the cache that points
elsewhere is still "inside". What the client writes there is its own and
`client_file` writes plain files, so that is the line for now.

**Not the two shapes it was not.** A per-module composed-texture directory
(`buildat.safe.module_resource_dir()`) would put the confinement in one
place per module, at the cost of engine code and of the sandbox having to
know which module is calling, which it does not today; it stays available if
a module ever has to be kept out of another's files. And the server
composing and shipping PNGs was rejected in "Who resolves textures" -- it
forfeits client-side texture size, filtering and texture packs, costs more
bandwidth than the sources, and cannot do the runtime cases at all.

### How the fork is made (settled 2026-09-12)

**Not by splitting the extension first.** `world.lua` is one closure --
`M.new()` runs 339 to 4566 with everything as locals inside it -- so there is
no file-level seam to fork along, and making one would mean refactoring
recently art-directed code while trying to do something else. Managing that
split would add friction to the task actually at hand.

So instead:

- **Leaf files are copied verbatim.** `shapes.lua`, `texmod.lua`,
  `surface.lua`, `light.lua`, `b3dmesh.lua`, `objmesh.lua`, `formspec.lua`,
  `formspec_ui.lua`, `engine_test.lua` and the rest of the taken column are
  close to pure functions; they arrive whole and are edited only where they
  break.
- **`world.lua` and `init.lua` are rebuilt from hand-picked parts as they are
  needed.** Their inputs change -- a server-built registry instead of a
  parsed one, voxelworld chunks instead of mapblocks, packets instead of
  protocol commands -- so copying the closure wholesale would mean deleting
  machinery whose inputs no longer exist, which costs more than writing what
  is wanted. Take a piece when the thing it draws is the next thing to work.

**Taken so far (2026-09-13):** `texmod.lua`, `formspec.lua`,
`formspec_ui.lua` and `hud.lua`, all verbatim but for how they load each
other and one resource path. `b3dmesh.lua` and `objmesh.lua` are the next
two and are what the meshes question is about; `world.lua` and `init.lua`
have not been drawn from at all -- what draws the world is `voxelworld`'s
own client and what drives it is `games/luanti_launcher`.

**Every copied file records where it came from**, at the top, the way
`res/PBRVoxel.glsl` already does -- the extension's revision as well as its
name. That is not bookkeeping for its own sake; it is what makes the
reconciliation below a comparison rather than an excavation.

**`res/PBRVoxel.glsl` is forked too, making three copies** -- the original in
`builtin/voxel_shading`, the extension's art-direction fork, and the
module's. For the same reason as the rest: easy to reconcile later, hard to
manage now, and if it has to diverge then it is allowed to. `res/` also moves
from an extension path to the module's `client_data`, so every resource name
in it changes.

**`skyvis.lua` stays client-side**, even though the server could compute
lighting. It answers how much sky the camera sees in each direction, per
frame, from the camera's position, and `res/PBRVoxel.glsl` multiplies its
reflections of the sky cube map by it. Two reasons, and the second is the
general one:

- The server does not spend CPU on moment-to-moment client rendering. This
  is per-frame, per-camera work whose cost scales with viewers and whose
  result nothing but one client's next frame depends on.
- **In buildat almost all style is the game's own, ideally all of it.** Sky
  visibility is an indoor/outdoor treatment -- a choice about how a world
  looks -- not a fact about the world. Moving it to the server would move a
  style decision out of the place where style belongs.

Worth noting while taking it: `skyvis.lua`'s header says it is a port of
`builtin/voxel_shading/client_lua/module.lua`, which does the same thing **against
voxelworld**. The module's client reads voxelworld, so it may be able to use
the original rather than carry the port -- a thing to check when it is picked
up, not a decision to make now.

**And the two copies are reconciled afterwards, as a project of its own.**
When the module's client works, it is compared with
`extensions/luanti_client` and whatever should be shared or back-ported is
dealt with then -- as the only task at hand, with the attention that needs.
Doing it continuously, while M3 is being built, would mean two moving targets
and neither finished.

**The rule that still holds**: `extensions/luanti_client` stays the client
for real Luanti servers. The reason is sharper than the original one about a
sandbox boundary, and the boundary is not actually the obstacle -- sandboxed
code *can* `require("buildat/extension/<name>")`, getting whatever `safe`
interface the extension exposes (`client/sandbox.lua:68`). The real reason is
distribution: **an extension is installed with the client; a module's
`client_lua` is served by the server.** A module that leaned on the extension
would depend on what happens to be installed on the player's machine, and a
server could not ship a fix to its own presentation code. That is against the
whole shape of buildat, and it is why the duplication is correct rather than
merely tolerable.

### Which mesher draws the drawtypes (settled 2026-09-12)

**buildat's own, server-side, as `VoxelDefinition::shape`.** Not a fork of the
extension's Lua meshing. The engine's mesher was extended for exactly these
requirements and the machinery is finished and unused: `generate_voxel_shapes()`
(`src/impl/mesh.cpp:900`), `VoxelQuad` with a `connect_dir` whose documented
cases are a fence and a pane (`src/interface/voxel.h:43`), `shape_group`
culling between neighbours, `shape_double_sided`, `shape_lit_from_above`,
`liquid_top` for a flowing liquid's surface, and `VoxelVariant::tile_order` /
`tile_turns` so a facedir permutes a cube's six textures instead of needing a
voxel type per rotation. **No game or module in this tree builds a single
`VoxelQuad`**, so M3 is what proves it -- which is a reason to do it this way
rather than a reason not to.

What this buys beyond not writing a mesher twice: the shapes go in the
registry the server already sends, so they replicate, they land in a save with
everything else, and the module's client does no meshing at all -- which is
most of what made `world.lua` 4200 lines.

**What a `VoxelQuad` has to be, read out of `generate_voxel_shapes()`
(`src/impl/mesh.cpp:1277`) since nothing in the tree builds one yet:**

- **The winding makes the normal.** The mesher takes
  `(p[1]-p[0]) x (p[2]-p[0])` and normalises it, so the four corners go
  counter-clockwise seen from the side the quad faces. It emits 0,1,2 and
  0,2,3, and `shape_double_sided` adds 0,2,1 and 0,3,2 with the normal
  negated.
- **The corners are in the voxel's own -0.5...0.5 cube**, which is where
  Luanti's node boxes already are, so a `node_box` arrives as it was written.
- **`uv` is 0...1 in the tile, 0,0 at its top left**, and the mesher maps it
  into wherever the atlas put that tile. A box face showing the part of the
  node's texture it covers -- Luanti's `makeCuboid` -- is the box's own
  extents on the two axes of that face, and it is worth doing: without it a
  slab wears the whole texture squeezed into it.
- **`tile` is 0...5 for one of the six faces and 6 and over for an entry of
  `extra_textures`**, so a shape that is more than one material has somewhere
  to put the rest.
- **The face order is +Y, -Y, +X, -X, +Z, -Z**, which is Luanti's tile order
  (top, bottom, right, left, back, front) exactly.
- **A shaped voxel usually wants `face_draw_type` NEVER and
  `edge_material_id` EMPTY**, or it draws cube faces as well as its shape and
  its neighbours do not draw theirs against it.

The named exception is **drawtype `mesh`**: an arbitrary .b3d or .obj is
triangles with skinning, not quads in a unit cube, and `b3dmesh.lua` /
`objmesh.lua` exist in the extension for it. It stays client-side, or it waits.
`nodebox`, `plantlike`, `firelike`, `fencelike`, `glasslike_framed`,
`raillike`, `torchlike`, `signlike` and the liquids all decompose into quads.

### Who resolves textures (settled 2026-09-12)

**The server decides which voxel types exist; the client decides what their
pixels are.** So the registry the server sends carries texmod *strings* as
its texture names, and the client resolves them through
`buildat.compose_image` when it builds its atlas -- which is what
`extensions/luanti_client` already does, with `resolve_tile` handed into
`build_voxel`.

The engine settled most of this already. `VoxelDefinition::textures[6]` are
`AtlasSegmentDefinition`s -- definitions, not references -- and
`src/interface/voxel.h:112` says why: "These must be definitions (not
references) because each client has to be able to construct their atlases
from different texture sizes." Shipping composed PNGs would hand the client a
baked thing the data model expects it to bake, and would forfeit everything
that depends on the client choosing: texture size, filtering, and client-side
texture packs.

Two more reasons pointing the same way:

- **Bandwidth.** Texmods reuse their sources heavily -- one
  `default_stone.png` behind twenty colorized variants. Sources plus strings
  is less to send than every composed result, and the sources ship anyway.
- **The runtime cases do not work server-side at all.** Crack overlays,
  animated tiles, palette colorize. Resolving those on the server means
  either enumerating every combination up front or resolving lazily on
  demand -- a round trip mid-dig, and server CPU spent on one client's next
  frame. The same rule as `skyvis.lua` above.

**The cost, stated honestly:** `compose_image`'s operations are fixed in C++
-- blit, fill, multiply, colorize, hsl, alpha, chromakey, transform, resize,
crop, shear -- so a texmod that does not decompose into those needs a new
one, which is an engine change rather than a module change. Server-side
resolution has the identical limit unless the server grows an image
compositor of its own, which would be a second implementation of the same
thing, free to diverge.

**What this does to the (id, param2) pair machinery: most of it dies.** In
the extension, a palette node becomes one voxel type per (id, param2) colour
pair, registered client-side -- which cannot work when the registry is the
server's. It does not need to:

- **Facing and liquid level need no pairs**, because
  `VoxelFormat::luanti()` binds `param` and `VoxelVariant` interprets it.
  That was the point of binding `param` in the first place.
- **Palettes are a variant per colour** (built 2026-09-13), not a voxel type
  per colour: the registry id is the Luanti content id, so a second type per
  colour cannot be registered at all. The palette is in the nodedef, so the
  colours are known, bounded by 256 and enumerated once rather than
  discovered per block; see "The palettes" below.

## The module interface

Minimal at first, grown as something needs it. What the first version has:

    struct Interface
    {
        virtual void run_game(const ss_ &game_path, const ss_ &world_path) = 0;
        virtual void load_lua(const ss_ &chunk, const ss_ &chunkname) = 0;
        virtual ... on_lua_event(name, handler)
    };

`load_lua()` is the whole extension story at the start: a buildat module hands
Lua into the running Luanti environment and that Lua does whatever the Luanti
API allows, including calling back out. The module ships some of its own this
way -- a `buildat` table inside the Luanti environment -- which is how things
get exposed "in the right way" rather than by widening the C API every time.

## games/luanti_launcher

A sample game that does nothing but host a save.

Paths follow `doc/plan/world_persistence_plan.md`, which is where the terms
come from: a **save** is what the user names and picks, a **world** is a
`voxelworld` instance inside it, and a Luanti world is one of each.

- Luanti games are scanned from `user_path/luanti/games`. Buildat's own
  directory on purpose: no reading of the user's real Luanti installation
  for content, and no chance of writing to it. A game is a directory with a
  `game.conf`.
- Saves come from `builtin/storage`'s `list()`, which for this game means
  `user_path/games/luanti_launcher/saves/`. Each one records which Luanti
  gameid it needs as a key in the save, rather than in a `world.mt`. A save
  whose gameid is not among the scanned games is still listed, with a
  warning appended to its name.
- That makes a better menu than Luanti's: "which save" and "which game it
  needs" were always two facts pretending to be one, and here they are two.
- The scan is server-side -- the server owns the filesystem -- so the list
  goes to the client as a packet and the client draws it with
  `ui_utils.vertical_menu`, the same as the aggregate structures menu.
- Choosing a save calls `run_game()`; a new one is `create()` then
  `run_game()`. The split is deliberate, so a typo in a name cannot silently
  start a new game instead of opening the old one. Nothing is extended; this
  is the proof that plain hosting works.

**Settled (2026-09-12): `run_game()` is callable after init, and that is
fine.** The reason it is fine is worth writing down, because it is the rule
that keeps the two uses apart:

- The launcher chooses its world from a menu, after boot, *because it does
  not extend the game*. Nothing of its own has to be in the Luanti
  environment before the mods load, so there is nothing that has to happen
  first.
- A game that does extend a Luanti game **already knows which one at init**
  -- it is written against it. So its `load_lua()` calls and its C-side hooks
  are registered before `run_game()`, and the ordering problem never arises.

So the interface has one ordering rule rather than a lifecycle: **whatever
extends the environment is registered before the game runs**, and when it
runs is the caller's business. A `load_lua()` after `run_game()` is an error
worth reporting rather than a case to support -- Luanti mods are loaded once,
in order, and a late arrival would be a different kind of thing entirely.

## Milestones

Each one ends with something that can be looked at. What each turned out to
be is in `doc/plan/luanti_module_history.md`; what is left of each is here.

**M0 the testbed, M1 the environment boots, M2 a world exists -- built
2026-09-12.** devtest loads its 35 mods and registers 390 node types, and a
buildat_client sees a floor a mod placed.

**M3 -- it looks like the game. Built 2026-09-13**, except the drawtypes
below. Nodedefs to `VoxelRegistry`, media over `client_file`, drawtypes
through buildat's own mesher, and the client composing the texture modifier
expressions into its own atlas. devtest: 279 of 390 node types wear a plain
shipped tile and the texture modifiers get all but 2 of the rest; 155 have a
shape of their own, 83 of those liquids; 56 turn with their param2.

- **The drawtypes that are left**, and there is not much: the frame of a
  `glasslike_framed` (5 in devtest, drawn as a plain cube, which is what it
  looks like without its frame); the node box kinds that are not `fixed` --
  `connected` is the same `connect_dir` a fence uses, and `wallmounted` and
  `leveled` are a `VoxelVariant` on the param; devtest has none of the three
  to check an implementation against, which is a reason to wait for a game
  that does. See "Which mesher draws the drawtypes".
- **`mesh`** (18 in devtest). Built 2026-09-13 for .obj and .b3d; see "The
  meshes" below.
- **Palettes**: built 2026-09-13. Nineteen of devtest's nodes wear a
  colour out of one; see "The palettes" below.

**M4 -- it plays. Built 2026-09-13.** Digging and placing with every
callback around them, node metadata, inventories, the recipes, the
formspecs, and a chest. A click digs the node it points at and the drops are
the digger's; the other button places what is wielded or runs the pointed
node's `on_rightclick`; a form is drawn from the string the server sends and
what was pressed comes back; a stack is picked up in one slot and put down
in another, with a node's own `allow_`/`on_metadata_inventory_*` around a
move that touches it.

- **What is left: a detached inventory.** `core.create_detached_inventory`
  keeps one server-side already; what is missing is sending it to the client
  and letting `ctx.inventory` and a move reach it, which is the chest's path
  with a different location. A `list[detached:...]` draws empty until then.
- **And what is picked up is what is put down**: Luanti puts a single item
  down with the right button and ten with the middle, which is a count on
  the way down as well as on the way up.

**M5 -- it lives. Built 2026-09-13.** ABMs, LBMs, entities, `core.after`,
node timers, the players, and the objects on screen wearing their own
texture -- a sprite for a dropped item, a cube for a cube.

- **What is left: attachments and bones**, which nothing in the drawing path
  carries yet, and the meshes below.

**M6 -- the launcher. The menu is built 2026-09-13; the map is not.**

With no world chosen the server waits, and a client that connects draws the
list of saves and the games they need and picks one or makes one. A save
records the gameid it needs as a key in its own store, so the list says
which game each save needs without opening any of them -- the two facts
Luanti's menu made one. `BUILDAT_LUANTI_GAME` and `BUILDAT_LUANTI_WORLD`
still run a world at start without a menu, which is what every check here
does.

simplified: the twelve most recent saves, because `ui_utils.vertical_menu`
does not scroll and a list longer than the screen has saves nobody can
reach. What it wants is a scrolling list.

- **What is left: the map.** The world is 3x3x3 sections, which is why the
  importer drops most of a real Luanti world. How it streams is settled --
  see "The map, and how it streams" -- and it is the largest piece of work
  left in this plan. Most of the first half of it is `voxelworld`'s rather
  than this module's.

**M7 -- an existing Luanti world opens. Built 2026-09-13**, except the seed.
`builtin/luanti/mapblock.h` reads a MapBlock at serialization versions 25 to
29, which is every world written since 2013, and `luanti::import_world()`
puts the blocks into the running game's world, the metadata onto its nodes,
the clock into its clock, what the mods remembered into their storage, and
the players into the save. One direction: a Luanti world directory is opened
read-only and nothing is ever written back to it.

- **What is left:** `map_meta.txt`'s seed and the mapgen parameters, which
  have nowhere to go until there is a mapgen; a world whose players are one
  text file each under `players/` rather than a database; and a block's node
  timers and static objects, which are walked past -- the objects want a
  `static_save` that means something here first.

**Not the other direction, and not a live format.** Writing Luanti's format
would mean bit-compatible `MapBlock` writes forever and would force
buildat's own world data into a pocket beside it -- and buildat's voxel word
is extended by *planes*, which a Luanti MapBlock has nowhere to put. An
exporter is the importer pointed backwards and can be written if anyone ever
asks. See `doc/plan/world_persistence_plan.md`.

M1 to M3 is where the module's shape is decided; everything after is surface
area, and surface area is the part that can be added forever.

## devtest's own unittests as the oracle (2026-09-13)

devtest ships a `unittests` mod -- around forty tests of the server API,
written by Luanti's own developers -- and it runs inside this module. A
save whose `world.mt` has `devtest_unittests_autostart = true` runs the lot
at load and prints a PASS/FAIL line each. There is no better check of this
half of the module, and it should be run whenever the API surface changes.

    cd Build && BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=<a save> \
        bin/buildat_server -m ../games/luanti_launcher -D ../user

A client has to be connected for the whole of it to run: the suite waits for
a player before its last eighteen tests, and the launcher makes one when a
client arrives. Start the server, connect `bin/buildat -s localhost` and
leave it there. It is 44 of 50 with one, and 32 of 40 without.

What it found, and what was built because of it: `core.sha1`, `core.sha256`,
`core.compress`/`core.decompress` with Luanti's three methods,
`core.urlencode`, `core.parse_json`/`core.write_json`, `Settings(filename)`,
a `core.get_game_info()` that reads the game's title, an exactly-Luanti
`PseudoRandom`, the metadata `${reference}` rule, alias resolution in
`ItemStack`, metadata-aware stack merging, `Inventory:remove_item`'s
reverse-and-oversize rule, and the recipe tables `get_all_craft_recipes`
answers with, an async job that can be cancelled before it calls back --
which is what had stopped the suite from ever reaching its player half,
since a job calling back twice resumed the runner's coroutine out of turn --
and the players themselves.

**What does not pass, and why it is not a bug to fix:**

- `lint_json_files` lints the `.json` files Luanti ships in `builtin/`. This
  module vendors the parts of `builtin/` it runs and not the main menu, so
  there are none to lint.
- `test_gennotify_api` is the mapgen's, and there is no mapgen.
- `test_str_pack_unpack` wants `string.pack`, which is Lua 5.3's. The Lua
  here is Urho3D's 5.1.
- `test_mapgen_env`, `test_handle_async`,
  `test_portable_metatable_registration` and `test_async_job_replacement`
  are all one thing: Luanti runs mapgen scripts and async jobs in Lua states
  of their own, and there is one state here. A job runs where it was asked
  for, an async environment is a globals table rather than a state, and
  there is no queue for a job to wait in or be cancelled from. The upgrade
  path is a second Lua state; the seam is `core.do_async_callback`,
  `core.register_async_dofile` and `core.register_mapgen_script`.

- `test_async_job_replacement` passes now that a job can be cancelled, but
  what it is really about -- a queue deep enough for a job to wait in -- is
  the same second Lua state.

The suite stops at `test_mapgen_edges`, which asks how far the map goes and
is the mapgen's question. What is past it is the rest of the map tests.

## Settled, and why -- not to be re-decided

Worked out in full before M2 became code, and they govern what comes after it
as much as they governed M2. Each one says what was decided and why, because
the why is the part that stops it being reopened by whoever reads the code in
six months.

- **The voxel word.** `interface::VoxelFormat::luanti()` exists in
  `src/interface/voxel.h:529`: a 16-bit id, param1's two light nibbles at
  bits 16 and 20, param2 at 24. Luanti's cut fits buildat's word exactly, so
  there is no packing decision to make and `core.get_node` returns the three
  numbers a mod expects by reading three fields of one word.

- **Skylight is the engine's.** `voxelworld` propagates it into
  `light_sky` and the format binds it, so `core.get_node_light` is a read
  and not a second store. `set_skylight_enabled()` is the switch.

- **Media, definitions, the world and the rest of the wire** are buildat
  packets; no Luanti protocol. Decided above and not reopened.

- **The ids are the same number (answered 2026-09-12).** The premise that
  Luanti's content ids are a numbering to be matched was wrong: they are
  allocated by the engine, and here the module *is* the engine.
  `core.get_content_id()`, `core.get_name_from_content_id()` and the three
  `CONTENT_*` constants are whatever the module says, and devtest's own
  `content_ids.lua` only ever asserts relations between them, never a
  literal. So the `VoxelRegistry` id **is** the Luanti content id and there
  is no second table:

  | | | why |
  | --- | --- | --- |
  | `CONTENT_IGNORE` | 0 | `VOXELTYPEID_UNDEFINED` is already 0, "nothing has generated this yet" |
  | `CONTENT_UNKNOWN` | 1 | the first `add_voxel()`, before any mod runs |
  | `CONTENT_AIR` | 2 | the second |
  | the rest | 3, 4, 5... | registration order |

  `add_voxel()` assigns `id = m_defs.size()` and the constructor reserves
  slot 0 (`src/impl/voxel.cpp:71`), so dense sequential allocation from 1 is
  what the registry already does, and 16 bits covers `content_t`'s range.

  The number and the appearance are allocated at different times: the module
  hands out an id when a name is first registered or first asked for --
  devtest calls `get_content_id` *during* mod load -- and builds
  `VoxelDefinition`s in one pass in id order after loading finishes. That is
  forced anyway, since `add_voxel()` takes a finished definition and refuses
  a duplicate name, and it makes `core.override_item` and
  `core.unregister_item` non-issues: only the final `core.registered_nodes`
  is ever turned into a definition.

  There is still a name-to-id lookup on the `set_node` path, but there
  always was -- `core.set_node(pos, {name = "default:stone"})` takes a name.
  What there is not is a second Luanti-id to buildat-id translation.

- **Saves, and id stability across them (answered 2026-09-12).**
  `voxelworld` persists nothing today, so this was not a live problem; it
  becomes one the moment it does. `doc/plan/world_persistence_plan.md` settles
  it for every game rather than for this module: a save carries the
  serialized `VoxelRegistry`. **Corrected 2026-09-12, and it is now Luanti's
  own design:** the running game owns the numbering and the save stores
  names, with a name table per save and the ids remapped on the way in and
  out -- so the module's Lua content ids and the `VoxelRegistry` cannot
  drift apart, which a save that dictated the numbering would have made them
  do silently. Any *format* change, as against a renumbering, is a migration
  the game owns; the engine moves data and never reinterprets it. Written out
  under "What a save says about its voxels" in
  `doc/plan/world_persistence_plan.md`. Still no Luanti-specific name-to-id
  file: it is every game's now.

  That plan also renames the world directory out of existence: a **save** is
  what the user picks, a **world** is a `voxelworld` instance inside it, and
  a Luanti world is one of each. `core.get_worldpath()` points inside the
  save directory, and `builtin/storage` is where node metadata, inventories,
  players and mod storage live.

- **Chunk size: nothing changes, and Luanti's chunksize becomes 4 (answered
  2026-09-12).** The number that matters is not the chunk but the
  **section**: `generate_section()` emits one `GenerationRequest` per section
  and it carries `section_p`, so the generation unit is 2x2x2 chunks of
  32^3 -- **64^3 voxels**.

  64 is four MapBlocks per edge, and Luanti's mapgen chunk is
  `chunksize * 16`. The default 5 gives 80^3, which straddles sections at
  2.5 each; **4 gives 64^3, exactly one buildat section**, 1:1, with the
  vendored mapgen keeping its 16-aligned internals untouched. `chunksize` is
  a mapgen param the module owns and reports through
  `core.get_mapgen_chunksize()`, so it is a constant we pick rather than a
  conversion we write. And since 32 is a multiple of 16, every 16-aligned
  Luanti concept -- a MapBlock, an LBM's unit, a VoxelManip's emin/emax,
  `core.get_mapgen_edges()` -- lands on whole buildat chunks anyway: eight
  MapBlocks per chunk, 64 per section.

  Not 16^3 for `voxelworld`: eight times the chunks, scene nodes, geometry
  batches and replication units, to match a number Luanti picked for 2010
  hardware, against a mesher and a replication path tuned for 32. And not
  per-instance configurable, which is an engine change bought for nothing.

  The worry this question was written around -- that M2 writes a translation
  M3 deletes -- does not apply: the seam is a **clipped region copy**, which
  `bulk_set_node` and VoxelManip need whatever the numbers do. Alignment
  makes it cheap, not unnecessary.

  What it costs: terrain generated at chunksize 4 differs from the same seed
  at Luanti's default 5, because ores and decorations are placed per mapgen
  chunk. Nothing here reproduces a particular world bit for bit -- that is
  what M7's importer is for -- but it is worth having written down rather
  than discovered.

- **The thread, and what drives it (answered 2026-09-12).** buildat runs
  **one thread per module** (`ModuleThread`, `src/server/state.cpp:44`),
  delivers events to a module's own queue, and runs `access_module(name, cb)`
  **in the caller's thread** holding the target's lock, under a validated
  lock hierarchy (`check_valid_access_u`). So there is no choice to make
  about where the Lua lives: one `lua_State`, owned by `builtin/luanti`,
  touched only from that module's thread. What follows from it is the part
  worth writing down.

  **`run_game()` and `load_lua()` queue rather than execute.** Since
  `access_module()` runs in the caller's thread, a `run_game()` that loaded
  mods inline would run devtest's 35-mod load on the launcher's thread while
  holding this module's lock. Both calls record the request and return; the
  module's own thread does the work on its next tick and reports back with
  `luanti:game_loaded` / `luanti:game_load_failed`, which the launcher wants
  anyway for a progress line and an error message. This strengthens the
  ordering rule above rather than changing it: "registered before the game
  runs" is now just queue order.

  **Calls go luanti to voxelworld and never back.** The lock hierarchy
  forbids the return direction and voxelworld does not need it -- it emits
  `voxelworld:generation_request` as an event, which lands on this module's
  own thread. That decides the shape of the mapgen seam: an event handler,
  not a callback, and no lock inversion is possible.

  **The tick rate is not buildat's.** `core:tick` is emitted at 30 Hz
  (`src/server/main.cpp:164`); Luanti's server steps at
  `dedicated_server_step`, default 0.09 s, which is what mods' `globalstep`
  dtime and `core.after` resolution are written against. Accumulate buildat's
  ticks and step the environment at Luanti's own rate.

  **Known cost, with a known fix.** Long work on that thread blocks it, and a
  Lua mapgen (`core.register_on_generated`) must run there because the state
  is single-threaded -- `set_node` and ticks queue behind it.
  `access_thread_pool()` helps the vendored C++ mapgen and not the Lua one.
  Luanti's answer is emerge threads plus a separate mapgen Lua state, and
  **`core.register_mapgen_script` is going in when it is needed**; it is
  scheduled, not an open question. Nothing to compute at M2, which is
  singlenode.

- **`set_node` is buffered and flushed once per step (answered
  2026-09-12).** The per-voxel write is already cheap: `set_voxel()`
  (`voxelworld.cpp:1051`) writes into a `ChunkBuffer` volume and pushes a
  skylight seed only when the voxel's transparency changed. The cost is
  `commit()` (`:1779`), which runs `update_skylight()` and then
  re-serializes and republishes the dirty chunks -- and the inline
  `voxelworld::access()` helper in `api.h` **calls `commit()` on every
  exit**. So one `access()` per `core.set_node` would pay a skylight pass
  and a 32^3 chunk serialize-and-replicate per node placed, which is what a
  mod placing nodes in a loop would do all day.

  So the module keeps a **write-behind buffer** and flushes it once per
  Luanti step inside a single `access()`. `set_node`, `add_node`,
  `swap_node`, `remove_node`, `bulk_set_node`, `place_node` and `dig_node`
  all append to it; `core.get_node` reads through it first, because Luanti's
  semantics are that a write is visible immediately and the `on_placenode`
  callbacks in the same step will look. One commit then covers every chunk
  the step touched, and `update_skylight()` (`:1522`) swaps a seed list and
  returns at once when it is empty, so an idle commit is free.

  That answers the question as it was asked: **M2 does not need a region
  write.** The buffer is what makes one-write-per-node fine, and it is about
  thirty lines. `merge_volume()` is not the region API for this -- its
  priority rules deliberately refuse to overwrite anything already there,
  because it is built for generators filling fresh sections. So
  **`voxelworld` has no "write this region over whatever is there" call at
  all**, which `bulk_set_node` and `vm:write_to_map()` will both eventually
  want.

  **Corrected 2026-09-12: that is not a capability gap.** A loop of
  `set_voxel()` inside one `access()` *is* "write this region over whatever
  is there" -- the priority rules are `merge_volume()`'s, not the engine's --
  and the same goes for reading. What a region call would add is a constant
  factor: one clip per chunk instead of a `container_coord`, a section lookup
  and a buffer lookup per voxel, and one pass of skylight-seed decisions
  instead of one per voxel. So it is a performance question, and it is
  deferred until the mapgen seam can measure it; see "The region calls" under
  Mapgen.

  Two details: `set_voxel()` rather than `set_sample()`, since
  `VoxelFormat::luanti()` is one plane and `set_voxel` writes plane 0. And
  `vm:write_to_map()` flushes the buffer before writing its region in the
  same access, so the two paths cannot reorder against each other.

- **The clock: three numbers, server-side at M2 (answered 2026-09-12).**
  `time_of_day` (0...23999 inside, 0...1 in Lua), `game_time` in seconds
  since the save was made, and `day_count`, plus the `time_speed` setting
  whose default 72 makes a 20-minute day. Stepped with the environment at
  Luanti's own rate, persisted in the save's store, restored on load. Four
  functions over three numbers.

  It blocks nothing: devtest calls `get_timeofday()` in exactly one place
  (`mods/testtools/light.lua:18`, inside a tool's `on_use`) and the vendored
  `builtin/game/chat.lua` uses it only in `/time` and `/days`. Nothing
  touches it during mod load, which is why M1 loads with all four stubbed.
  It goes into M2 because it is nearly free and mods reach for it as soon as
  anything runs.

  **Time of day must not touch voxel data.** `voxelworld`'s skylight is a
  per-voxel 0...15 saying how much sky reaches a voxel and does not vary
  with the hour; Luanti is the same, and it is the *client* that multiplies
  stored skylight by the daylight ratio. So the clock is a scalar the server
  keeps and the client applies, and nothing re-lights, re-serializes or
  re-meshes when the sun moves. Wiring `set_timeofday` to a relight is the
  expensive mistake available here, and it would look correct on a small
  test world.

  **The wire shape is decided now and sent at M3**, since M2's client has a
  static light and no sky to send it to: **`time_of_day` and `time_speed`,
  with the client extrapolating**, which is what `TOCLIENT_TIME_OF_DAY`
  carries and what `extensions/luanti_client` already implements --
  `client.lua` advances `time_of_day_f` by
  `time_speed * 24000 / (24*3600) * dtime`. The fork inherits it, and the
  server sends a packet only when the clock is *set*, not every tick.

- **The build step is not the milestone it looked like (answered
  2026-09-12).** The question mixed two thresholds.

  *When the module needs more C++* is sooner than mapgen, and neither case
  is mapgen: **VoxelManip** at the Lua-mapgen stage, because a 64^3 region
  is 262144 entries and a Lua table of that per chunk is not viable -- it
  wants a C++ buffer with a thin Lua face, which is the pattern
  `pack_voxel_volume` already uses -- and **ABMs** at M5, which scan loaded
  blocks for matching content ids on a timer. Both are "touch a big array
  per element", the one thing Lua is bad at here, and both go into the
  module's own C++ without changing anything about how it is built.

  *When it needs a build-time library* is later than it looked, because
  **runtime compiles are cached**: `build_module_u()`
  (`src/server/state.cpp:655`) hashes the .cpp, its includes and the
  optimisation flags and skips the compile when the hash matches. So a large
  module compiles once per source change, not once per server start. What
  would force a CMake step is one translation unit getting too big --
  `src/mapgen/`'s 9.5k lines plus the data classes at `-O2`, re-triggered by
  any edit -- and even that is a preference rather than a wall. **A single
  runtime-compiled `vendored_luanti.cpp` is an acceptable answer if it works
  when we get there**; all that matters is that the vendored code gets
  compiled somehow and that the licence boundary holds. `meta.json` already
  carries `cxxflags`/`ldflags` (`src/interface/module_info.h:17`), so
  whichever way it goes needs no new mechanism.

  **The Lua noise is fine until then, and is then deleted rather than
  kept.** It cannot match Luanti bit for bit, and does not have to: the
  chunksize decision above already gave up bit-identical terrain. What
  matters is determinism within a save, which Lua gives, and agreement
  between what a mod samples through `core.get_perlin` and what the mapgen
  used, which Luanti gets by them being the same code. So when vendored
  `noise.cpp` arrives the Lua implementation is **replaced by bindings to
  it**, never run beside it. They land together, so there is no window where
  both exist and disagree -- and `lua/classes.lua` says so at the top,
  because "two noise implementations that nearly agree" is a bug that costs
  a week.

  **The licence boundary does not move.** Whatever compiles it, the vendored
  code ends up only in `builtin/luanti.so`, which is dlopened;
  `buildat_server` links nothing of Luanti's. It stays under
  `builtin/luanti/vendor/` so the boundary is visible in the file listing.

## How the module is put together

What M2 settled about the shape, and what is still true of it:

- **The module owns the scene and the `voxelworld` instance.** It is what
  knows the world's node ids and its light, so it is what owns them, and it
  announces the scene with `luanti:game_loaded` -- which is how whoever
  started the game finds out where to put its peers. The launcher creating
  the scene and handing it in puts the registry's ordering rule in the wrong
  place: the ids are allocated while the mods load and the definitions are
  built straight after, both inside the module.
- **`run_game()` and `load_lua()` queue rather than execute**, and every
  `voxelworld` call goes out from this module's own thread, never back into
  it.
- **A write emerges the section it lands in**, the way Luanti's `set_node`
  emerges the block it writes into. Without it the first flush raced
  `voxelworld`'s own first tick and silently wrote nothing.
- **The vendored `constants.lua` is modified**, not wrapped: it hardcodes
  125/126/127 for the three content ids and would overwrite the ones the
  module allocates. First use of the fork rule, and the file says so where
  the numbers were.

## Simplified, and the upgrade path

Every shortcut this module has taken that is still a shortcut, with what it
costs and what it would take to lift. Each is written at the code as well;
this is the list, so that nobody has to grep for `simplified:` to find out
what the module does not do.

- **A cube object wears one texture, not six**, and a `mesh` object is a
  cube wearing its first. Lifting it is the meshes; see the open question.
- **A node's inventory image is one of its tiles**, not the little cube
  Luanti draws. The upgrade path is shearing three tiles into one image,
  which `extensions/luanti_client` does and `compose_image` has the `shear`
  op for.
- **What is picked up is what is put down.** Luanti puts a single item down
  with the right button and ten with the middle; that is a count on the way
  down as well as on the way up, in the same packet.
- **A detached inventory draws empty.** See M4.
- **A tool use costs 65535/uses of it**, not the arithmetic that makes one
  break after exactly `uses` digs whatever wear it started at.
- **The texture is not turned inside a shape's quad.** `tile_turns` does
  that for a cube's faces and the mesher does not apply it to a shape, so a
  turned node box wears its textures straight.
- **A section's metadata is taken out of one table over the whole world**,
  once per unload, rather than kept in an index per section. A world with
  more than a few thousand nodes carrying something wants the index; the
  place to keep one is beside the table in `lua/bootstrap.lua`.
- **An object outside the active range stays in the world and stops
  moving.** Luanti takes it out of the world entirely and writes it into the
  block it was in, so a world with a thousand wandering mobs in it costs
  nothing while nobody is there. Here it costs an object that is stepped
  over and skipped. The upgrade path is Luanti's static objects, which want
  the same per-section write the metadata does.
- **A VoxelManip does not emerge.** Luanti reads whole mapblocks around the
  box asked for and hands back the corners it really read; here the box is
  the box. A mod that uses the corners it is given -- which is the
  documented way and what every mod does -- does not notice; what it costs
  is that a write cannot straddle what was never read.
- **A Lua mapgen runs on the server's own thread**, so a slow one is a slow
  server: about 600 ms a section over devtest. The module turns
  `voxelworld`'s stream budget down to one section a pass while its mapgen
  is slow, which spreads it but does not remove it. Luanti generates on an
  emerge thread; the upgrade path is stage 3's, where the generator is C++
  and does not hold the one Lua state.
- **The noise has no lacunarity and no flags**, because buildat's vendored
  copy of Luanti's noise doubles the frequency per octave and has no eased
  or absvalue switch. A mod that sets either gets the default.
- **The importer loads every section it writes into** and lets the streamer
  unload them afterwards, so a large world peaks at the whole import in
  memory. It was the whole world before the map streamed, and the upgrade
  path is to unload a section once nothing more will be written into it --
  which the block order in the database already gives.
- **The players and the clock are written when they change and at
  shutdown**, not on a timer, so a server that is killed loses what changed
  since. Luanti writes its own every 5.3 seconds with the map.
- **The auth database asks nobody for a password**, because a buildat server
  decided who a peer is one layer down.
- **One Lua state**, so `core.request_insecure_environment` and the async
  environment are what they are; two of devtest's six failing unittests are
  this.
- **The menu lists the twelve most recent saves**, because
  `ui_utils.vertical_menu` does not scroll.
- **The importer reads `players.sqlite` only**, not a world whose players
  are one text file each under `players/`.

## What the drawtypes that are left turned out to be

### The palettes: built 2026-09-13

`VoxelVariant` grows textures of its own and a palette entry is one; what
each turned out to be is in `doc/plan/luanti_module_history.md`, "The
palettes, and what a variant wears".

### The meshes: built 2026-09-13

`drawtype = "mesh"` is read while the registry is built and becomes the
node's shape, so the quads travel in the definition like a nodebox's. The
readers are `objmesh.lua` and `b3dmesh.lua`, copied out of
`extensions/luanti_client` where they were written against this same mesher;
`doc/plan/luanti_module_history.md`, "The meshes, where they are read", has
what that turned out to be.

**What is left of it.** A node naming a `.x`, a `.gltf` or a `.glb` keeps
the cube it had -- ten of devtest's thirty mesh references, mostly its
dedicated glTF test mod -- because glTF is a third reader nobody has
written. And an object with `visual = "mesh"` is still a cube wearing its
first texture: an object is drawn by the client half rather than by the
voxel mesher, so it wants the readers on that side as well, which is where
the extension has them.

## Risks

- **The C API surface is discovered, not designed.** The estimate for
  "implement what devtest calls" is only as good as devtest's coverage, and
  the next game will call something else. Accepted: the alternative is
  specifying Luanti's API up front, which nobody has ever finished.
- **The vendor tree is a maintenance surface.** Pulling a newer Luanti means
  re-applying whatever was modified. Keep the modifications few and marked,
  and record the upstream commit the tree came from.
- **Entities are not over `replicate` any more**: where an object is and
  what it looks like are packets of the module's own, because a material is
  a resource file and a Luanti object's texture is not. What is still
  untried is attachments and bones, which nothing in the drawing path
  carries.
- **Performance.** Luanti's server is C++ doing per-block work; here the same
  work crosses a Lua boundary that Luanti's own C++ does not. devtest's
  `benchmarks` mod exists and should be run early rather than late.
- **Luanti's `builtin/` Lua is theirs and the C API under it is ours**, so a
  version bump can break the load in ways that are tedious to diagnose.
  Vendoring the builtin Lua at the same pinned commit as the rest of the
  vendor tree is what keeps the two halves honest.
- **The runtime-compiled module now depends on a build-time library**, which
  is a new shape for a builtin module and will surprise whoever edits one
  next. A README line, and a clear error when the library is missing.
