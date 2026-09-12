# Implementing aggregate

The executable half of `doc/plan/aggregate.md`: what gets built, in what order,
and how each step is known to work. Read the design note first for *why*;
this file is *what, when, and what breaks*.

Kept out of git (`/local`) with the other plans.

## Scope, and what "done" means

Done, for a first playable: a world made of mixtures with no material ids in
it, dug and poured and built in, where water migrates under pressure, loose
material settles, a mixture with nothing holding it together holds nothing
up, and you
can tell what a voxel is made of by looking at it.

Not in scope, and deliberately: saving, multiplayer beyond what every sample
game already gets for free, and any material count beyond what reads on
screen.

## The order, and why it is this order

Four steps and a spike. The order is chosen so that **every step has a
consumer before aggregate exists**, and so that the question most likely to
kill the game is answered second rather than last.

1. **The vertex payload, and the first modifiers: `tint` and `sag`.** DONE.
   No planes, no selectors, no new game. Its consumer was meant to be
   luanti_client; it turned out not to be, and the spike is its check
   instead -- see "What it turned out not to replace" below.
2. **The look spike.** DONE. A static scene of hand-set mixtures, to find out
   whether grain, speckle and gloss make two mixtures of the same colour
   look like different materials. This is the cheapest possible answer to
   the question that decides whether aggregate is a game at all.
3. **Per-property selectors and tables.** The engine stops asking "what
   definition does this id have" and starts asking each question through its
   own selector. With only the `FIELD` selector this is a pure refactor and
   every existing game is unchanged, bit for bit.
4. **Planes.** DONE. The storage change, under a mesher that already does
   everything aggregate needs. Existing games became a single 32-bit plane
   and did not notice -- and meshing came out slightly faster than before,
   which is the measurement that was to decide whether planes stayed.
5. **aggregate itself.** World, simulation, look rules.

Two things worth saying about the order. The **payload comes first** because
it is the only part with an existing consumer, so it is the part that gets
exercised by a real game before anything depends on it. And **planes come
late** because they are the change most likely to break everything and least
likely to teach anything new -- the design is already written and the
unknowns are elsewhere.

## Step 1: the payload, `tint` and `sag`

### What is built

**In `VoxelFormat`**, modifier roles beside the data roles:

- `tint`, `wetness`, `grain`, `gloss`, `speckle`, `emission` -- **surface
  modifiers**, each a field, at most four bound at once.
- `sag_top`, `sag_bottom` -- **geometry modifiers**, each a field.

The four surface slots are ordered by the format, and that order *is* the
shader contract: slot 0 is whatever the game bound first. A game's shader
knows its own order; the engine only promises four normalised scalars.

**In `VoxelDefinition`**, the parameters each modifier needs:

- `tint_ramp` -- two colours, lerped by the tint scalar. Not a per-voxel
  RGB: that would eat three of the four slots, and a ramp covers Luanti's
  palettes, wet soil and a mixture's colour for one.
- `sag_extent` -- how far a full-value sag moves a face, in voxels.

**In the mesher**, three things:

- `DefineGeometry(..., hasTangents = true)` when any surface modifier is
  bound, and the four scalars written into `CustomGeometryVertex::tangent_`
  -- the slot the voxel mesher has never used. Voxel faces are axis-aligned,
  so a normal-mapping shader derives its tangent from the normal and does
  not need it.
- Sag applied to vertex positions. A face's top vertices move by the owning
  voxel's `sag_top`, its bottom vertices by `sag_bottom`; a vertex shared by
  four voxels takes their average, which is `liquid_corner_top()`
  generalised and is what stops a sagging surface reading as stairs.
- All of it hoisted: a world that binds no modifiers runs the loop it runs
  today, with the branches outside it.

**In `builtin/voxel_shading`**, the reference consumption of the four
scalars, so that the feature can be seen without writing a shader first.
Deferred into step 2: tint and sag need no shader -- one moves the vertex
colour and the other moves vertices -- and what the other four should look
like is exactly what the spike is for.

### What it replaces

`VoxelVariant::color` and `VoxelVariant::liquid_top` are the discrete
ancestors of `tint` and `sag_top`. Both stay -- luanti_client's facedir
tables still want variants -- but the two fields inside them become the
special case of the modifier reached through the param.

### What it turned out not to replace -- and what that does to the order

**Palettes stay where they are.** The step was written expecting
luanti_client to drop a voxel type per palette colour, and that is not what
the tint does. A palette entry multiplies the *texture*; everything that
reaches the vertex colour -- `VoxelVariant::color`, the `color` role and now
the tint -- multiplies the *light*. That is the same blocker already
recorded in "The blocker" in `doc/plan/voxel_data_model_plan.md`, and building
the tint did not move it: a light tint shows in shade and vanishes in
sunlight, which is not what a palette is.

