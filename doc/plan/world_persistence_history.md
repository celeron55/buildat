# Saves and the object store: what is finished

Moved out of `doc/plan/world_persistence_plan.md` so that it holds only what
is open. Nothing here is a to-do; it is kept for the reasoning behind what
was built and for the checks each step left behind.

## Step 5: builtin/luanti uses the save

Three of its four parts, as they were built (2026-09-13). 5b -- moving mod
storage from files into the object store -- is still open and is in the plan.

   - **5a. The world and the clock persist. BUILT 2026-09-13.**
     `run_game()` takes the save rather than a world path and derives
     `<save>/luanti/` from it, `create_world()` calls
     `voxelworld::set_save()` between building the registry and lighting the
     world, and the clock -- `time_of_day`, `game_time`, `day_count` -- goes
     into the module's own store in the save, read before the mods load and
     written at `core:shutdown`.

     Two things it turned up. The module's shutdown handler asks the world
     to save after flushing its node writes, because subscribers are called
     in module load order and voxelworld's own handler may already have run;
     asking twice costs nothing now that a section is written only when it
     changed. And `check_map.lua`'s clock check had to become relative and
     put the clock back where it found it -- it rolled the day forward, and
     a check that ages the world by a day on every start is a check that
     breaks the thing it is checking.

     simplified: the clock is written at shutdown and not before, so a
     server that is killed loses the day it was on. Luanti writes its own
     every 5.3 seconds with the map; the upgrade path is to do the same,
     once anything else here is worth a periodic checkpoint.
   - **5c. Node metadata and inventories. BUILT 2026-09-13.** What hangs off
     a voxel -- a chest's contents, a sign's text -- goes into the module's
     own store in the save beside the clock, written at `core:shutdown` and
     read after the mods have loaded, because what it holds is item strings
     and a mod's items have to be registered for one to mean anything. The
     fields are strings and an inventory is lists of item strings, which is
     what `ItemStack()` takes back.

     The fixture checks it across runs the way mod storage is checked: a
     probe in a corner of `minimal_game`'s floor counts the runs in its
     metadata and holds one stone per run in its inventory, and every run
     after the first checks what the last one left.

     simplified: one blob for the whole world. Luanti keeps a block's
     metadata with the block and writes it when the block is written; the
     upgrade path is the same shape -- a blob per section, written when
     voxelworld writes that section -- and it is what a map bigger than the
     sections a mod can reach will need.
   - **5d. Players. BUILT 2026-09-13.** What Luanti's player database holds
     -- where a player stood, which way they looked, their health and
     breath, what a mod wrote on their metadata and what their inventory
     lists held -- goes into the module's store beside the node metadata,
     keyed by the name the client connected under. It is written when a
     player leaves and at shutdown, and read after the mods have loaded, for
     the same reason the node metadata is: an inventory holds item strings.

     The auth entries go with them, because a privilege a mod granted is as
     much a part of a player as their health is, and `core.auth` had nowhere
     to put one before.

     A player is restored before `on_joinplayer` runs, which is where Luanti
     has them come out of its database too.

     The check is a round trip in `lua/entity.lua`
     (`core.__check_players()`), run at every start: a player made for it is
     written down and read back, and every field is compared. It is not a
     live player because adding one would run every mod's join callback to
     find that out.

     simplified: written when a player leaves and at shutdown, not on a
     timer, so a server that is killed loses what changed since. The clock
     beside it names the same upgrade path.

