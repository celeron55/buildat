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
and a menu to pick a save from. What is left of the module is a map bigger
than 192 voxels a side, two drawtypes, and a handful of named shortcuts.
`doc/plan/luanti_module_history.md` has what each turned out to be.

**And it is checked against Luanti's own tests.** devtest ships a
`unittests` mod of about fifty tests of the server API, and it runs inside
the module: forty-four pass with a client connected, and the six that do not
are each a simplification the plan names rather than a bug. See "devtest's own
unittests as the oracle" in the module plan for how to run it -- it is the
first thing to run after touching the API surface.

In order:

1. **M6's map, and it starts in `voxelworld`.** The world is 3x3x3 sections
   -- about 192 voxels a side -- so the importer drops most of a real Luanti
   world, devtest's unittest suite stops at `test_mapgen_edges`, and
   `map_meta.txt`'s seed has nowhere to go. **How it streams is settled
   (2026-09-13)**; see "The map, and how it streams" in the module plan for
   the design and the order of work.

   The first half is engine work with three callers, not Luanti work:
   `voxelworld::Instance` grows load points -- a position and its own load
   and generate radii, so that a player can have a big range and a machine
   only enough to work, and so that two players can differ from each other
   -- plus `get_loaded_sections()` and a per-peer send range, which is a
   hole today rather than a refinement: every chunk goes to every peer.
   `games/infidigger` and `games/bomber_drone` already stream server-side
   with identical copy-pasted code and **delete their copies** when it
   lands, which is the check that the interface is right.

   The second half is the module's: a load point per player, an active range
   bounding the ABM and LBM sweeps, node metadata per section rather than
   one blob for the world, and node timers that stop with their section.
2. **The palettes**, which is settled (2026-09-13) and is engine work
   first: `VoxelVariant` gains textures of its own, which finishes what its
   own header already says variants are for -- "a voxel that faces one of
   twenty-four directions, or wears one of eight palette colours". The
   tinted tiles are texture modifier expressions, so the client composes
   them through machinery that already exists. See "The palettes: a variant
   wears its own textures" in the module plan.

   **The meshes are settled and deferred** until after the map: the two
   readers in `extensions/luanti_client` cover two thirds of devtest's mesh
   nodes and were written for the voxel mesher, and the other third is glTF,
   which is a reader nobody has written.
3. **The leftovers**, each small and none blocking anything. They are under
   "Bonuses" below, which is what that section is for; the module plan's
   "Simplified, and the upgrade path" has the full list of what the module
   does not do.

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
preferences screen, and the media set -- a game's models, sounds and
translations went nowhere until 2026-09-13, because only `textures/` was
collected.

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

Not a queue. These are understood well enough to start on any afternoon, and
none of them is on anyone's critical path -- which is exactly what makes them
the right thing to pick up when the current branch is blocked on an answer,
or when a round has just landed and the next has not started.

- **A detached inventory reaches the client** (`builtin/luanti`). It is
  kept server-side already; what is missing is the packet and letting
  `ctx.inventory` and a move reach it, which is the chest's path with a
  different location. A `list[detached:...]` draws empty until then.
- **Put a single item down** (`builtin/luanti`). Luanti puts one item down
  with the right button and ten with the middle; what is picked up is what
  is put down here. A count on the way down as well as up, in the packet
  that already exists.
- **A sneak flag** (`builtin/luanti`). Without it a node with an
  `on_rightclick` cannot be built against. One boolean in `main:place` and
  one argument to `core.item_place()`.
- **A scrolling save list** (`games/luanti_launcher`). The menu shows the
  twelve most recent saves because `ui_utils.vertical_menu` does not scroll.
  Whatever is built for it belongs in `ui_utils`, since it is the same
  widget every menu in this tree uses.
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