So the tint replaces the *discrete* colour rather than the composed texture:
wet soil darkening, a load reading hot, a mixture shifting colour with what
is in it. Those are all lighting-coloured things and they are what the
modifier is right for.

An albedo tint would want either a channel of its own or three of the four
surface slots. It is not built here, and the thing that should decide it is
step 2, which is the first time anyone looks at a tinted mixture and says
whether it reads.

**What this does to the order:** step 1 has no existing consumer after all,
so **step 2 is also step 1's check**. The spike sets the fields by hand and
is where tint and sag are first seen at all. The liquid half of the check
below is still worth doing, but it is a VoxeLibre run for one variant table
and it waits until something else wants that server up.

### Check

luanti_client against VoxeLibre:

- a palette-tinted area (grass, leaves, water) before and after: the same
  colours on screen, and **the composed tinted textures and the
  (definition, colour) pairs gone from the registry**, which the load line
  already counts.
- a flowing liquid: the same surface heights, out of `sag_top` instead of a
  variant per level.

Both are screenshot comparisons against the current build plus a count in a
log line, which is the shape of test this tree already uses.

## Step 2: the look spike

Built and run; what it answered is below. **Kept as a sample game** rather
than thrown away: it is the only thing in the tree that exercises the
modifier roles, so it is their regression test.

### What is built

A static scene -- `games/aggregate_look`, throwaway or kept as a sample --
of a grid of cubes with hand-set field values. No simulation, no planes, no
rules: the fields are written directly, the modifiers do their work, the
shader draws it.

The grid runs the interesting axes: rock-to-sand at ten steps, dry-to-
soaked, none-to-all wood, and a few three-way mixtures.

### The question

**Can you tell them apart?** Specifically: can 70% rock / 30% sand be told
from 30% / 70% at a glance, from across a room, in a cave and in daylight?

### What a bad answer means

If it is mush, the responses in order of preference:

- **More separation in the base texture**, chosen by threshold: fewer,
  more distinct base looks with the modifiers only refining them.
- **Fewer distinguishable states**: four levels per material rather than
  sixteen, so mixtures read as recipes rather than as a continuum.
- **Fewer materials.** Four is already the plan; three may be the answer.

If it is still mush after those, that is worth knowing before the storage is
rewritten, which is the entire point of doing this second.

### What it answered -- built, run, looked at

`games/aggregate_look`, fifty samples in a wall. Its README says what the
rows are; this is what came back.

**The answer to the question as asked is no, and that is fine.** 70/30 rock
and sand can be told from 30/70 -- but *only* because the threshold between
the two base looks falls between them. Two mixtures on the same side of a
threshold cannot be told apart by the grain alone at any distance. So the
number of states a player can see is **the number of base looks, not the
number of levels in a field**, and where the thresholds are put is the whole
design. That is the first of the fallbacks written above, arrived at from
the picture rather than from the argument, and it is what step 5 should be
built on: three or four base looks along rock-to-sand, not two.

**The grain does not read, and it should not.** Loose sand and packed sand
look the same in life too, which is exactly why sand is dangerous -- so a
modifier that refuses to show how loose a heap is has landed on something
true rather than failed. What follows for the game is a positive: the danger
is the thing you cannot see, and the game can make that its own -- a probe, a
sound, a view mode, a collapse. It also says the *other* scalar slots should
carry something that does read, and grain is a poor use of one.

**What reads at a glance, in daylight and in a cave:** the albedo tint, over
its whole ramp; the wetness, which darkens and sharpens; and the sag, which
is unambiguous because it changes the silhouette. Three of those are enough
to say what a voxel is made of. The gloss reads as a sheen and wants
something to reflect, so it is real but weak on its own.

**What it cost to find out:** two bugs in the engine and a wrong idea about
the tint, all three of which would have been found much later and much more
expensively. That is the case for spiking, made.

## Step 3: per-property selectors and tables -- DONE, and much smaller

### What it turned out to be

**One selector and one table, not four of each.** The step was written as a
table per property -- look, physically_solid, transmits_light,
edge_material -- each with its own selector. Building it that way turned out
to be answering a question nobody asked: every property a voxel has already
lives on its `VoxelDefinition`, so **a selector that finds the definition
answers all of them at once**. A world that wants a finer distinction in one
property than in another writes the rules that make it and points them at
definitions that differ in that property alone, which costs a definition and
no engine machinery at all.

