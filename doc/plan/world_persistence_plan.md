# Plan: saves, paths and an object store

Steps 1 to 3 are built (2026-09-12, branch `saves`): the paths, the sqlite
object store, and `voxelworld` reading its sections back. `games/digger`
keeps its world in `user/games/digger/saves/world`. Step 4 -- what a save
says about its voxels -- is the next piece of work in the third round, and
steps 5 and 6 belong to `builtin/luanti`.

**How it ended up working, where that is not obvious from the plan below:**

- **A row per chunk, not per section.** A section is the load and unload
  unit, but a chunk is what a scene node holds and what
  `serialize_volume_compressed()` describes, so eight rows per section meant
  no container format had to be invented for the eight of them. The key is
  still `(world, position)`: `"<world>/<cx>,<cy>,<cz>"`. A section loads all
  or nothing -- one missing chunk and the section is generated instead,
  because generation is by section, and that is also why the modified flag in
  step 4 is per section.
- **`core:shutdown`.** There was no event for "the server is going away":
  `core:unload` is a module-reload thing and nothing else reached the modules
  after the main loop ended. It is emitted synchronously from
  `src/server/main.cpp`, before the module threads stop, and it is what gets
  the last sections written.
- **The region's sections are created on the first tick**, not in
  `CInstance`'s constructor. A game needs one `core:start` to create the
  world, register its voxels and call `set_save()` in, in that order, and a
  section that comes out of a save must not be generated -- so nothing may
  load before the game has said whether there is a save.
- **sqlite is compiled into `buildat_core`**, as an object library rather
  than a static one. A static archive would have been dropped at link time,
  since nothing in buildat_core itself calls sqlite; the whole point is that
  the shared library exports `sqlite3_*` to a module that cannot link
  anything. The module compiler gets `3rdparty/sqlite/src` on its include
  path the same way it already gets cereal and PolyVox.
- **`valid_name()` is on the interface**, because a save name becomes a
  directory name and that is a trust boundary. `remove()` only ever deletes
  under the one saves directory, and only a name that passed.

## What a save is

A **save** is the unit of persistence: what the user names, lists, copies and
deletes. A **world** is a `voxelworld` instance, and a save holds zero, one
or many of them.

That distinction is the reason this is not called "world persistence".
Luanti's save format *is* a world, so the two words are the same word there.
Here they are not: `voxelworld` already has a `SceneReference` per instance
and "several voxel worlds on one server" is already a design note. So the
store keys sections by **(world, section position)** from the first line of
code. It is free now and expensive to retrofit, and it is most of what the
naming buys.

**Persistence is opt-in.** A game that never opens a save gets exactly
today's behaviour: `voxelworld` generates and forgets. `digger`,
`infidigger`, `aggregate` and an arena game are all unchanged and need no
edits. `voxelworld` persists only once a game has handed it a save and a
world name. An ephemeral game therefore needs no "temporary save" feature --
it does not open one, or it opens one and deletes it.

## Paths

Two base directories, and one rule that sorts everything into them:

> The cache is what the program can recreate by itself. The user path is what
> the user made, chose, or fetched deliberately.

"Deliberately" is what separates a Luanti game the user installed from the
896 MB of media a Luanti server pushed at them.

| | user | cache |
| --- | --- | --- |
| Linux | `$XDG_DATA_HOME/buildat`, default `~/.local/share/buildat` | `$XDG_CACHE_HOME/buildat`, default `~/.cache/buildat` |
| Windows | `%APPDATA%\buildat` | `%LOCALAPPDATA%\buildat\cache` |
| macOS | `~/Library/Application Support/buildat` | `~/Library/Caches/buildat` |
| Android | its own, later -- but it splits the same way (`getFilesDir()` and `getCacheDir()`), so the two names survive |

Inside the user path:

    games/<game>/saves/<save>/       -- a game's saves
    games/<game>/...                 -- anything else it keeps per user
    luanti/games/<gameid>/           -- Luanti content the user installed
    preferences.json                 -- client preferences
    network_addresses.csv            -- servers the user has typed in

A directory per game rather than a flat `saves/<game>/`, because a game will
want other user data eventually -- per-game keybinds, downloaded content --
and one home per game means `rm -r games/<game>` removes everything about it.

What today's `cache/` holds, and where each part goes:

| | size | to |
| --- | --- | --- |
| `luanti_media/` | 892M | cache -- a server pushed it |
| `rccpp_build/` | 16M | cache -- recompiled on demand |
| `remote/` | 6.6M | cache -- files from a buildat server |
| `tmp/` | 1.5M | cache |
| `luanti/` | 4.2M | **user** -- games the user installed, and worlds |
| `network_addresses.csv` | 4K | **user** |
| `window.json` | 4K | **user**, and renamed `preferences.json` |

