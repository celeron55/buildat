# Implementing the voxel data model

The executable half of `doc/plan/buildat_voxel_data_model.md`: the interfaces,
the order, and the migrations. Read the design note first for *why*; this
file is only *what changes, in what order, and what breaks*.

Kept out of git (`/local`) like the note, until it is decided.

## The one decision that shrinks the whole diff

**The format lives in the `VoxelRegistry`.** Not passed alongside the volume,
not a parameter on 51 signatures.

The registry is already exactly the right object: one per world instance
(`CInstance::m_voxel_reg`, so several worlds already work), already handed to
every mesher entry point beside the volume, already serialized to clients
(`voxelworld:voxel_registry`), already the thing a client deserializes before
it can draw a chunk. A volume plus its world's registry is self-describing,
and the registry is where "what does a voxel word mean" belongs next to "what
does voxel id 7 mean".

So `mesh.h` keeps its signatures. `voxelworld`'s API keeps its signatures.
What changes is that the hardcoded masks in `VoxelInstance` and the mesher's
uses of them go through a format the game set.

Cost of that choice, stated plainly: the format must be set **before the
first voxel is added and never after** -- one `set_format()` that asserts on
a non-empty registry. A world does not renegotiate its layout at runtime.

## Stage 1: a bit cut the game picks -- DONE

Built on the `voxel-format` branch, ten commits, client migration included:

- `51f3d39` VoxelFormat and its self-test
- `dce4a68` the format in the registry, serialized to clients
- `31bf398` the mesher reads through it
- `0a98cdf` pack_voxel_volume's fields are roles; set_format in Lua
- `51c0f48` voxelworld's skylight in the bits the format says
- `794cf7d` VoxelVariant: a definition says what its param means
- `5a30b30` what a variant colour tints, which is the light
- `d191950` cast_voxel_rays reads the id and light through the format
- `f1f1467` luanti_client: param2 reaches the mesher

What was done differently from the plan below:

- **No `Instance::set_voxel_format()`.** `Instance::get_voxel_reg()` is
  already public and the registry already refuses a late format, so the
  wrapper would have been a second way to say the same thing.
- **`VOXELTYPEID_MAX` is not a mask.** It is 1398100, which is not
  2^21 - 1, so the id rule is the field's width (at most 21) and the
  registry stays what refuses an id above the cap. The self-test found this
  on its first run, by rejecting `legacy()`.
- **`VoxelRegistry::get_by_id()` cannot be called from Lua at all** --
  luabind will not take its `const VoxelTypeId&` from a number. Pre-existing
  and unused; noticed while writing the variant check, left alone.
- The engine keeps `pv::RawVolume<VoxelInstance>` and the 51 signatures,
  as intended. `generate_voxel_lod_volume()` gained the registry, for the
  format alone.

The client migration is done under decision 1 below: it sets Luanti's cut,
packs param2 as the param, and `build_variants()` turns what param2 says
about a voxel's shape into variants of one voxel type. A facedir is 23
variants instead of a voxel type per (definition, param2); a palette entry
is the one thing that still costs a voxel type. `world.self_test()` checks
the variant mapping at boot.

**Checked on a turned node**, in the end: three `testnodes:facedir` cubes
placed through the client's own input in `buildat_test_testgame` at
(200, 12, 200), then the same view rendered by the commit before the
migration and by the migration. The visible face wears the same tile with
the same turn in both, which is the thing that would have broken. That spot
is unlit -- it is a dark part of that world, in the old client too -- so the
images had to be brightened to compare; VoxeLibre at spawn is the lit
smoke test and is unchanged.

### The blocker: a colour has nowhere to go but the light

A variant's `color` is multiplied into the vertex colour, which is what the
design note said to do and what the plan wrote down. Building it made clear
that this is **not** enough for a palette, and the reason is worth writing
down before anyone tries again.

The vertex colour does not carry an albedo. It carries light, in the split
`interface/mesh.h` documents and `VoxelUnlit.glsl` implements:

    ambient   = cAmbientColor.rgb * vColor.a + vColor.rgb
    fragment  = texture.rgb * ambient

