# aggregate: voxels as mixtures

The next game. Proposed during undermine's playtesting: drop the material id
entirely and let every voxel hold a portion of each material, with the
number of fields being the number of materials.

**The name.** *Aggregate* is the word for the mix of rock, sand and binder
that concrete is made of, which is literally this game's subject, and it is
also what a vector of fractions is. It reads as a noun for the stuff the
world is made of. Alternatives considered and available: **binder**, which
names the rule that decides whether a mixture holds anything up, and
**slurry**, which is more fun and implies more liquid than the game is.

- Light wood is 50% fibre and 50% air; hard wood is 90%; plywood is fibre
  with more binder in it than a tree puts there itself.
- Overfilling the total is pressure. Under pressure some materials migrate
  -- water does, the things you build with do not.
- Mixed gravel is any amount of rock with any amount of sand, and a voxel
  can be contaminated with a bit of everything. A mixture with nothing
  holding it together is rubble and holds nothing up.

**A material may not itself be a mixture**, and the test is whether the
game's own processes take it apart. That rules out the one everybody
reaches for first: **dirt is decomposed organic matter mixed with sand**,
water washes the one out of the other, and a model with dirt in its base
list is lying about the exact thing it exists to model. It keeps rock in,
because nothing a player does separates granite into its minerals -- the
line is what the game can separate, not what is chemically pure.

It also ruled out *binder*, which looked like a function wearing a
material's clothes -- and then let it back in once there was an answer to
where binder comes from, which is rot. The materials are **rock, sand,
water, fibre and binder**: fibre rather than wood, because wood is fibre
bound with lignin and the rule applies to it too; and not organic matter,
because organic matter *is* fibre and water, that being what fibre turns
into given time and damp. Which is the correction that pays
for itself twice over: the decayed thing comes out of the mixture rather
than needing a field, **you can build with wood**, and rot has something to
turn fibre *into*. Tree, dead wood, rot, soil, tree is one cycle in four
fields.

Cohesion is derived from what is there: binder holds a span, and water gives
sand some and takes it away again at saturation -- a damp sandcastle
standing and a soaked one not, out of the model rather than out of a rule.
Cement is a binder you can make, and is the first addition.

What the model cannot say by composition alone is **how finely divided a
material is**: a plank and a heap of sawdust are the same fibre and the same
binder. That is what `bond` is for -- how continuous the solid is, which
falling destroys and growing and curing make. What stays unsaid, and
deliberately, is grain size: fluffy sand and packed sand are one sand
fraction, and the look spike says to take that loss, since they look the
same in life too, which is why sand is dangerous.

## Why it is a second game and not undermine's next phase

**undermine is frozen as of this decision** -- see the master plan -- and
this is a new game rather than its next phase. Three reasons, in order of
how much they matter:

1. **undermine is the evidence.** Its value in `doc/plan/master_plan.md` is
   that it is a real consumer that exercised the voxel format and produced
   numbers -- 902 packets to 366, twenty of thirty-two bits, what adding a
   field costs. Rewriting it onto a different data model would conflate two
   experiments and destroy the first one's results.
2. **It cannot be built on the engine that exists, and undermine can.**
   See below: a composition model needs planes, and planes are not built.
   Making a working game depend on unbuilt engine work stalls the game.
3. **They are different games to play.** undermine is about spans and props:
   discrete, legible, teachable in under a minute, and its fun is a cascade.
   A mixture model's interest is systemic -- contamination, binders, what a
   pile of stuff can hold -- which is slower and wants a different kind of
   attention. Both are good; neither is the other's better version.

## What this gives luanti_client, which is part of the envelope

Worth stating because it stops this being one game's feature. Both modifier
roles land squarely on things the Luanti client pays for today:

- **tint** is the palette. A palette entry currently costs a voxel type with
  its own composed, tinted textures and its own atlas segments -- the one
  thing stage 1 could not remove, and the reason the (definition, param2)
  pair machinery still exists there at all. An albedo tint per voxel removes
  it outright.