So what got built is `VoxelRegistry::set_look_selector()`: how a voxel's
definition is found. `FIELD`, the default, is the format's id role, which is
today's behaviour exactly -- so **sub-step 1 needed no work and no call site
changed**, because "index the registry by the id field" already *was* the
FIELD selector. `RULES` is the new capability: an ordered list, each a
conjunction of ranges over fields, first match wins.

`QUANTISED` is not built. It existed to be the key of the memo, and the memo
is not built either: a rule list is walked per voxel asked about, which is a
few comparisons. There is nothing to measure against yet and no size to
choose for a cache. The note in `interface/voxel_selector.h` says so and
says what the upgrade is.

### What it cost outside the registry

One thing, and it is the kind a plan does not predict: PolyVox carries a
per-face `material` from the face-culling pass to the geometry pass, and the
mesher was putting the id role in it. With no id role to put there, every
face came out as air and the world drew nothing. It is now the look
selector's answer on both sides. The same applies to the LOD pass, which
picks a dominant voxel by comparing ids.

### Its consumer

`games/aggregate_look`, which now stores **no voxel type id at all**: two
bits of rock and two of sand per voxel, and two rules over them. The one id
role bound is written as 1 everywhere, because that is how voxelworld tells
a generated voxel from an ungenerated one -- which is worth keeping separate
from what a voxel *is*, and the separation is now explicit.

### What was planned, for the record

### What is built

`interface/voxel_selector.h`:

    struct VoxelSelector {
        enum Kind { FIELD, QUANTISED, RULES };
        // FIELD:     key = (word >> shift) & mask
        // QUANTISED: several fields cut to a few bits each, packed
        // RULES:     ordered {field, lo, hi} conjunctions, first match wins,
        //            behind a memo keyed by a QUANTISED tuple
        uint32_t key_of(uint32_t word) const;
    };

and, on the registry, a table per property rather than one definition per
id:

    look             selector -> key -> VoxelDefinition
    physically_solid selector -> key -> bool
    transmits_light  selector -> key -> bool
    edge_material    selector -> key -> uint8

### The order within the step

1. **`FIELD` only, and every existing game on it.** Every property's
   selector is the id field, every table is indexed as it is today. This is
   a refactor whose acceptance test is that nothing changes: the sample
   games' check images identical, luanti_client identical.
2. **The hoisting.** Each loop reads its selector once before it starts, the
   way the mesher already reads the voxel format. What is left inside the
   loop is the shift, the mask and the index it does today.
3. **`QUANTISED` and `RULES`, plus the memo.** No consumer until step 5, so
   the check is a self-test: a rule table and a sweep of voxel words against
   a reference implementation written the obvious slow way.

### The thing to get right

**These run on the server too.** The light flood, `merge_volume()` and the
physics ask per-voxel questions where there is no mesher. Selector and table
evaluation belongs in `interface/`, beside the registry, called by the
mesher and `voxelworld` and the physics alike. Writing it inside
`impl/mesh.cpp` is the mistake this step exists to avoid.

## Step 4: planes

**One thing the spike changed about the case for this, on record and not
acted on.** The reason planes come before the game is that four materials at
eight bits each is thirty-two bits before light, a tint or a sag. The spike
says the *look* needs far fewer -- two bits was enough to read -- and at four
bits each, four materials plus light and two modifiers fit one word. So a
first playable aggregate could be built on a word, and planes could then be
built against a game that had actually run out of room.

That is not what is being done, and deliberately: the decision on record is
to aim straight for planes and to call them off only on unusable
performance. The observation is kept because if planes do go badly, this is
the fallback that exists, and because the argument it weakens -- width --
was already the weak one when undermine fitted in twenty of thirty-two bits.
What it does not weaken is the other argument, which is the capability: a
module adding a field without asking the game for bits, and a simulation
that sweeps a plane rather than a call per voxel.


The design is written: "Stage 2: planes, as designed" in
`doc/plan/voxel_data_model_plan.md`. Nothing here supersedes it; what follows
is the order and what each part breaks.

1. **`VoxelFormat` grows `planes`**, and `VoxelField::plane` starts being
   read. Nothing else changes; every format is one 32-bit plane.
2. **`VoxelVolume`** replaces `pv::RawVolume<VoxelInstance>` as the type the
   engine passes around: a region, a format, and one allocation holding the
   planes. 51 sites, none of them templates.
3. **The plane view for PolyVox.** The cube extractor wants `getVoxelAt`, a
   nested `Sampler` constructible from a volume pointer, and nothing else --
   checked, in the bundled copy. So a view over the id plane is a small
   header and no patch.