`vColor.rgb` is the light that reaches the surface regardless of the sky and
`vColor.a` is how much of the sky it sees -- a scalar, so it cannot carry a
hue. Multiplying a tint into `vColor.rgb` therefore tints only the part of
the lighting that does not come from the sky: a tinted grass block in full
sun comes out untinted, and the same block in a cave comes out tinted. That
is not a palette, it is a bug with a plausible screenshot.

Luanti's palette is a multiply against the *texture*, so it needs to reach
`diffColor`. Three ways, and this is the decision:

1. **Leave palettes as they are.** Variants cover the param2 uses that are
   geometry -- facedir, 4dir, wallmounted, and a flowing liquid's level --
   and a palette entry keeps needing a voxel id with its own composed,
   tinted textures, exactly as today. The client's pair machinery stays but
   its cache key loses the facing and the liquid level, so the pairs (and
   the definitions, at 368 bytes each) collapse to one per (definition,
   colour) instead of one per (definition, param2 that means anything).
   Cheapest, no dead end, and it is honest about what the vertex format can
   hold.
2. **Give the mesher an albedo channel.** `CustomGeometryVertex` is 52
   bytes -- position, normal, colour, one texture coordinate, and a
   `tangent_` Vector4 that the voxel mesher does not write. Put the tint
   there and have the voxel shader multiply `diffColor` by it. Correct, and
   it makes `color` a real role rather than a half one. The cost is that the
   tangent is what a PBR path wants for its normal maps, so this trades one
   spare channel for another want; `builtin/voxel_shading`'s PBRVoxel is the
   thing to check before choosing it.
3. **A second vertex colour**, which means a vertex format of the mesher's
   own instead of `CustomGeometry`. That is the right end state and a much
   bigger change: `CustomGeometry` cannot hold an index buffer either, which
   is a cost the mesher already pays (see the `#if 0` block in
   `generate_voxel_geometry`). Worth doing together, not for a tint alone.

**Decided: 1.** Palettes stay on their per-colour-voxel path. 3 is the
eventual end state and belongs with the index buffer; 2 is a measurement to
make rather than an assumption. `VoxelVariant::color` means "tints the
light", which is right for a voxel that emits or sits in coloured shade and
wrong for a palette, and the client does not use it.

### What the migration does once that is settled

- `voxel_reg:set_format` with Luanti's cut: id 0...15, sky 16...19, lamp
  20...23, param 24...31.
- A `field = "param"` source per block and per neighbour slice, replacing
  the second pass with `second = {...}` and `PAIR_SCALE`.
- `build_voxel()` grows the variants for a definition: one per distinct
  (facedir, wallmounted direction, liquid level) that any param2 comes to,
  with the param values it claims.
- `VOXEL_AIR_LIT` moves: the sky light is at bit 16 now, not 24.
- Anything reading a volume back in Lua stops using `VoxelInstance:get_id()`,
  which is the default cut and would read light and param as part of the id.

## The generalization: modifier roles

Asked after undermine made wet dirt a material of its own: the user did not
like a voxel type existing only so that the mesher could see something, and
wanted instead to *subtly modify the look* of dirt by how wet it is -- and,
in the same breath, to modify the *mesh*, sagging a voxel downward by how
loaded it is. What does that generalize to?

**It generalizes to the mesher already having two of these and reaching them
the wrong way.**

- `VoxelVariant::color` is a per-voxel colour modifier.
- `VoxelVariant::liquid_top` is a per-voxel *geometry* modifier -- a vertical
  displacement of the top face, with the corner averaging in
  `liquid_corner_top()` already blending it across neighbours.

Both exist, and both are reachable only through `param` -> `variant_of_param`
-> a variant. That indirection is a **discrete lookup**, which is exactly
right for a discrete thing -- twenty-four facedirs, four rail shapes -- and
exactly wrong for a continuous one. Wetness is a number between none and
soaked; sag is a number between flat and bowed. Expressing those through a
table costs an entry per value, and worse, costs a whole `param` to itself,
which is why wet dirt became a material instead.

### The shape

A small closed set of **modifier roles**, each a per-voxel scalar that drives
one named, bounded visual effect, with the *definition* saying how much:

| role | what the mesher does | what the definition supplies |
|---|---|---|
| `tint` | lerp the vertex colour toward a colour, by value/max | the colour at full |
| `sag` | move the voxel's top face down, by value/max | the distance at full |