- **sag** is the flowing liquid level, which is a per-voxel number reached
  through a variant table today.

So the work below is not speculative even if aggregate is never built.

## Why this is the first proposal that genuinely needs planes

Everything else in these documents has fitted in a 32-bit word, and the
width argument has repeatedly turned out to be the weak one. This does not
fit and cannot be made to:

- **N materials is N fields.** Eight materials at a byte each is sixty-four
  bits a voxel before light, pressure or anything else. Sixteen materials is
  a hundred and twenty-eight. There is no cut of one word that expresses it.
- **The simulation sweeps.** Migration under pressure reads and writes one
  material's field over a whole volume, in order, repeatedly -- which is the
  structure-of-arrays argument's ideal customer, and the first one there has
  been. Interleaved, every pass pulls the whole mixture to touch one
  component of it.
- **Lazy materialisation stops being an optimisation and becomes the thing
  that makes it affordable.** Eight bytes a voxel over a world is hundreds
  of megabytes -- but almost every chunk is entirely one material, or
  entirely air. A chunk that is pure rock should carry *no* planes and
  answer from defaults, and a plane that is one value everywhere should cost
  one byte. That is in the design note already
  (`doc/plan/buildat_voxel_data_model.md`, "Lazily materialised per chunk"),
  written as a nicety; here it is load-bearing.

So: if this game is wanted, it is the argument for stage 2, and a much
better one than anything undermine produced.

## The hard part, which is not the storage

**The engine finds everything through the voxel id.** Textures, shape,
`physically_solid`, whether light passes, what the mesher culls against --
all of it is `get_cached(id)` today. A voxel that is a mixture has no id.

An early draft answered this by having the game derive an id and store it, a
redundant byte that kept the engine stupid. The better answer is in the
choices below: **the engine asks each question through its own selector and
table**, and the id becomes one selector kind among several rather than the
only way in. A game that wants the id-only path keeps it, unchanged and
undegraded.

What remains hard, and no amount of data model fixes it: **a mixture has to
look like something, and dominant-material-plus-tint will look muddy** for
genuinely mixed voxels. That is the thing to prototype before any
simulation, because it decides whether the game reads at all. A screen of
grey-brown mush is a failed game whatever the physics underneath is doing.
The modifier list below exists mostly to answer this: grain, speckle and
gloss are what make two mixtures of the same colour look like different
materials.

## What carries over from undermine

More than might be expected, and this is the encouraging part:

- **Support and load work unchanged.** They are per-voxel numbers with
  per-material constants; the constants become derived from the mixture
  rather than looked up. `span`, `density` and `capacity` are then functions
  of the composition -- and "nothing holding it together" is a derived span of
  zero, which is undermine's rubble rule generalised rather than replaced.
- **The three views work unchanged**, and gain company: a view per material
  fraction is the same machinery.
- **Phase 4 of undermine is this game with one material.** Water as a
  quantity with pressure, migrating between voxels, seeping through porous
  things -- that *is* the composition model at N = 1, on the engine as it
  stands. If it is fun there it will be fun here, and if the flow simulation
  is too slow at N = 1 it is not going to survive N = 8.

That last point is the whole recommendation: **build phase 4 first.** It is
a day's work on an engine that exists, it answers the interesting questions
about flow, pressure and whether a fluid reads on screen, and it is the
prototype for this without being a commitment to it.

## The parameterized mesher

What all of this adds up to, and the name for it: **a parameterized mesher,
as an alternative to the plain fast one.** PolyVox's cube extractor plus an
id-indexed definition is the right answer for a world of plain solid voxels
and should stay exactly as fast as it is. Next to it, a mesher that catches
the wider envelope of what a voxel can be -- a mixture, a partial fill, a
surface whose character is a number rather than a texture.