4. **Serialization format 4**: region, the plane list, then each plane's
   bytes, zstd. Formats 2 and 3 load as a single 32-bit plane, so **saved
   worlds and the wire keep working and are rewritten as 4 when a chunk is
   next committed**. No migration pass.
5. **`pack_voxel_volume()`** takes a plane name as well as a role name.
6. **The field registry**: `world:voxel_field("mod:name", {bits, default})`,
   append-only, serialized with the registry.
7. **Lazy per-chunk materialisation.** For aggregate this is not an
   optimisation: eight bytes a voxel over a world is hundreds of megabytes,
   and almost every chunk is entirely one material. A chunk carries a plane
   only once something writes it, a plane that is one value everywhere costs
   one byte, and a read of a missing plane returns the field's default.
8. **Bulk plane access**, because a simulation that sweeps wants the plane
   and not a call per voxel.

### Acceptance

The sample games' check images identical, before and after, at every
sub-step. That test has caught every regression in this branch so far.

### The measurement that decides whether planes stay -- MEASURED, they stay

Meshing time per chunk, on digger, with `DEBUG_CORE_TIMING`, two runs each
side, 65 chunks a run:

| | median | p90 | mean |
|---|---|---|---|
| before planes | 31.2 ms | 37.5 ms | 31.3 ms |
| on planes | 29.0 ms | 36.8 ms | 28.7 ms |

**Planes are slightly faster**, not slower, on a world with one plane. Some
of that is the two whole-section zero-fill loops that stopped existing --
voxelworld and worldgen both filled a new volume with VOXELTYPEID_UNDEFINED,
which is what an unwritten plane already reads as -- and the rest is inside
the noise. Either way the question the plan asked is answered: there is
nothing here to call planes off over.

### What got built, and what did not

Done: the plane list in the format; `VoxelVolume` with lazy per-plane
materialisation; the PolyVox view; serialization format 4 with formats 2 and
3 still loading; planes carried through `merge_volume` into chunks and onto
the wire; `pack_voxel_volume()` writing a field into its own plane;
`set_format` taking a plane list from Lua; bulk `plane_bytes()` in C++.

Not built, and why: **the field registry** -- `world:voxel_field("mod:name",
...)`, the no-questions-asked module-facing half -- because a game declaring
its own planes in `set_format` covers everything that exists, and the piece
that makes the module case work is already there: a chunk takes on whatever
planes reach it and keeps planes it has that the world does not. And **bulk
plane access from Lua**, which waits for the simulation that wants it.

### One thing the port turned out to need that was not in the design

A voxel that is a word can only be asked about that word, and **the look
rules of a world whose materials are a plane of their own are a question
about another one**. So the mesher works in `VoxelSample` -- a voxel's
planes read together -- and PolyVox's extractor is handed a view whose voxel
type is that sample rather than a word. Everything outside the mesher still
sees `getVoxelAt` as the first plane's word, which is what it has always
meant.

## Step 5: aggregate

**The game has a plan of its own now: `doc/plan/aggregate_game_plan.md`**,
which supersedes this section wherever they disagree. What changed in the
writing of it, in one paragraph: the material list is **five, not four** --
`rock`, `sand`, `water`, `fibre`, `binder` -- because applying this plan's
own rule ("a material may not itself be a mixture") to wood splits it into
fibre bound with lignin, and that split is what gives rot something to eat
and soil somewhere to come from. Two state fields join them, `bond` and
`life`, which are states rather than materials because nothing moves when a
plank becomes sawdust or a branch dies. And phase 1 of the game is
**undermine played again on mixtures**, so that the model is the only
variable.

### The materials

**The test a material has to pass: can the game's own processes take it
apart?** If they can, it is a mixture and it does not go in the list. That
rules out the obvious candidate: **dirt is decomposed organic matter mixed
with sand**, and organic matter is itself wood and water. Water washes the
one out of the other, and a model that keeps dirt as a base material is
lying about the exact thing it exists to model.
It also keeps rock in, because nothing a player does separates granite into
its minerals -- the line is what the game can separate, not what is
chemically pure.

**Five**, settled in `doc/plan/aggregate_game_plan.md` and summarised here:
`rock`, `sand`, `water`, `fibre`, `binder`, plus two state fields `bond` and
`life` that are not materials because nothing moves when they change.

Wood is not among them, and that is the point: **wood is fibre bound with
lignin**, so the rule applies to it as much as to dirt. The split is what
pays -- rot is fibre plus water plus time becoming binder, which is
composting, and binder in sand is soil, so the whole cycle is four fields
and one conversion and dirt is derived rather than placed.