Read N bits, normalise to 0...1, one multiply-add per voxel. No table, no
entry per value, and several can apply at once and compose with the param's
variants. `liquid_top` becomes the special case of `sag` that it always was.

Then wet dirt is dirt with `tint` bound to the moisture field and a wet
colour on the definition, darkening continuously, and no voxel type exists
for the mesher's benefit.

### The part that makes it cheap, and it is not obvious

**A modifier role can point at bits that already mean something.** Roles are
`{plane, shift, width}` views onto storage, and the engine only ever *reads*
them -- the game writes. So `sag` can be bound to the same nibble the load
already lives in, and `tint` to the moisture nibble, and neither costs a bit.

`VoxelFormat::validate()` currently refuses overlapping roles. That rule was
written for fields the engine might write and it is wrong for these: it
should forbid overlap only where it would be ambiguous -- `id` with anything
-- and allow a modifier to alias a field a game already keeps. One of the
cheaper changes in this document, and it is what turns "another modifier"
from "another eight bits" into "another way to read eight bits you have".

### The tension to write down before anyone builds it

**A field that is visible is a field that is expensive.** Sag driven by the
load means every load change moves geometry, so every load change dirties
the mesh -- which is the exact opposite of the mask in the next section,
whose whole point is that simulation fields do not. You can have a field be
cheap or expressive, not both, and that is a choice per field rather than a
thing to solve.

Sag is also the more invasive of the two: the mesher would displace vertices
per voxel on the cube path, which today is PolyVox's output taken as it
comes. The shape path already displaces (that is `liquid_corner_top`), so
the model is there; the cube path is where the work is.

## Adjacent: what a chunk publishes, and when

Not part of the data model, and the thing the data model kept being blamed
for. undermine measured 902 chunk-changed packets for one building placed
and settled, where what changed appearance happened once; its phase 2 works
through why planes do not fix that. This is what does.

**The rule worth aiming at: the server publishes what the client can
perceive, and answers for the rest on demand.**

### Which changes are perceivable, and that part is free

It needs no new declaration from anybody, because the format and the
registry already say it:

- the **id** bits: always
- the **light** bits: while the world maintains light
- the **colour** bits: while the colour role is bound
- the **param** bits: while any definition has variants -- which is the same
  test the mesher already makes when it hoists the param lookup out of its
  inner loop

Everything else in the word is a game's own simulation state and cannot
change the picture. A mask of those bits, and a comparison of the voxel
before against the voxel after, is perhaps twenty lines in
`voxelworld::set_voxel()`.

### Where the mask alone is wrong

A field that cannot change the picture *today* can change it tomorrow: the
client switches to a view that reads it, and its copy is stale. The user's
shape for this, which is right, is two mechanisms rather than one.

**1. Three classes of change, not two.**

- **Perceived now** -- publish at once, as today.
- **Perceivable later** -- what a view that is not on would read, or a
  client feature that is not active. Publish, but behind the first class,
  and coalesced: several ticks of a settling simulation become one
  publication.
- **Never perceivable** -- nothing on the client can ever read it. Do not
  queue at all.

The catch is that **the class is not a property of the field.** It depends
on what the client is doing, and the server does not know that: the stress
view is a client-side registry swap that the server never hears about. So
the client has to declare its interest -- one small packet, the shape the
game already uses for its own -- and the third class only exists relative
to that declaration.

**2. What deferring actually means.** The server's own volume stays current
always; what is deferred is *publishing* it. Today publishing is writing the
serialized volume into the chunk node's `buildat_voxel_data` Var, which is
what Urho3D's replication picks up, so "lower priority" is "write the Var
later" rather than anything in the network layer. Two consequences worth
writing down before anyone builds it:

- **Saving has to flush first**, because that same Var is what a saved
  scene holds.
- **A slow flush timer -- every few seconds -- bounds staleness for
  nothing**, and means a mode change usually finds little to catch up on.
  Worth having before anything cleverer.

**3. Tell the client what is stale, per chunk and per field.** The server
knows which field it just wrote, so it can keep a **bitfield per chunk of
"which fields have changed since this chunk was last published"** and send
that to the client. A field per bit, eight or sixteen bits a chunk: next to
nothing.

