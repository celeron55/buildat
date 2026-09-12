# buildat's voxel data model: a design note

Not a plan and not decided. This is the thinking from a session that spent a
long time inside luanti_client, written down at the engine's level, because
the Luanti client is *one sample point* for what buildat has to support and
not the thing that should decide the shape of it.

Kept out of git (`/local`) on purpose: committing it would read as a
decision.

## What exists today

A voxel is one `uint32_t` (`interface::VoxelInstance`), cut by the engine:

- id, bits 0...20 (`VOXELTYPEID_MAX` 1398101)
- sky light, bits 24...27; lamp light, 28...31
- bits 21...23 unused

`pv::RawVolume<VoxelInstance>` is the volume, and it appears in 51 places
across `src/interface`, `src/impl` and the Lua bindings, none of them
templates. `pack_voxel_volume()` writes into named bit ranges through a fixed
enum ("id", "skylight", "lamplight", "light", "raw"). The mesher reads the id
to look a definition up (`CachedVoxelDefinition`, **368 bytes**, indexed by
id) and the light bits to write vertex colours.

So: the engine decides what a voxel word means, and every game gets the same
cut. That is the thing worth revisiting.

## The games to design for

Each of these is a real shape of game, and each wants something different:

1. **A Minecraft-like of buildat's own** (`module/voxelworld`, the original
   demo): hundreds of ids, no per-voxel parameter, baked light. Today's
   layout *is* this game, which is why it looks arbitrary from anywhere else.
2. **A Luanti client**: 16-bit ids, 8 bits of light in two nibbles, 8 bits of
   param2 whose meaning is per definition -- a facedir, a wallmounted
   direction, a liquid level, a palette index. Thousands of definitions.
   Needs the parameter to reach *meshing*: it turns a shape, picks a surface
   height, permutes a cube's tiles, tints a face.
3. **A physics or simulation game**: three to eight ids and several 8-bit
   fields -- temperature, pressure, damage, flow. Meshing cares about almost
   none of them; the simulation reads and writes them hot, over the whole
   volume, and wants to vectorise. An interleaved word is the worst possible
   layout for that; a plane of `uint8` is the best.
4. **A voxel painter or art tool**: one implicit definition and a colour per
   voxel -- 32-bit RGBA, or a palette index. Meshing needs the colour in the
   vertex data. There is no registry to speak of.
5. **A mass-terrain game**: 8- or 16-bit voxels, LOD, streaming, tens of
   millions of voxels resident. Wants the narrowest word that will do, and
   wants LOD generation to read the same data.
6. **Anything with sparse per-voxel metadata**: chests, signs, machines.
   This is *not* a plane -- it is a map keyed by position, and saying so is
   part of the design.
7. **Anything networked**: the layout has to serialize, travel and compress.

## The observation that decides it

Luanti's own mapblock is already three planes: 4096 `param0`, then 4096
`param1`, then 4096 `param2`, one after another. Not interleaved. It is that
way because most consumers want one of the three, and because three arrays of
low-entropy data compress far better than one array of interleaved words --
zstd on the wire sees runs instead of noise.

The same reasoning applies inside the engine:

- **The mesher's hot array is the id.** Face culling and the definition
  lookup read a voxel's neighbours six to twenty-six times over. Halving
  *that* stream is worth more than halving everything.
- **A simulation's hot array is one of its own fields**, and it never wants
  to touch the id at all.
- **A painter's hot array is the colour.**

Interleaving forces every consumer to pay for every field. Planes let each
pay for what it reads. That is structure-of-arrays against
array-of-structures, and voxel access is the pattern where it wins.

## The shape I would propose

**A `VoxelFormat`, made by the game and handed to everything.** A volume plus
a format is self-describing; the registry stays about definitions rather than
about bits. A format says:

- **Planes**: an ordered list of `{name, bits}` where bits is 8, 16 or 32.
  One allocation holds them all (plane offsets into one buffer), so a volume
  is still one thing to allocate, serialize and hash.
- **Role bindings**: for each role the *engine* understands, where it lives
  -- `{plane, shift, width}` -- plus how to downsample it for LOD. The roles
  are a closed set:
  - `id` (required): indexes the registry.
  - `light_sky`, `light_lamp` (optional): what `use_skylight` reads.
  - `param` (optional): what a definition's own rule interprets -- the turn,
    the level, the mask. The engine passes it to the shape logic; the
    *definition* says what it means.
  - `color` (optional): RGBA or a palette index that reaches the vertex data.
  - Everything else in the volume is opaque to the engine. A game's physics
    fields are its own business, and the engine must not need to know them.
- **Defaults**: one 32-bit plane with `id` at 0...20 and the two lights at
  24...31 is today's layout, so nothing existing changes and nothing has to
  be migrated.