898 of 900 MB stays cache and does not move at all. Three small things become
user data -- `luanti/`, `network_addresses.csv` and `preferences.json` -- and
`builtin/luanti`'s devtest fixture goes with them.

### Portable and system builds

Two builds, chosen at compile time, the way Luanti has done it for years:

| `-DPORTABLE=TRUE` | `-DPORTABLE=FALSE` |
| --- | --- |
| `user_path` = `<buildat root>/user` | the platform paths above |
| `cache_path` = `<buildat root>/cache` -- where it already is | the platform cache path |
| **recommended for development**, and what this project uses | **recommended for distribution**; there is already an `install()` target, Windows-only so far |

A build option rather than a runtime probe for a directory, because which one
you are is a property of how the thing was built and shipped, not of what
happens to exist beside it.

**`user/`, not `.`.** Luanti's portable builds put the user path at the
program's own directory, which scatters `worlds/`, `mods/`, `screenshots/`
and the rest through the project. One directory for all of it instead.

**And `cache/` stays its sibling, not its child.** The two are separate
because the user path is the thing worth copying -- to another machine, into
a backup, out of a broken checkout -- and a cache inside it would be carried
along every time for nothing. That is also the whole reason the rule that
splits them exists. So a portable build ignores exactly two directories,
`user/` and `cache/`, and `cache/` is already one of them: `.gitignore`
gains `/user` and nothing moves off anyone's disk.

`-D` and `-C` still override either build's choice, which is what a
dedicated server's admin and a test run want.

`user_path` joins `share_path` and `cache_path` in `core::Config`, with `-D`
beside the existing `-P` / `-C` / `-U`. The server needs it too, for saves; a
dedicated server's admin overrides it and that is what the flag is for.

## The store

sqlite, vendored into `3rdparty` and added to `buildat_server_core`'s link
line beside zlib and zstd (`CMakeLists.txt:242`). **Only `builtin/storage`
includes `sqlite3.h`**; everything else goes through its `api.h`, so no
runtime-compiled module ever links it and the "first builtin that needs a
build-time library" problem is not triggered by this.

Vendoring it pays twice: the Luanti importer has to read `map.sqlite` anyway.

Not files. Module data comes in shapes a filesystem is bad at, and Luanti's
own history ran per-file to sqlite rather than the other way. Not an SQL
surface either: Luanti's mod storage is get/set and that has been enough, and
an SQL API handed to whoever writes a game is both a footgun and a
compatibility burden. Object storage is the right amount.

    // builtin/storage/api.h
    struct Store
    {
        virtual bool get(const ss_ &key, ss_ &value_out) = 0;
        virtual void set(const ss_ &key, const ss_ &value) = 0;
        virtual void remove(const ss_ &key) = 0;
        virtual sv_<ss_> list(const ss_ &prefix) = 0;
        // One transaction. The only sane way to write more than a few keys.
        virtual void batch(std::function<void()> writes) = 0;
    };

    struct Save
    {
        // A namespace within the save, created on demand: an empty store
        // and a store that does not exist are the same thing.
        virtual Store* store(const ss_ &name) = 0;
        // The save's directory, for things that are not ours
        virtual ss_ path() = 0;
    };

    struct Interface
    {
        // Split on purpose: neither call can do the other's job by
        // accident, so a typo in a save name cannot silently start a new
        // game. open() returns nullptr if it is not there; create()
        // returns nullptr if it already is.
        virtual Save* open(const ss_ &name) = 0;
        virtual Save* create(const ss_ &name) = 0;
        virtual void close(Save *save) = 0;
        virtual sv_<SaveInfo> list() = 0;      // name, modified_us
        virtual void remove(const ss_ &name) = 0;
    };

A game that genuinely wants open-or-create writes the two lines itself,
where it is visible.

**The game dimension is not a parameter.** A buildat server runs exactly one
game -- it is started `-m ../games/minigame` and that is the whole of it --
so `builtin/storage` takes the game id from the server it is running in. A
game cannot open another game's saves because it has no way to name one.

Behind it: one table, `(store TEXT, key TEXT, value BLOB, PRIMARY KEY(store,
key))`, in `<save>/save.sqlite`. No module ever runs DDL and the backend
stays swappable. WAL mode. The server is multithreaded and `voxelworld` has
its own thread, so the store owns one connection behind a mutex -- simplest
thing that is correct, and the writes are batched anyway.

