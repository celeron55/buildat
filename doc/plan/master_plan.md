# Master plan

What order the work goes in, and which document holds the detail. This file
exists to prioritise the others; it is deliberately short. When a step's own
document disagrees with this one about *order*, this one wins.

What is finished is in `doc/plan/master_plan_history.md`, and each plan has a
history of its own. What is in this file is open.

The documents:

- `doc/plan/luanti_voxels_plan.md` -- the Luanti client's open work.
- `doc/plan/luanti_voxels_history.md` -- the Luanti client's finished work, kept
  for the reasoning rather than the diff.
- `doc/plan/buildat_voxel_data_model.md` -- the engine's voxel data model:
  planes, roles, a field registry a module can extend without asking.
- `doc/plan/voxel_data_model_plan.md` -- how that design gets built: the
  interfaces, the six steps of stage 1, planes in stage 2, the migrations.
- `doc/plan/undermine_plan.md` -- a sample game where digging brings the roof
  down, and the consumer the data model does not otherwise have.
- `doc/plan/aggregate.md` -- the next game: voxels as mixtures, with no
  material ids at all. The first thing here that would need planes, and the
  choices a mesher without a voxel id has to settle.
- `doc/plan/aggregate_plan.md` -- how the engine under it got built: five
  steps, of which one to four are done.
- `doc/plan/aggregate_game_plan.md` -- how the game gets built: parity with
  undermine first, then compaction and water, then the wood cycle.
- `doc/plan/luanti_module_plan.md` -- `builtin/luanti`: running an unmodified
  Luanti game inside buildat_server, and `games/luanti_launcher`.
- `doc/plan/client_preferences_plan.md` -- what the user sets once and every
  game honours: undersampling, vsync, the frame limiter, MSAA, and the sound
  volume and mute. Includes how a preference reaches a viewport a game made
  itself.
- `doc/plan/world_persistence_plan.md` -- saves, the user and cache paths,
  and the sqlite object store modules keep their data in. Steps 1 to 5 are
  built but for 5b.
- Section 14 of this file -- what `builtin/client_file` needed before it
  could carry a Luanti game's media set. Finished.
- `doc/plan/master_plan_history.md` -- the steps this file has finished,
  kept for the reasoning rather than the diff.

Each plan whose work is largely done has a history file beside it, holding
what was built and why it came out the way it did:
`luanti_module_history.md`, `luanti_voxels_history.md`,
`voxel_data_model_history.md`, `aggregate_history.md`,
`aggregate_game_history.md`, `undermine_history.md`,
`world_persistence_history.md`. Nothing in any of them is a to-do.

## What is next (2026-09-13, fourth round)

**The focus is `builtin/luanti` until further notice.** Everything else
unfinished is frozen -- `undermine`, `aggregate` and
`extensions/luanti_client`; see "Frozen" below.