This is better than letting the client infer staleness from what it has
received, which is what an earlier draft of this section proposed, and the
reason is worth stating. Inference cannot tell "this chunk did not change"
apart from "this chunk changed in a field I was not sent", so a client
switching views has to treat **every** loaded chunk as suspect and wait for
all of them. Being told, it knows that twelve of four hundred are behind. The
catch-up stops being a burst and becomes a handful of chunks, which removes
the need for the republish-everything fallback that was here.

Three properties that make it cheap, and they are the design:

- **It is edge-triggered.** A chunk's load field goes stale once and stays
  stale until the chunk is published, however many times the simulation
  writes it. So the traffic is on the order of chunks times fields per flush
  cycle, not writes -- which is the whole problem restated as something
  small.
- **Send the whole current mask rather than a delta.** Same size,
  idempotent, and a client that missed one is corrected by the next.
- **One mask per chunk, not per peer.** It clears when the chunk is
  published, and a publication reaches every peer observing that node, so
  one mask serves all of them. A peer that arrives later gets the chunk
  fresh and has nothing stale. That is the per-peer bookkeeping avoided
  rather than deferred.

**Why per field and not one "this chunk has hidden changes" bit**: a client
in the load view does not care that the moisture field is behind. With one
bit it waits for chunks it has no use for. The distinction starts paying as
soon as there are two non-visible fields, which is undermine after phase 3.

**4. The client asks for what it wants first.** With the mask it can name
the chunks it needs refreshed -- the ones it is looking at, and the ones it
predicts it will be looking at -- and the server moves those up the
deferred queue. voxelworld's client already keeps a spatial update queue
with weights, so what to ask for first is a list it can already produce.
Being wrong about a prediction costs one chunk's resend, which is what the
queue is for.

**5. And it should show what it has not got.** A view that dims a chunk
whose field it is still waiting for is the honest presentation, and honesty
is the point here: the bug that started this whole thread was a view that
looked confident and was wrong.

**What the mask also tells a client is which strategy to use.** Stale in
bulk, for a view, means wait. Stale for a feature that needs a handful of
voxels to be right -- the creak -- means do not wait, ask. That is the same
conclusion as the precondition below, arrived at from the other end.

### What this has to do with planes, which is more than it looks

The tracking is **independent of planes** -- it is a mask over fields, and a
field is a bit range today and a plane later. Build it now over bit ranges
and it carries over unchanged, which is an argument for doing it now rather
than waiting. A plane *is* a field, so the granularity is per plane from the
start rather than the wholesale "this chunk's planes are behind" that a
first pass at planes would probably have settled for.

But there is a difference, and it is the first argument for planes in any of
these documents that survives being looked at hard:

**With one word, the mask is informative. With planes, it becomes
actionable.**

Knowing that only the load is stale does not reduce what has to be sent
today: the chunk is one array of 32-bit words, so the client receives all of
it or none of it, and a mask of one field costs the same resend as a mask of
all of them. With planes, the same mask names a slice -- send the load plane
of this chunk, one byte per voxel instead of four -- and the transfer shrinks
to the thing that actually changed. For a simulation writing one 8-bit field
over a 32-bit word, that is a four-fold cut on exactly the traffic that
started this.

What it costs, so that this does not get quoted as free: chunk data reaches
the client today as one serialized blob in a scene node's Var, carried by
Urho3D's own replication. A per-plane send is not a smaller Var, it is a
**different channel** -- an engine or game packet, with its own ordering
against the replicated scene, and a client that has to splice a plane into a
volume it already holds. That is a real piece of work and it is downstream
of everything else here.

So the order stands: the mask first, over bit ranges, because it is useful
on its own and it is what tells us how much traffic is really left. If what
is left is dominated by "the whole chunk resent for one field", that is the
measurement that makes planes worth building, and it will be a number rather
than an argument.

### The precondition, which undermine does not meet -- and undermine is frozen

Left as written, because the point generalises: a client that reads a
simulation field in bulk makes the publish mask useless, whatever the field
is stored in. aggregate should be built not to do that from the start --
its HUD and any warning it grows should ask about the voxels they care
about rather than reading the volume.

The original note follows.

### The precondition, which undermine does not currently meet

None of this buys anything for undermine as it stands. Its HUD reads the
load out of the client's copy of the volume, and its creak reads the
support the same way, so for this client those fields are perceived *now*,
continuously, everywhere -- and the mask correctly concludes that every
write must be published.