Keys are strings. Luanti uses an integer primary key for map blocks because
it has millions of 16^3 ones; buildat's sections are 2x2x2 chunks of 32^3, so
a `"world/x,y,z"` key over thousands of rows is fine. *simplified:* the
ceiling is an integer key and a hashed position, and the upgrade does not
change the API.

### Why a save is a directory and not one file

One `.sqlite` per save is nicer -- copyable, nothing half-written.
`core.get_worldpath()` kills it: Luanti mods write real files there, and
sqlite has nowhere to put them without a sidecar directory, at which point
the single-file property is gone anyway.

So `saves/<save>/` holds `save.sqlite` plus room for what is not ours. The
rule: **modules use the object store; the directory is for foreign formats
and escape hatches** -- `get_worldpath()`, the importer's source, a game that
insists on its own format. Shipping a save to a friend is a zip, if anyone
ever asks for it.

## voxelworld

`voxelworld` opens the store named `"voxelworld"` in the save the game gave
it, and keys sections `"<world>/<x>,<y>,<z>"`. The value is what
`serialize_volume_compressed()` already produces -- the same bytes
replication already sends, already versioned, already carrying planes -- so
the on-disk format is not designed, it is reused. The one thing in front of
it is the format tag; see "The format, and migration" below.

Beside the sections, the save holds **the serialized `VoxelRegistry`**, which
`VoxelRegistry::serialize()` already produces because it is already sent to
clients. What it is for is below; it is not the authority on numbering.

Writes go through `batch()`, one transaction per flush. A section at a time
outside a transaction is the classic slow-save and it is the reason `batch()`
is in the first version rather than an optimisation later.

`load_section()` gets its missing half: read the section if it is there,
generate it if it is not.

## What a save says about its voxels (settled 2026-09-12)

**The running game owns the numbering; the save stores names.** An earlier
draft of this file had it the other way round -- the save's registry replaced
the game's, so "the numbering a save was written under is the numbering it is
read under" -- and that is wrong. The game is the only thing that can decide
whether a name still means what it meant, and a save has nothing to
contribute to that question. Luanti has had this right for years: a MapBlock
carries a mapping from its own ids to node names, and loading translates
them into the session's registry, which is already built and is never
reorganised.

So:

- **A name table per save**, `save_id -> VoxelName`, append-only, never
  renumbered. Luanti keeps this per MapBlock because a MapBlock is its unit
  of storage; we have one store per save and chunks eight times the volume,
  so one table for the save is the same idea more cheaply. A chunk written
  under an older table stays valid because the table only grows.
- **Load** builds `save_id -> session_id` by name and remaps the id field.
  Everything else in the word -- param, light, whatever a game's format binds
  -- travels untouched, which is what lets an unknown voxel survive a round
  trip intact.
- **Save** is the reverse, appending any name the table has not seen.
- **The identity fast path is what makes it free.** Same game, unchanged
  registration order, and the two numberings are identical -- so compare once
  when the save is opened, and if the mapping is the identity, a chunk stays
  the byte copy it is today. The work falls only on the run where the game
  actually changed.

### A voxel type the game no longer registers

It gets a session id, its word is kept whole, and it is written back under
the same name -- straight from Luanti, and the part that makes this safe
rather than merely tidy.

Where we can do better than Luanti's blank unknown node: the save carries the
definitions too, so it is **drawn with its saved definition**. A dropped
voxel type still looks like itself in an old world. What that would hide is
that the game no longer supports it, so it comes with a marker and two
warnings, all of which are free:

- `VoxelVariant::color` multiplies into the vertex colour, and the vertex
  colour is *light, not albedo*, so tinting every variant of such a
  definition is one field written while it is being constructed anyway. It
  reads as a block lit by the wrong colour. Honest limitation: it is a light
  tint, so in the dark an unknown voxel looks like everything else.
- A warning at load naming every unregistered type, and the list exposed so a
  game can put it on screen rather than leaving someone to walk into it.

### The format, and migration

**Each chunk is tagged with the format it was written in**, and the save
holds a small table of formats. This is Luanti's MapBlock property and it is
what it buys: chunks are independent, which is error tolerance -- one bad
chunk is one bad chunk -- and nothing is ever rewritten that was not
modified. A save may hold a mix of formats and that is fine; it converges as
sections are touched.