**Semi-generalized**, deliberately: the set of modifiers is hardcoded and
parameterized, not a language. That is what keeps it fast and what lets the
set grow as buildat's envelope grows without any existing game paying for
the growth. A game picks the modifiers it uses; the ones it does not use are
hoisted out of the loop before the loop starts, exactly as the param lookup
already is.

### Terminology

**Not "mesh modifier"** -- half of them do not touch the mesh. The vocabulary
that already exists in the voxel format is *field* (bits in a voxel) and
*role* (a meaning the engine understands for some bits). These fit there:

- a **data role** is one the engine reads as fact -- `id`, `light_sky`
- a **modifier role** is one the mesher applies as an effect -- `sag`, `tint`

and modifier roles come in two families: **geometry modifiers**, which move
vertices, and **surface modifiers**, which travel to the shader and change
how a surface is lit and textured. One word, "role", for the binding; one
word, "modifier", for what it does. Proposed as final unless something
better turns up in use.

## A mesher with no voxel id: the choices to make

The requirement: *the mesher works out what a voxel looks like without being
given an id.* Below is what an implementation plan has to settle, with a
recommendation on each.

### 1. Per-property tables, each with its own selector

The first draft of this section said "keep `VoxelDefinition` as the unit and
change only how one is chosen". The better answer, from the playtest
discussion: **there is no reason the four consumers have to agree.**

`voxelworld` wants to know whether light passes. The physics wants to know
whether it is solid. The mesher wants to know what to cull against, and what
it looks like. Those are four questions, and a mixture answers them from
different parts of itself -- solidity from how much non-fluid it holds,
opacity from something else entirely.

So: **one table per property, each with its own selector.** A selector turns
a voxel word into a small integer key; the table maps the key to the answer.

    transmits_light : selector -> key -> bool
    physically_solid: selector -> key -> bool
    edge_material   : selector -> key -> uint8
    look            : selector -> key -> definition

A `VoxelDefinition` stops being the unit the engine looks things up by and
becomes what the *look* table holds -- which is exactly what it is for.

### 2. Does this cost the id-only case anything? No, and here is why

The question that decides whether this is acceptable at all: does a Luanti
client, which wants the id and wants it fast, get slower?

A selector is one of a small closed set of kinds:

- `FIELD` -- key is a field of the voxel: a shift and a mask. **This is
  today's cost exactly**, and it is what every existing game uses for every
  property.
- `QUANTISED` -- key is several fields cut to a few bits each and packed:
  a handful of shifts, masks and ors.
- `RULES` -- an ordered list of `{field, lo, hi}` conjunctions, first match
  wins, behind a memo keyed by a `QUANTISED` tuple. The rules run once per
  distinct mixture per chunk rather than once per voxel; a chunk of uniform
  rock runs them once.

The kind is a per-world constant, so **every loop hoists its selector before
it starts**, the same way the mesher already hoists the voxel format. What
is left inside the loop is the same shift-mask-index it does today, with the
branch outside it. The `FIELD` case can be a specialised loop instantiation
if measurement ever says the hoisted branch matters.

What actually costs something is `RULES`, and only for the game that chooses
it -- which is the right place for the cost to land.

### 3. Where the boundary between solid and fluid lives

Asked directly, and it is the question a mixture model has to answer:
there is no field that says "solid". Air at atmospheric pressure is a very
thin, very light fluid; saturated gravel is solid *and* has water flowing
through it.

Where it leads, and this is a design position rather than a detail:

- **Solidity is a derived scalar, thresholded.** The game's table says
  "non-fluid fraction above this and it is solid". The engine never knows
  the derivation; it asks the physics table through a selector like anything
  else. Air stops being a material and becomes the case where every fraction
  is near zero.
- **Collision stays boxes on a threshold, and the look stays continuous.**
  The alternative -- collision as an isosurface of a continuous solidity --
  is marching cubes, a different engine, and not what buildat is. Coarse
  collision under a fine-grained appearance is the normal answer and a
  defensible one.