So the first move is not the mask. It is to stop reading simulation state
in bulk for things that need it one voxel at a time: the HUD wants the
voxel under the crosshair and the creak wants four above the player's head,
which is a query and a round trip, not a replicated field. Do that and the
simulation's fields become view-only, which is the case all of the above is
designed for. Skip it and the mask is correct and useless.

## Stage 1, as planned

Nothing about planes yet. The word stays one `uint32_t`; the game says where
the fields are inside it. This is worth doing first because it is most of the
discipline and almost none of the risk, and because **it already covers the
cases that hurt today**: Luanti's 16 + 8 + 8 fits a 32-bit word exactly, and
a painter's RGBA is 32 bits with no id.

### The type

```cpp
// interface/voxel_format.h
struct VoxelField {
    uint8_t plane = 0;      // always 0 in stage 1
    uint8_t shift = 0;
    uint8_t width = 0;      // 0 = the role is not bound
    uint32_t mask() const { return width >= 32 ? ~0u : ((1u << width) - 1); }
    bool bound() const { return width != 0; }
};

struct VoxelFormat {
    VoxelField id, light_sky, light_lamp, param, color;
    uint8_t plane_bits[1] = {32};
    static VoxelFormat legacy();   // id 0..20, sky 24..27, lamp 28..31
    static VoxelFormat luanti();   // id 0..15, sky 16..19, lamp 20..23, param 24..31
    bool validate(ss_ *why) const; // no overlap, fits its plane, id bound or
                                   // color bound, id width <= 21
};
```

`VoxelFormat::legacy()` is the default, so a game that says nothing gets
today's layout **bit for bit** and nothing migrates. That is the property to
protect through the whole stage: `git stash` the game changes and every saved
world still loads.

### The accessors

`VoxelInstance::get_id()` and friends are hardcoded masks, inlined, and in
the hottest loop there is. They do not gain a format argument. Instead:

- `VoxelInstance` keeps its methods, **deprecated**, meaning "the legacy
  format's cut" and used only by code that has been checked to be
  legacy-only. Grep shows the users; there are not many outside the mesher.
- The mesher and anything else per-voxel hoists the fields into locals once
  per chunk -- `const VoxelField id_f = fmt.id;` -- and does
  `(w >> id_f.shift) & id_f.mask`. That is what the design note means by
  specialising the loop rather than the API.
- `VoxelRegistry::get_cached(const VoxelInstance&)` is the one place that
  silently assumes the cut today. It has the format, so it just uses it.

### The sites

Order within the stage, each step compiling and passing on its own:

1. `interface/voxel_format.h`, `VoxelFormat::validate()`, and a self-check
   (below). Nothing uses it. **Commit.**
2. `VoxelRegistry::{format, set_format}`, serialized at the front of the
   registry with a version byte; deserializing an old registry yields
   `legacy()`. `get_cached(VoxelInstance)` reads the format. **Commit.**