The chunk blob already carries half of what is needed. `serialize_volume_planes()`
(`src/impl/voxel_volume.cpp:441`) writes a version byte, the region, and each
plane's **name and bit width** -- so a plane appearing, vanishing, being
renamed or resized is visible in the chunk itself. What it does not write is
where `id`, `light_sky` or `param` sit *inside* a plane. That is what the
saved `VoxelRegistry` is for: it is the format the chunks are in, and that is
its whole job now.

**The rule the engine follows: it moves data, it never reinterprets it.**

| | |
| --- | --- |
| same role, same width, different position | moved |
| a role or plane the session has and the save does not | zero |
| a role or plane the save has and the session does not | dropped, with a warning naming it |
| the id field | remapped by name, always -- that is what the name table is for |
| **any width change, and any change to a named plane** | **the game's migration, or refuse** |

The last row is the important one. Loading a 4-bit field into a 3-bit one
loses data; and even 4 bits into 5 is a decision -- scale, or zero-extend? --
that only the game can make. An engine that guessed would be wrong silently,
which is the worst way to be wrong about a world somebody built.

**A game's own plane is versioned by name.** `games/aggregate` packs rock,
sand, fibre, binder, water, bond and life inside `VoxelPlane("aggregate:mix",
32)`, and the engine knows that plane's name and width and nothing else about
it. So a game changing what is in there creates `aggregate:mix2`, and its
migration converts one to the other. The engine needs to understand none of
it; it only has to hand over the chunk.

**The hook is per chunk, not per voxel** -- one virtual call handing the game
the old volume and the engine-moved new one, so it fixes up its own planes
with whatever loop it likes instead of 262,144 virtual calls per section. A
`begin(from, to)` that returns false is how a game says "I will not migrate
this", which is better than a guess and much better than a crash.

**Writing in an old format is left possible and not built.** The hook is
directional, so a game that wants to keep a save readable by an older build
can be asked to convert the other way, and the format table already holds
more than one. What is not built is the switch that pins the write format,
because nothing asks for it yet, and the burden of getting a backwards
conversion right is the game's.

### What this means for the games in the tree

`games/digger`'s worldgen writes `VoxelInstance(1)` through `VoxelInstance(7)`
literally (`main.cpp:101-164`), with `// id 1` comments keeping them in step
with the `add_voxel()` calls. The name table makes that *safe* -- the ids mean
what they meant -- but it should use the ids `add_voxel()` returns instead,
which turns "safe" into "impossible to get wrong". A few lines in a sample
game.


## Order

**1 to 3 are done** -- the paths and `-DPORTABLE`, the vendored sqlite and
`builtin/storage`, and `voxelworld` saving and loading sections. Each left a
check behind: an assert-based self-check of the path selection (the XDG
variables present, absent and empty, and `-C`/`-D` winning over both), a
round trip in `builtin/storage` over an in-memory database, and digger
generating 108 sections into a save which a second run loaded without
generating any -- the two saves byte-identical over all 865 rows.

4. **The name table, the format tag and the modified flag.** What "What a
   save says about its voxels" describes: the save stores names and the
   running game owns the numbering, each chunk is tagged with the format it
   was written in, and a section is only written when something changed.
   These are one piece of work because they change the same two functions --
   `save_section()` and `load_saved_section()` -- and because the modified
   flag is what keeps the other two affordable. It lands before 5a.
5. `builtin/luanti` uses it. Written as one step originally, which hid that
   it is one thing and three later things:

   - **5a. The world and the clock persist.** `voxelworld::set_save()` from
     the module, and the clock -- `time_of_day`, `game_time`, `day_count` --
     into the save's object store. This is the only part that touches voxel
     ids, and so the only part that waits for step 4: the module's Lua
     content ids are allocated while the mods load and the `VoxelRegistry`
     is built from them, so a save that dictated the numbering would
     desynchronise the two halves silently.
   - **5b. Mod storage into the object store.** The code path exists
     (`bootstrap.lua`) and writes serialized-Lua files under
     `<save>/luanti/mod_storage/`, which works; moving it into the store is
     a small redirect when there is a reason. Untested so far -- nothing in
     a devtest run has called it.
   - **5c. Node metadata and inventories.** With M4, not before it.
   - **5d. Players.** With M5.

   Already done, and listed here because the original step 4 named it:
   `core.get_worldpath()` is `<save>/luanti/`, a directory of the save's
   rather than the save's own root, so that a Luanti mod writing through it
   -- which is normal, and which games depend on -- cannot land on
   `save.sqlite`.
6. The Luanti importer, which is its own milestone in the module plan.

Steps 1 and 2 are independent of everything in `builtin/luanti` and can land
whenever. Step 3 is what the sample games notice. Step 4 is what makes a save
survive the game changing under it.
