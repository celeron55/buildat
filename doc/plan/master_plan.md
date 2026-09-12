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
- Section 14 of this file -- the one thing `builtin/client_file` still wants
  before it is level with Luanti: compression.
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

## What is next (2026-09-12, third round)

**The focus is `builtin/luanti` until further notice.** Everything else
unfinished is frozen -- `undermine`, `aggregate` and
`extensions/luanti_client`; see "Frozen" below.

The second round is done. `build-check` merged (PR #54), and the other three
are a stack waiting to merge bottom-up: `client-preferences` (PR #55) into
master, `saves` (PR #56) into that, `luanti-module` (PR #52) into that. M2 is
built; sections 10, 12 and 13 of the history say what each one turned out to
be.

The order of work, which is one line of it rather than parallel branches:

1. **M3 -- it looks like the game.** The big one. Drawtypes through buildat's
   own mesher, media, and the client resolving textures into its own atlas.
   `init.lua`'s three-way split is the largest unexamined piece of it.
2. **M4, M5, M6, M7** after, in the module plan's own order.

Done since this list was written, all in `doc/plan/master_plan_history.md`:
steps 4 and 5a of the persistence plan -- voxelworld's name table, format tag
and modified flag, and `builtin/luanti` keeping its world and its clock in a
save -- and items 1, 2, 3 and 5 of section 14, which is what `client_file`
needed before M3 points it at a Luanti game's whole asset tree.

Two loose ends inside the module, neither blocking: the region reads are
written in Lua and pay an `access_module()` per voxel, so the loop belongs on
the C side inside one `access()`; and the mapgen seam is where `voxelworld`'s
region calls get decided, deferred until there is something to measure them
against.

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

## 14. client_file, for a Luanti-sized media set -- one item left

Items 1, 2, 3 and 5 are built; see `doc/plan/master_plan_history.md`. What is
left is the one that was never about size:

4. **Compress the payload.** Luanti does it for protocol 48 and up. The gain
   on PNG and OGG is small -- they are compressed already -- and it is real
   on models and translation files. The reason to do it anyway is that
   buildat will be compared with Luanti, and missing a feature this basic is
   not defendable. zlib and zstd are already bound.

**Not changed: the gate.** `client_file:files_transmitted` fires only when a
client has everything, and games wait on it before showing the world. Luanti
gates too -- its "Media..." progress bar is the same wait -- so this is not
where buildat is behind.

## Bonuses, for when everything else is stalled or done

Not a queue. These are understood well enough to start on any afternoon, and
none of them is on anyone's critical path -- which is exactly what makes them
the right thing to pick up when the current branch is blocked on an answer,
or when a round has just landed and the next has not started.

- **A client preferences screen.** `doc/plan/client_preferences_plan.md` builds
  the preferences and makes every game honour them, but nothing sets them
  except a file and `-o`. `extensions/__menu` is Lua and already draws menus,
  so a page of sliders and checkboxes is a small job -- it only needs a Lua
  call that writes a preference and persists it, which is why the C++ side is
  the authority for them in the first place. Wanting one is not the same as
  needing one: a preference nobody can find is still honoured by every game.

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