- **"Empty" is a threshold too.** `fully_empty`, which `merge_volume()` uses
  to decide whether generated terrain may overwrite something, becomes
  "nothing much in it" rather than "is air".
- And the good part: **buoyancy and pressure fall out of density
  differences** rather than needing a rule. A thing floats when what is
  under it is heavier, which the mixture already says.

### 4. The shader contract, and games writing their own

The engine's job is to define what a vertex carries; what a surface *looks*
like is the game's. buildat ships shaders in `builtin/voxel_shading` and
sample games ship their own, and those act as references whether or not
they are called that -- so the honest framing is not "do we ship a reference
shader" but **"what is the contract they are all written against"**.

Today that contract is: position, normal, texture coordinate into the atlas,
and a colour that is light in the split `interface/mesh.h` documents.

What is added: **one `Vector4` of normalised per-voxel strengths.**
`CustomGeometryVertex` already carries a `tangent` the voxel mesher never
writes, and `DefineGeometry()` has the switch that uploads it. Voxel faces
are axis-aligned, so a normal-mapping shader derives its tangent from the
normal and does not need the slot.

**The limitation, stated plainly: four scalars.** That is the reasonable
limit `CustomGeometry`'s fixed vertex struct allows, and going past it means
the mesher writing its own vertex buffer instead of using `CustomGeometry`
-- which is the same change that would let it use an index buffer, so there
is a natural moment for both.

Four is less generous than it sounds, which forces one good decision:
**colour is not carried per voxel.** An RGB tint would eat three of the
four. Instead a tint modifier carries **one** scalar and the *definition*
holds the ramp -- two colours to lerp between, or a small palette to index.
That covers Luanti's palettes, wet soil darkening, and a mixture's colour,
costs one slot, and is friendlier to the shader than unpacking bytes out of
floats would be.

### 5. A preliminary list of modifiers

Geometry modifiers, which move vertices at mesh time:

| role | what it does | driven by, in these games |
|---|---|---|
| `sag_top` | moves the top face down, blended across the four voxels meeting at each corner | a liquid's level; a loaded ceiling bowing |
| `sag_bottom` | the same for the bottom face | a solid sagging as a whole; a liquid perched on air, which physics will produce sooner or later |
| `jitter` | a deterministic per-voxel nudge of the whole voxel | rubble and gravel, so a pile does not read as a grid |
| `inset` | pulls the side faces in | a voxel that is nearly gone; a thin layer |

`sag_top` and `sag_bottom` are separate rather than one `sag` with a split,
because the cases genuinely differ: a liquid sits on the floor and only its
top moves, a sagging slab moves both, and a floating liquid moves both by
different amounts. `liquid_top` is `sag_top` with a discrete driver, and
should become it.

Surface modifiers, which travel in the payload and are the shader's to
interpret:

| role | what it suggests | driven by |
|---|---|---|
| `tint` | lerp the albedo along the definition's ramp | a palette index; how wet; which way a mixture leans |
| `wetness` | droplets over the surface, and a wetter reflection | water in a porous voxel |
| `grain` | the frequency and depth of the normal perturbation -- fine for sand, coarse for rock | which mineral dominates |
| `gloss` | smooth normal, strong reflection | glue, resin, anything moulded |
| `speckle` | static reflective flecks, size with the value | rock content large, sand content small |
| `emission` | glow | lava, and anything a game wants to light itself |

Six surface modifiers against four slots is deliberate: **a game picks four**,
and the ones it does not pick cost nothing.

Which four aggregate wants is answered, and the answer is **two**: `tint` and
`wetness`, both of which the look spike found read at a glance, plus
`sag_top` on the water fraction, which is a geometry modifier and does not
count against the four. Two surface slots stay unbound, because the spike
found `grain` does not read at all and `gloss` reads weakly -- and spending
a slot on either would be spending it on nothing.

### 6. Where the rules run -- BUILT