The second round is done. `build-check` merged (PR #54), and the other three
are a stack waiting to merge bottom-up: `client-preferences` (PR #55) into
master, `saves` (PR #56) into that, `luanti-module` (PR #52) into that.

**Where the module is.** Everything a Luanti game does on the server is
built: the environment and the map (M2), digging and placing with the
callbacks around them, node metadata, inventories and the recipes (M4), the
globalsteps, `core.after`, ABMs, LBMs, the objects, the players and the node
timers (M5), and reading an existing Luanti world -- its map, what hangs off
its nodes, its clock, what its mods remembered and its players (M7).

**And the client half is built** (2026-09-13): a game's textures, its
formspecs and inventories, a chest, the objects wearing what they look like,
and a menu to pick a save from. What is left of the module is two drawtypes
and a handful of named shortcuts.
`doc/plan/luanti_module_history.md` has what each turned out to be.

**And it is checked against Luanti's own tests.** devtest ships a
`unittests` mod of about fifty tests of the server API, and it runs inside
the module: forty-four pass with a client connected, and the six that do not
are each a simplification the plan names rather than a bug. See "devtest's own
unittests as the oracle" in the module plan for how to run it -- it is the
first thing to run after touching the API surface.

**The palettes are built (2026-09-13).** A `VoxelVariant` can wear textures
of its own, and a palette entry is the node's tiles through a modifier that
multiplies them -- so the client composes them through the machinery the
texture modifiers already built. Nineteen of devtest's nodes wear one:
4424 variants over them, 1383 textures composed in 440 ms. See "The
palettes, and what a variant wears" in the module's history.

**M6's map is built (2026-09-13), and most of it was engine work.**
`voxelworld` streams sections around load points -- a position and its own
load and generate radii -- and `games/infidigger` and `games/bomber_drone`
deleted their copy-pasted streamers, which was the check that the interface
was the right one. A peer is sent only the chunks near its own point, as far
out as its client asked for. The module puts a load point under every player
and runs its ABMs, its node timers and its objects in Luanti's own
active_block_range, which is one section; its world is the map's limits
rather than 192 voxels a side. What is left of it is node metadata per
section -- one blob for the world still works, and what it costs is memory
that grows with where the players have been. See "The map, as it was built"
in the module plan.

**The mapgen's seam is built (2026-09-13).** A section that has been filled
runs `core.register_on_generated` over the box it filled, and a mod writes
terrain into it through a VoxelManip that really reads and writes the map --
three flat arrays in the order `VoxelArea` indexes. The noise a mapgen
shapes a world with is bound to buildat's vendored copy of Luanti's, so a
mod's `NoiseParams` means here what it means there, and `map_meta.txt`'s
seed finally has somewhere to go: the save, beside the clock. See "The
mapgen seam" in the module's history.

**The meshes are built for .obj and .b3d (2026-09-13).** A mesh node is read
while the registry is built and becomes the node's shape, so the quads
travel in the definition like a nodebox's -- nineteen more of devtest's
nodes have a shape of their own. What is left is glTF, which is a reader
nobody has written, and an object with `visual = "mesh"`, which is drawn by
the client half rather than by the voxel mesher.

What is left, in order of what it is worth:

1. **The mapgen, stage 3: vendor `src/mapgen/` and point it at the seam.**
   Stage 2 is built (2026-09-13) and a Lua mapgen makes terrain through it,
   so what is left is the 9.5k lines of noise, biomes, ores, decorations,
   schematics and the tree generator that a mainstream Luanti game's world
   actually is -- a world that is *nearly* v7 is a world that is nothing,
   which is why it is vendored rather than rewritten. See "Mapgen" in the
   module plan.

   Two things stage 2 measured are arguments for doing it in C++: a Lua
   mapgen over a section costs about 600 ms, most of it a quarter of a
   million voxels crossing the Lua boundary twice, and all of it runs on the
   server's own thread. Luanti has an emerge thread; this module has one Lua
   state and nowhere to put one. A vendored mapgen writes the volume with no
   Lua in the middle.
2. **Node metadata per section**, which is what M6's map left behind. One
   blob for the world still works and loses nothing, but it grows with
   everywhere the players have been and it is one large write at shutdown.
   It wants a section-loaded notification from `voxelworld`, which does not
   have one. See "The map, as it was built" in the module plan and step 5c
   of `doc/plan/world_persistence_plan.md`.
3. **The rest is minor and belongs to a later round.** glTF, an object drawn
   as its own model, a detached inventory, a put-down count, the inventory
   cube, a scrolling save list: each is an afternoon, none blocks a game
   from running, and they are in "Bonuses" below for exactly that reason.
   The module plan's "Simplified, and the upgrade path" is the full list of
   what the module does not do.

**And the branch stack should merge before more lands on it.**
`client-preferences` (PR #55) into master, `saves` (PR #56) into that,
`luanti-module` (PR #52) into that -- four rounds of work that every further
change widens. Whose call that is is the reader's, not this file's.

What is *not* left: the client half, which was item 1 of this list for three
rounds. The texture modifiers, the formspecs, the inventories, the chest,
the objects wearing their own textures and the launcher's menu are all built
as of 2026-09-13; `doc/plan/luanti_module_history.md` has what each turned
out to be. The one thing the fork's plan expected that did not happen is
that `init.lua` was never split -- the wiring was written fresh against the
packets and the camera and input stayed the launcher's, which is where they
belong.

Done since the third round, all in `doc/plan/master_plan_history.md` or in
the module's own history: M4's inventories and recipes, all of M5, M7's
importer, the whole client half, M6's menu, the players in the save, the
preferences screen, the media set -- a game's models, sounds and
translations went nowhere until 2026-09-13, because only `textures/` was
collected -- and M6's map, which streams.

The loose end that was here is closed: `voxelworld` has `get_volume()` and
`set_volume()`, built once there were three callers to measure them against.
See "The region calls" in the module plan for what they turned out to be
worth.

## Maintenance -- do this daily

**Go through the plans and move what is finished out of them.** A session
adds to a plan every time it settles something, and none of it removes
anything, so a plan drifts from "what to do" towards "what happened" without
anyone deciding that it should. This file was 1034 lines of which thirteen
sections were finished work before the first pass; it is 196 now.

Daily because it is minutes at that cadence and a day's work once it has been
skipped for a month -- and because a plan nobody trusts to be current stops
being read, which costs far more than the tidying.

**Commit before starting.** The pass deletes things, and the judgement calls
in it are made quickly. Git holding the previous state is what makes that
safe.

**What stays in a plan:** clear principles, rules, implementation steps,
tests, benchmarks, goals, what is deliberately *not* being implemented,
prioritisations, open questions, gotchas and findings -- as long as each one
bears on something upcoming, in progress or open. A decision written down so
that it is not re-argued stays even when the work it governed is done, which
is why `builtin/luanti`'s settled list is still in its plan.

**What moves to `<name>_history.md` beside it:** long series of DONE and
BUILT items, the blow-by-blow of how something was built, and anything whose
only remaining value is the reasoning behind a finished decision. Nothing in
a history file is a to-do, and each one says so at the top. Leave a stub
where a section was, naming what it was and where it went.

**Two failure modes worth looking for while in there**, because both have
happened:

- **A status that contradicts its own sub-plan.** This file said the Luanti
  PBR round was "Not started" while `luanti_voxels_plan.md` section 7c said
  BUILT, with a full account of what it turned out to be. The ordering
  document is the one that goes stale, because it is written from memory;
  the sub-plan is written from the work. When they disagree, the sub-plan is
  right about *status* and this file is right about *order*.
- **A reference broken by a move.** "See the section below", a section
  number, a plan path. Grep for them after moving anything.

## Frozen

Kept compiling and working as the engine changes, and nothing more. Each one
has its own plan, which says the same at the top and holds what it never
spent.

- **`games/undermine`** (`doc/plan/undermine_plan.md`). Gave what it was built
  to give: a consumer that exercised the voxel format, and the measurements
  behind the data model. The player physics fault is the engine's and is
  fixed if a working fix turns up.
- **`games/aggregate`** (`doc/plan/aggregate_game_plan.md`). Phases 1 to 5
  built and playable.
- **`extensions/luanti_client`** (`doc/plan/luanti_voxels_plan.md`). Parked,
  not abandoned, and now also a parts bin: the module's client half took
  `texmod.lua`, `formspec.lua`, `formspec_ui.lua` and `hud.lua` from it
  verbatim, and `b3dmesh.lua` and `objmesh.lua` are what the meshes question
  is about. Edits to a copied file belong in both, which each copy's header
  says. What it still holds that nothing else has is the HUD, chat,
  particles and sounds.

## Still open from finished work

One thing a finished section left behind, not big enough for a section of its
own:

- **The client's chunk physics fix has not been played.** All three parts are
  built and the walking-digging-pouring harness does not fall through in
  aggregate or in digger, but the fault was always intermittent and a harness
  is not proof. Section 4b of the history has the diagnosis.

## 14. client_file, for a Luanti-sized media set -- DONE

All five items are built; see `doc/plan/master_plan_history.md`.

## Bonuses, for when everything else is stalled or done

Not a queue, and deliberately after the mapgen (2026-09-13): none of them
stops a game from running, and each is understood well enough to start on
any afternoon. That is what makes them the right thing to pick up when the
current branch is blocked on an answer, or when a round has just landed and
the next has not started -- and the wrong thing to spend a round on while
every world the module makes is still empty.

- **A detached inventory reaches the client** (`builtin/luanti`). It is
  kept server-side already; what is missing is the packet and letting
  `ctx.inventory` and a move reach it, which is the chest's path with a
  different location. A `list[detached:...]` draws empty until then.
- **Put a single item down** (`builtin/luanti`). Luanti puts one item down
  with the right button and ten with the middle; what is picked up is what
  is put down here. A count on the way down as well as up, in the packet
  that already exists.
- **A scrolling save list** (`games/luanti_launcher`). The menu shows the
  twelve most recent saves because `ui_utils.vertical_menu` does not scroll.
  Whatever is built for it belongs in `ui_utils`, since it is the same
  widget every menu in this tree uses.
- **glTF, the mesh format nobody has a reader for** (`builtin/luanti`). Ten
  of devtest's thirty mesh references are `.x`, `.gltf` or `.glb`, mostly
  its dedicated glTF test mod, and a node naming one keeps its cube. The
  other two formats are read in `builtin/luanti/lua/`; a third reader goes
  beside them.
- **An object drawn as its own model** (`builtin/luanti`). A `visual =
  "mesh"` object is a cube wearing its first texture. The readers are in
  the module now, but an object is drawn by the client half rather than by
  the voxel mesher, so this is the same two files on that side -- which is
  where `extensions/luanti_client` already has them.
- **An inventory image that is a cube** (`builtin/luanti`). An item that
  places a node is drawn as one of its tiles; Luanti draws the little cube.
  `compose_image` has the `shear` op and `extensions/luanti_client` has the
  three-tile version to copy.

The client preferences screen that was here is built; see
`doc/plan/master_plan_history.md`.

## Think about later

Not to-do items. Each needs a discussion before it is even a plan.

- **Build flags for the server's runtime C++ modules.** `buildat_server`
  compiles game modules at runtime with its own command line, which does not
  follow the flags the server itself was built with -- so a Debug server can
  end up loading optimised, assert-free modules, and a module's stack frames
  need not match the server's idea of them. Worth looking into whether the
  build type, `-g`, `-D` set and sanitizers should be propagated from the
  server's own build into the module compile command.
- **Several voxel worlds on one server, each on its own thread.** Arenas, or
  an overworld with dungeons. Mostly a lifecycle and threading question
  rather than a data-model one; the one constraint it puts on step 1 is
  recorded in `doc/plan/buildat_voxel_data_model.md` ("Adjacent: more than one
  world"), and the rest wants its own note.