**Why roles rather than raw bits.** A role carries more than a position: it
says how LOD folds the field (id by mode, light by max or mean, colour by
mean), whether the mesher may skip it, and what a missing binding means (no
light at all -- which a painter wants -- rather than black). Raw bits would
put that knowledge back in each game.

**What the mesher does with it.** Read the format once per chunk into locals,
specialise the inner loop on the id plane's width (three instantiations of
one loop, not of the engine), and hoist "is there light?" and "is there a
colour?" out of the per-voxel path. The per-voxel cost is a shift and a mask
from a register.

**Where the colour goes.** The mesher writes light into the vertex colour
(rgb the bounced and lamp light, alpha the sky factor). A game's own colour
either multiplies into that -- which is what an unlit voxel shader wants, and
what Luanti does with its palettes -- or takes a channel of its own, since
`CustomGeometry` has a second texture coordinate and a tangent going spare.
The first is a few lines and covers cases 2 and 4; the second keeps light and
colour separable for a PBR path. Open question.

**Answered, partly, by building it.** The first does *not* cover case 2. The
vertex colour carries light in a split -- `rgb` the light that does not come
from the sky, `a` how much of the sky the surface sees -- and the fragment is
`texture.rgb * (cAmbient.rgb * a + rgb)`. A tint multiplied into `rgb`
therefore tints a voxel in shade and leaves the same voxel in sunlight
untinted, because `a` is a scalar and cannot carry a hue. A palette is a
multiply against the texture and has to reach it. See the blocker section in
`doc/plan/voxel_data_model_plan.md` for the three ways out and which one to
take.

## What this is worth, honestly

- Case 2 stops needing a voxel id per (definition, param2) pair: measured at
  5701 extra ids on VoxeLibre, and a texture composed and an atlas segment
  uploaded for each of the tinted ones.
- Case 3 becomes possible at all, rather than being expressible only as an
  id per state.
- Case 4 becomes trivial: a one-definition registry and a colour plane.
- Case 5 gets its narrow word without the engine being templated on it.
- Serialization and network get planes, which compress the way Luanti's
  mapblocks already show they do.

And what it does *not* buy: it is not a fix for the frame stutter measured in
this client. That was a node type's textures being loaded and put in an atlas
the first time it is seen, plus a definition table of 368 bytes an entry hit
at random by id. Both are unaffected by how the word is cut.

## What not to do

- **Do not template the whole engine on the voxel type.** 51 sites, and the
  bindings would have to instantiate a fixed set anyway. Specialise the
  inner loop, not the API.
- **Do not let games define roles the mesher has to interpret.** An open set
  of planes with a closed set of roles is what keeps the engine's job
  bounded.
- **Do not put sparse metadata in a plane.** A chest's inventory is a map
  keyed by position; a plane would spend a word per voxel on nothing.
- **Do not lose the single-store property silently.** One 32-bit word is
  written atomically today; an id and its param in two planes are two
  stores, and a reader on another thread can see one without the other. The
  mesher works on its own padded copy, so it is safe as things stand -- but
  that has to be written down, or the first live-volume reader will find out
  the hard way.

## Cache, since it comes up

Measured on the machine this was written on (i7-11850H): L1d 48 KB a core,
L2 1280 KB a core, L3 24 MB shared, 64-byte lines. `sizeof(VoxelInstance)` 4,
`sizeof(CachedVoxelDefinition)` 368, `sizeof(CustomGeometryVertex)` 52.

For a chunk of edge S the padded edge is S+2, and the mesher's resident set
is three z-slices rather than the volume: 3.8 KB at S=16, 13.5 KB at 32,
48 KB at 62 -- so the *volume* stays in L1d up to S≈62 at 32 bits a voxel.
It is not the volume that fills the cache, though: 2493 definitions are
918 KB hit at random, and the output vertex buffers pass the volume in size
at S=16 already. With those in the room the practical ceiling is S≈32.

The lever worth pulling there is not the word: it is that 368 bytes. Most of
it is two inline shape vectors and the LOD atlas references. Splitting the
meshing-hot fields -- draw type, edge material, the flags, six atlas
references, under 64 bytes -- from the cold ones would put a chunk's worth of
definitions in L2 beside any volume size a game picks.

## Extensibility: a module adds a plane, no questions asked

The point buildat cares about, and the thing the format sketched above gets
wrong by being a list the game writes once. Either a game offers extension
points to the modules that depend on it, or -- better -- it does nothing
special and the engine's own handling of planes is extensible: a module says
"I want a byte per voxel" and gets one.

**Why planes can do this and a bit-cut word cannot.** Adding a field inside
a 32-bit word moves the other fields: every saved chunk and every live volume
has to be rewritten, and two modules asking at once contend for the same
bits. Adding a *plane* moves nothing. The existing planes keep their widths,
their offsets and their bytes; the new one is a new array. That is the whole
argument, and it is worth putting above the cache and compression arguments,
because those are optimisations and this is a capability.