Not only in the mesher. The light flood, `merge_volume()` and the physics
all ask per-voxel questions on the *server*, where there is no mesher at
all. **Selector and table evaluation belongs in `interface/`, beside the
registry**, as one shared cached lookup that the mesher, `voxelworld` and
the physics all call. Deciding this early is what keeps it from being
written twice and diverging.

### 7. Planes: aim for them from the start -- BUILT, and they are faster

The first draft recommended four materials in one 32-bit word, to get the
look pipeline working before the storage changed, with the non-plane version
as a performance baseline.

**Overruled, and rightly.** The comparison is the only thing that version
buys, and the feature set at four materials in a word is not one anybody
would be happy with -- so the baseline would be measuring something nobody
wants to ship. Planes are only abandoned if their performance is unusable,
and that will be obvious from the plane version alone.

So stage 2 of `doc/plan/voxel_data_model_plan.md` stops being a blocked item
and becomes part of this step. Its design is written; what it needs is the
plane view over PolyVox (answered: the extractor wants only `getVoxelAt` and
an unused `Sampler` typedef), the field registry, lazy per-chunk
materialisation, and format 4 on the wire.

Built, and the measurement came out the other way from the worry: **meshing
on planes is slightly faster than it was on one word** (median 29.0 ms a
chunk against 31.2, on digger), partly because two whole-section zero-fill
loops stopped existing -- an unwritten plane already reads as zero. The
field registry is the one piece deliberately left unbuilt, having no
consumer: a game declares its planes in `set_format`, and a chunk already
takes on whatever planes reach it.

### 8. What the client receives -- BUILT

Selectors, tables and modifier bindings all have to reach the client, and the
registry already travels there and already carries a version byte from stage
1. **Extend the registry's serialization**, bump the version, refuse a
mismatch with a message as it already does.

## The questions this note left open -- all three answered

The game's own plan is `doc/plan/aggregate_game_plan.md`; these are the three
things this note said to decide deliberately, and what they were decided as.

- **What does overfilling mean for a solid?** *An error, resolved by pushing
  material out.* Not a compaction -- because **compaction is the step before
  it**, and by the time a voxel is overfull it has already happened. That
  ordering is the part worth having: loose material under load first packs
  down, each material to its own limit, and only then does anything have to
  leave. Water goes first, being the mobile one.

  With a detail that makes it worth simulating rather than asserting: **sand
  and gravel still hold water when fully compacted**, because the grains do
  not fit together and voids are left between them. So the void a material
  keeps is the material's own number, not one constant -- ~0.35 for sand and
  gravel, ~0.10 for wood, ~0 for a binder that has set.

- **How many materials?** *Five*, and picked by the rule rather than by
  counting: `rock`, `sand`, `water`, `fibre`, `binder`. The fourth draft said
  "wood"; applying this note's own rule to it splits it, because **wood is
  fibre bound with lignin and is therefore an aggregate like everything
  else**. That split is what pays: rot is fibre plus water plus time
  becoming binder, which is composting, and binder in sand is soil -- so
  tree, dead wood, rot, soil, tree is one cycle in four fields, and dirt is
  derived rather than placed. Four materials could not reach that.

  Two fields join them that are **not** materials, because nothing moves
  when they change: `bond`, how continuous the solid is, which is what
  falling destroys; and `life`, whether the fibre here is alive, which is
  what makes leaves and sawdust different voxels.

- **What is the unit?** *Four bits a solid, eight for water.* The look spike
  says two bits is enough for what is seen, because what a player can read
  is which side of a threshold a mixture is on and not where in the range it
  sits -- so **the look is out of the argument about how wide a voxel has to
  be**. What is left is the arithmetic, and the one that has to conserve is
  water: sixteen levels cannot carry a flood without losing it.

  If sixteen levels turn out too coarse for a solid once material starts
  moving, widening that plane is a format change and not a rewrite. Reach
  for it first rather than designing around it.
