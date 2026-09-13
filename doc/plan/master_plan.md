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
- Section 14 of this file -- what `builtin/client_file` needed before it
  could carry a Luanti game's media set. Finished.
- `doc/plan/master_plan_history.md` -- the steps this file has finished,
  kept for the reasoning rather than the diff.

Each plan whose work is largely done has a history file beside it, holding
what was built and why it came out the way it did:
`luanti_module_history.md`, `luanti_voxels_history.md`,
`voxel_data_model_history.md`, `aggregate_history.md`,
`aggregate_game_history.md`, `undermine_history.md`. Nothing in any of them
is a to-do.
- `doc/plan/world_persistence_plan.md` -- saves, the user and cache paths, and
  the sqlite object store modules keep their data in. `voxelworld` persists
  nothing today; this is where that stops being true.

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
globalsteps, `core.after`, ABMs, LBMs, the objects and the node timers (M5),
and reading an existing Luanti world -- its map, what hangs off its nodes,
its clock and what its mods remembered (M7). The module plan has what each
turned out to be; `doc/plan/luanti_module_history.md` has the detail.

**And it is checked against Luanti's own tests.** devtest ships a
`unittests` mod of about forty tests of the server API, and it runs inside
the module: thirty-two pass, and the seven that do not are each a
simplification the plan names rather than a bug. See "devtest's own
unittests as the oracle" in the module plan for how to run it -- it is the
first thing to run after touching the API surface.

What is left is, in order:

1. **The client half.** It is what M3, M4 and M5 each say is left of them:
   nothing draws an object, a click is not a dig, and there are no
   formspecs. `games/luanti_launcher`'s viewer is a camera and a HUD line.
   The fork's shape is settled -- which files are copied, which are dropped,
   and that `world.lua` loses a fifth of itself to `voxelworld` -- and
   `init.lua`'s three-way split is the largest unexamined piece of it. See
   "The protocol, and the client" in the module plan.

   **The texture modifiers are blocked on an open question** and are 112 of
   devtest's 390 node types: a module's client Lua runs in the sandbox and
   `buildat.compose_image` is not in it. What of the image and cache-path
   primitives belongs in the sandbox, and under what confinement, is a
   trust-boundary decision; the three shapes it could take are under "OPEN:
   what a module's client half is allowed to do" in the module plan. Nothing
   else in the client half waits on it.
2. **M6, the launcher and its map.** The menu -- which save, and which game
   it needs -- is client work of a much smaller kind, and
   `ui_utils.vertical_menu` already draws that shape elsewhere. The map is
   the bigger half: the world is 3x3x3 sections today, which is why the
   importer drops most of a real Luanti world, and a map that loads and
   unloads around a player is what the mapgen seam was deferred until there
   was something to measure. There is something to measure now.
3. **What is left of M7:** `map_meta.txt`'s seed, the player database, and a
   block's node timers and static objects. The seed wants a mapgen, the
   players want players, and the objects want a `static_save` that means
   something.

Done since the third round, all in `doc/plan/master_plan_history.md` or in
the module's own history: M4's inventories and recipes, all of M5, M7's
importer, and the preferences screen.

One loose end inside the module, not blocking: the mapgen seam is where
`voxelworld`'s own region calls get decided. See "The region calls" in the
module plan.

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
  not abandoned: it comes back once `builtin/luanti` reaches feature parity
  and the client half is what needs doing, because at that point the module's
  forked client and this one are the same problem.

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

Empty at the moment: the client preferences screen that was here is built;
see `doc/plan/master_plan_history.md`.

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