**The mechanism, and it is one buildat already has a precedent for.** This is
the same problem as Luanti's node ids: a name that mods agree on, an integer
the data is stored under, and a table saved with the world so the two survive
a restart and travel to a client.

- **A field registry per world.** `field = world:voxel_field("mymod:heat",
  {bits = 8, default = 0})` at load time. Name-keyed, so two modules cannot
  collide and neither has to know about the other. It returns a handle; the
  integer behind it is allocated by the world, saved with the world, and
  sent to clients along with the voxel registry. Registration is
  **append-only**: a name that has been allocated keeps its slot forever, so
  saved data never needs migrating.
- **Lazily materialised per chunk.** A chunk does not carry a plane until
  something writes to it; a read of a missing plane returns the field's
  default. So "add a plane, no questions asked" costs memory in proportion
  to *use* rather than to world size -- a heat field that only matters near
  the volcano costs nothing in the rest of the world. This is what makes the
  no-questions-asked answer affordable rather than merely allowed.
- **Unknown planes are preserved, not dropped.** A chunk saved by a world
  with five fields, loaded by a world with three, keeps the two it does not
  understand as opaque bytes and writes them back out. A module that is
  disabled for a session does not cost the player their data. (Luanti does
  the same with unknown nodes, for the same reason.)
- **Storage is uncontested; roles are contested.** Anyone may add a plane
  and read and write it -- that is the "no questions asked" part. What is
  *not* free is binding one of the engine's roles to it: `id`, the two
  lights, `param`, `color` can each have one binder, because the mesher has
  to know which bytes mean what. So a module that just wants to remember
  something per voxel needs no cooperation at all, and a module that wants
  to change how the world is *drawn* has to be given the role by whoever
  owns it -- which is the game. That split is what keeps an open storage
  model from turning into modules fighting over the mesher.
- **A game that wants to offer more than that** declares fields of its own
  and documents what it does with them -- "write to `mygame:heat` and blocks
  glow" -- which needs nothing new from the engine: the game reads the plane
  in its own code and drives the roles it owns.

**The framing that keeps this honest: a plane is a per-voxel component.**
The field registry is a component registry, a chunk's set of planes is what
that chunk has, the engine's roles are the components the engine itself
understands, and everything else is a module's business. Read it that way and
the rules above are the ones every ECS ends up with, which is a good sign
rather than a coincidence.

**What it costs, and the two rules that keep it safe.**

- **Bytes per voxel per world grows with the fields in use.** Report it
  rather than police it: a world's summary line should say "5 fields, 7
  bytes a voxel, 4 materialised in this chunk" so that a module adding a
  32-bit plane to a mass-terrain game is a visible choice and not a mystery.
  A cap belongs in the world's configuration, not in the engine.
- **Registration is append-only and a chunk's plane set is materialised
  under that chunk's lock.** A reader -- the mesher, on its own thread --
  takes a snapshot of the plane pointers and works from that. Without those
  two rules, adding a plane while a mesher runs is a data race, and the
  mesher already works from a padded copy so the discipline costs nothing.
- **Bulk access matters more than per-voxel access.** A module iterating its
  plane wants the whole plane for a chunk as one buffer (the way
  `pack_voxel_volume()` already hands ids in), not a Lua call per voxel. The
  per-voxel accessor is for convenience; the plane accessor is for work.

## Adjacent: more than one world

A separate question -- several voxel worlds on one server, each on its own
thread, for arenas or for an overworld with dungeons -- is mostly about
lifecycle and threading, not about what a voxel word means, and it wants its
own note rather than a section here. It does put **one constraint** on this
design, though, and it is cheap to honour now and expensive to retrofit:

**Nothing in the format, the field registry or the definition registry may be
global.** Everything above is already worded per world (`world:voxel_field(...)`,
"a field registry per world", "saved with the world"), and that has to stay
literally true: a format instance, a name-to-slot table and a definition
table per world, reached through a world handle, with no process-wide
singleton and no static id counter. Two worlds may then allocate the same
name a different slot, which is fine as long as the mapping travels with the
chunk data and with the registry that clients get.

Most of that is already true: `voxelworld::Interface::create_instance()`
takes a `SceneReference`, `get_instance()` looks one up, and each `CInstance`
owns its own `VoxelRegistry` and its own sections. So several worlds on one
server already exist in the shape of the API; a format and a field registry
hanging off the registry inherit that for free, which is the second reason to
put them there.

The part that is *not* this design's problem, and is why the rest wants its
own note: threads. Today everything goes through the module's one call queue.
Per-world tick loops, which thread a mesher belongs to, and how a game module
moves a player between worlds are all that note's business.