See the game plan for what the five make, for the look rules, and for the
storage. The rest of this section is what was written before that plan
existed; where they disagree, it wins.

**"Binder" was a function wearing a material's clothes**, and it is gone
from the list. Cohesion is derived from what is actually there: wood holds
a mixture together and holds a span on its own, water gives sand some and
takes it away again at saturation -- which is why a sandcastle needs damp
sand and collapses when soaked, and that is a rule the model now gets for
free instead of being told. **Cement is the first addition**, and it is what makes concrete;
until it exists, nothing in this world sets hard.

One plane each, eight bits, as a fraction of a full voxel.

### Superseded from here to the end of this step

What follows is how step 5 was sketched before the game had a plan of its
own. It is kept because the shape of it is still right -- everything the
engine asks is a table over a selector, everything the simulation asks is
the game's own arithmetic over the planes -- and because the places where
`doc/plan/aggregate_game_plan.md` departs from it are the places something was
learned. It is not a queue.

### What is derived, and where

Everything the engine asks is a table over a selector; everything the
simulation asks is the game's own arithmetic over the planes:

| property | derivation |
|---|---|
| solid | non-fluid fraction over a threshold |
| empty | everything near zero -- air is the absence of material, not a material |
| density | the fractions weighted by each material's own |
| cohesion | wood, plus what water does to sand: a little damp binds, saturated does not |
| rot | wood that has stayed wet turns into the weak dark thing soil is made of -- a rate rather than a fraction, and the one derived property with a clock on it |
| span, capacity | cohesion times the solid fraction: nothing holding it and it is rubble, which spans nothing |
| opacity | fractions of the things that stop light |

### The simulation

undermine's support and load carry over unchanged in shape, with the
constants derived rather than looked up -- and "nothing holding it together"
*is* a derived span of zero, which is undermine's rubble rule generalised
rather than replaced.

What is new is **migration**: water moves down, sideways and -- under
pressure -- up, through anything porous. This is the first thing in either
game that sweeps a volume rather than relaxing around an edit, so it is
also the first real customer for bulk plane access. It runs on a budget per
tick, over chunks that have anything to do.

Overfilling is pressure. **Decide before writing it**: a fluid compresses
into pressure, and a solid that is overfull is an error to resolve by
pushing material out rather than a compaction. Pick the first; the game is
downstream of it.

### The look

Thresholds choose the base and the four chosen surface modifiers refine it.
Which four the spike decided; **how many bases it decided too**, and its
answer was "more than you think": the base carries nearly all of what a
player can see, so the bases along the rock-to-sand axis want to be three or
four -- rock, gravel, sand -- rather than two, and soil is a base of its own
where the wood is. There is no dirt texture standing for a
material; it stands for a range of one.

### The world

Layered mixtures rather than layered ids: a gradient from rock through
gravel to sand, with wood laid over the top of it so that soil is where the
two meet rather than a layer of its own; ponds as a water fraction rather
than a water material; and pockets of sand. Trees are wood at nearly full,
standing in the same field that is a trace of itself in the soil below. The generator writes
fractions; there is no id to write, and there is no dirt to place -- dig
through the topsoil and what is under it is the same sand with less in it.

## Risks, and what is done about each

- **The mixture does not read on screen.** Answered by the spike, second,
  before anything expensive.
- **Migration is too slow.** It is the one sweeping loop; measure it at one
  material before there are four. If it cannot be afforded at one, it will
  not survive four, and the fallback is coarser time steps and smaller
  active regions rather than a faster loop.
- **Planes cost more than they give.** Measured in step 4 against the games
  that exist, with the check images as the correctness net.
- **The step-3 refactor quietly changes behaviour.** The `FIELD`-only
  sub-step exists precisely so that the refactor and the new capability are
  never in the same commit.
- **Scope.** This is the largest thing in the project. Steps 1 and 2 are
  each a day or two and stand alone; step 3 is a week's shape of work; step
  4 is the big one; step 5 is a game. Stopping after any of them leaves the
  tree better than it found it, which is the property to preserve.

## Not in this plan

- **undermine's phase 4**, water as a quantity with pressure. It is the same
  idea at one material and it would have been the prototype, but undermine
  is frozen and aggregate does it properly.
- **The publish mask and staleness tracking** from
  `doc/plan/voxel_data_model_plan.md`. aggregate should be *built* not to need
  it -- its HUD asks about the voxels it cares about rather than reading the
  volume in bulk -- and then it can be measured honestly.
- **Marching cubes, or any continuous collision surface.** Solidity is
  thresholded and collision stays boxes. That is a position, not an
  oversight.