3. `src/impl/mesh.cpp`: the id reads (`IsQuadNeededByRegistry*`,
   `generate_voxel_shapes`, `occludes`, `connects_to`, `liquid_corner_top`,
   `preload_textures`, the LOD generator) and the light reads
   (`face_vertex_colors`, the shape path's per-voxel light) go through
   hoisted fields. Behaviour identical under `legacy()`. **Commit.**
4. `pack_voxel_volume()`: `field` becomes a **role name** rather than a bit
   range. "id", "skylight", "lamplight", "light", "raw" keep working and keep
   meaning what they mean; "skylight"/"lamplight" resolve through the format,
   "light" means both light roles when they are adjacent and errors when they
   are not, "raw" stays all 32 bits. New names: "param", "color". A source
   whose field names an unbound role is an error with the format in the
   message. **Commit.**
5. `builtin/voxelworld`: `Instance::set_voxel_format()` before generation
   starts, and the skylight maintainer reads the light fields from the format
   instead of `VoxelInstance::set_skylight()`. Refuses if a section is
   already loaded. **Commit.**
6. Lua: `voxel_reg:set_format{...}` in the client sandbox and the server's
   registry bindings, taking the same table shape the note uses. **Commit.**

### The param role, which is the contested part

A bound `param` reaching the mesher is useless unless a definition says what
it means, and the design note's rule is that games do not get to define
things the mesher has to interpret. The closed answer:

**A definition holds a param-indexed variant table.**

```cpp
struct VoxelVariant {           // what a param value changes about drawing
    sv_<VoxelQuad> shape;       // empty: the definition's own shape
    uint8_t tile_order[6];      // which of the 6 textures each face wears
    uint8_t tile_turns[6];
    uint32_t color = 0xffffffff;// multiplied into the vertex colour
    float liquid_top = 0.5f;
};
// in VoxelDefinition / CachedVoxelDefinition:
sv_<VoxelVariant> variants;     // empty: param is ignored for drawing
uint8_t variant_of_param[256];  // param -> index into variants
```

Two levels, so the common cases stay small: facedir is 24 variants behind
256 bytes of index, a palette is 8, `paramtype2 = "none"` is an empty vector
and one branch the mesher hoists out. The mesher's per-voxel work is one
indexed load once it has the param, and the *game* -- luanti_client's
`shapes.lua`, which already computes exactly these -- fills the table.

This is the item to expect argument about, and the alternative worth naming:
let a definition name a *rule* (`FACEDIR`, `WALLMOUNTED`, `LEVEL`,
`PALETTE`) and let the mesher implement each. That is less data and more
engine, and it makes the engine own a list that grows every time a game wants
a new kind of turn. The variant table is more bytes and no engine knowledge,
so it is the one to build; write the rule enum off.

Only `param` widths up to 8 get a variant table (256 index entries). A wider
param is storage the game reads itself, not something the mesher indexes.

### What stage 1 is worth, and to whom

- luanti_client deletes the (definition, param2) pair machinery: `PAIR_SCALE`,
  `param2_look`, `build_pair`, `register_pairs`, `pair_count`, the second
  `pack_voxel_volume` pass and the `second =` sample array. Measured 5701
  extra voxel ids on VoxeLibre, at 368 bytes of `CachedVoxelDefinition`
  each -- 2.1 MB of definition table hit at random by id, gone.
  **Not** gone: the composed, tinted textures and their atlas segments. A
  palette entry is still a texture. Say so before anyone expects the frame
  spikes to change.
- A painter gets `id` unbound... no: `id` stays required (the registry needs
  one definition), so a painter binds `id` to 0 bits -- treat width 0 on `id`
  as "always voxel id 1" -- and `color` to 32 bits. One definition, one
  colour plane's worth of data in the word.
- `module/voxelworld` and the sample games: **no change at all.** That is the
  test.

### The check

There is no C++ test harness in this tree and this is not the change that
should add one. What there is, and what fits: an extension runs a Lua
self-check of the engine primitives at boot -- `engine_test.lua`, called from
`luanti_client/init.lua`, checking `pack_voxel_volume()` against
`Volume:serialize()`. `set_format()` is bound to Lua in step 6, so the format
can be checked the same way, from the same file, with no new machinery:

- `legacy()` and `luanti()` accept; overlapping fields, a field past the end
  of its plane and an id wider than 21 bits are rejected with a reason.
- A round trip: write every field at every width, read it back.
- **The one that matters**: under `legacy()`, a packed volume's voxels read
  through `get_id()` / `get_skylight()` / `get_lamplight()` give what the
  format-driven path gives, over a sweep of words. That is the assertion
  that stage 1 changed nothing.
- A non-legacy format with a `field = "param"` source, packed and read back.

`VoxelFormat::validate()` is worth an `assert` sweep of its own in C++,
which fits in the same place the rest of the engine's invariants live:
`assert` at the call site in `set_format()`, with the reason logged.

The games are the other half of the check, and better than a unit test for
the property that matters: `games/voxel_lighting` and
`games/multisection_lighting` have `check.txt` command sequences that produce
comparable screenshots. Take them before and after each of the six steps.
Identical images under `legacy()` is stage 1's real acceptance test.

## Stage 2: planes -- ADOPTED

Decided while planning `doc/plan/aggregate.md`: aggregate is a mixture model,
its field count is its material count, and no cut of one word expresses it.
The decision was also to aim straight for planes rather than build a
four-materials-in-a-word version first, since the only thing that buys is a
performance comparison against a feature set nobody wants to ship. Planes
are called off only if their performance is unusable, and that will be
obvious from the plane version on its own.

What it needs, all of it designed below: the plane view over PolyVox (which
turned out to want only `getVoxelAt` and an unused `Sampler` typedef), the
field registry, lazy per-chunk materialisation -- which for a mixture model
is what makes the memory affordable rather than a nicety, since nearly every
chunk is entirely one material -- and format 4 on the wire.

The section that follows is the reasoning from when this was open. It is
kept because the arguments in it are the ones to check the result against.

## Stage 2: planes -- the case as it stood

Two findings first, one that clears the way and one that raises a question.

### The PolyVox obstacle is not one

Answer 1 below -- a view type that satisfies PolyVox's volume concept -- is
not just the laziest option, it is nearly free. `CubicSurfaceExtractor-
WithNormals` (3rdparty/polyvox, 128 lines of `.inl`) uses exactly two things
from its volume type:

- `m_volData->getVoxelAt(x, y, z)`, six times per voxel, and
- `typename VolumeType::Sampler`, which it *declares and constructs* as a
  member and then never uses.

The region comes in as a constructor argument, not from the volume. So a
plane view needs a `VoxelType` typedef, a nested `Sampler` with a
`Sampler(VolumeType*)` constructor, and `getVoxelAt`. No PolyVox patch, no
copy of the id plane, no fork of the extractor. Answers 2 and 3 can be
struck.

### The question: who is asking for planes?

Stage 1 removed every consumer that wanted them. luanti_client -- the case
that drove the whole design -- now fits Luanti's 16 + 8 + 8 in one word with
bits to spare. `module/voxelworld` and the sample games use one 21-bit id and
two light nibbles. Nothing in the tree needs a second plane today.

What planes buy is in the design note: the **capability** that a module can
add a byte per voxel without asking anyone, narrow words for a mass-terrain
game, and planes on the wire compressing the way Luanti's mapblocks show
they do. All real, none of it wanted by code that exists.

What it costs is not small: the volume stops being
`pv::RawVolume<VoxelInstance>` at 51 sites, `serialize_volume_*` grows a
format that travels inside saved worlds *and* on the wire, chunks gain lazy
per-plane materialisation under a lock, and the field registry has to
serialize and survive a module being disabled. That is a sweeping change
whose acceptance test is "nothing broke", which is the expensive kind.

So this is the sizing question rather than a technical one, and it is
yours: **build the capability now on the strength of the design note, or
wait until a game asks for it?** A third option that is cheaper than both:
build only the *narrow word* half -- `plane_bits = 8` or `16` with one
plane, which needs the plane view above and none of the field registry --
if a mass-terrain game is the nearer want.

Until that is answered, the rest of this section is the design, not a
queue.

## Stage 2: planes, as designed

Now the word stops being a word. This is what buys cases 3 and 5 and the
extensibility the design note calls the capability rather than the
optimisation.

### The type

`VoxelFormat` grows `sv_<VoxelPlane> planes` (`{name, bits}`), and
`VoxelField::plane` starts being read. The volume stops being
`pv::RawVolume<VoxelInstance>` and becomes:

```cpp
class VoxelVolume {              // interface/voxel_volume.h
    pv::Region region;
    const VoxelFormat *fmt;      // owned by the registry, outlives this
    sv_<uint8_t> data;           // all planes, one allocation, plane at a time
    // plane p of a volume of N voxels starts at plane_offset[p]
};
```

**The PolyVox problem, which is the real work of this stage.** The cube
mesher is `pv::CubicSurfaceExtractorWithNormals<pv::RawVolume<VoxelInstance>,
IsQuadNeededByRegistry<VoxelInstance>>`: PolyVox is templated on a volume
type whose `getVoxel` returns a value, and `RawVolume` owns its buffer, so a
plane cannot be aliased into one. Three ways out, in order of laziness:

1. **A view type that satisfies PolyVox's volume concept** over the id plane
   -- `region`, `getVoxel(x,y,z)`, a `Sampler`. PolyVox only needs those, and
   the extractor is header-only, so a `PlaneView<uint16_t>` is a small header
   and no PolyVox patch. Try this first.
2. Copy the id plane into a `pv::RawVolume<uint16_t>` per chunk. A padded
   S=32 chunk is 78 KB; it is a memcpy-with-widening and defensible.
3. Stop using PolyVox's extractor. The shape path in `generate_voxel_shapes`
   already walks the volume itself and emits quads; the cube path could too,
   and then PolyVox is only the volume container. Most work, best end state,
   and it is where the "specialise the inner loop on the id width" line in
   the design note actually lands.

Decide by trying 1. If PolyVox's concept turns out to want more than the
above (it wants `getVoxel` by `Vector3DInt32` too, and the extractor takes
the volume by pointer), fall back to 2 and leave 3 as its own item.

### The field registry, and the no-questions-asked part

```cpp
// on VoxelRegistry, per world
VoxelFieldId voxel_field(const ss_ &name, uint8_t bits, uint32_t deflt);
```

Append-only, name-keyed, saved with the world, serialized with the registry
to clients. `bits` is 8, 16 or 32 and a name that already exists returns its
slot and asserts the width matches. In Lua:
`world:voxel_field("mymod:heat", {bits = 8, default = 0})`.

Two rules from the design note become code here:

- **Materialised lazily under the chunk's lock.** A chunk carries a plane
  only once something writes it; a read of a missing plane returns the
  default. A mesher takes a snapshot of the plane pointers and works from
  that. Without this, "add a plane" is a data race against a running mesher.
- **Storage is uncontested, roles are contested.** `voxel_field()` needs no
  cooperation. Binding a role to a field is `set_format()`, which only the
  game calls, and only before the first voxel.

### The serialization migrations

Three formats travel, and each needs its own answer:

- **Volume blobs** (`serialize_volume_*`, format byte 2 = raw and 3 = zlib,
  living in a scene node's `buildat_voxel_data` Var, so they are inside saved
  worlds *and* on the wire to clients). Add **format 4**: region, the plane
  list (name, bits) so a blob is self-describing even without its registry,
  then each plane's bytes in order, zstd. A format 2 or 3 blob deserializes
  as one 32-bit plane -- which is exactly what `legacy()` describes -- so
  **old saves load unchanged and are rewritten as 4 the next time the chunk
  is committed.** No migration pass, no world upgrade tool.
- **Unknown planes are preserved.** Format 4 carrying a plane the loading
  world has no field for keeps it as opaque bytes and writes it back out. A
  module disabled for one session does not cost the player their data.
- **The registry** (`VoxelRegistry::serialize`). Stage 1 already put a
  version byte and the format in front; stage 2 adds the plane list and the
  field table to it. A client with an older registry version refuses the
  connection with a message rather than drawing nonsense.

### `pack_voxel_volume()` in stage 2

`field` accepts a registered field name as well as a role name, and gains
`plane = "mymod:heat"` as the explicit spelling. The output is a format-4
blob. `raw` becomes ambiguous with more than one plane: keep it meaning
"plane 0, all its bits", and say so in `doc/client_api.txt`.

### Bulk plane access

The thing the design note is right to insist on: a module iterating its own
plane wants the plane, not a call per voxel. One accessor, both languages --
`volume:plane("mymod:heat")` returning a byte string in the client sandbox,
`VoxelVolume::plane_bytes(field)` in C++ -- and the per-voxel accessor stays
for convenience.

## Stage 3: what stage 1 and 2 make possible but do not do

Listed so they are not mistaken for part of the work:

- **Narrow ids for a mass-terrain game** (`plane_bits = 8` or `16`): stage 2
  allows it and the mesher's specialisation is where the win is. Measure
  before believing it.
- **Splitting `CachedVoxelDefinition`** into a meshing-hot part under 64
  bytes and a cold part. This is the measured cache lever and it is
  *independent of everything above* -- it could be done today. Keep it
  separate so its measurement is not confounded with the format work.
- **LOD downsampling per role** (id by mode, light by max, colour by mean).
  Today's LOD generator reads the whole word; under a format it needs to
  fold each role its own way. Until it does, a world with a bound `param` or
  `color` loses them at LOD, which is the same limitation shaped voxels
  already have there.
- **A colour channel of its own** in the vertex data instead of multiplying
  into the light, for a PBR path. The design note leaves it open and stage 1
  answers it with "multiply", which covers Luanti's palettes and a painter.

## Order against the master plan

Stage 1 is step 4 of `doc/plan/master_plan.md` and can start the day the merge
lands. Stage 2 is the same step continued, and the honest thing to say is
that stage 1 is a week's shape of work and stage 2 depends on which of the
three PolyVox answers holds. Stage 3 is not step 4.
