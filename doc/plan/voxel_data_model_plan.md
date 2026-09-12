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

## Stages 1 and 2 -- BUILT

The bit cut a game picks, and then planes. Both are in
`doc/plan/voxel_data_model_history.md`: what was planned, what it came to, and
the case that was made for planes before they were adopted. `VoxelFormat`,
`VoxelPlane` and the roles in `src/interface/voxel.h` are the result, and
`games/aggregate` is the consumer that proved them.

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

## Stage 2: planes -- ADOPTED

Decided while planning `doc/plan/aggregate.md`: aggregate is a mixture model,
its field count is its material count, and no cut of one word expresses it.
The decision was also to aim straight for planes rather than build a
four-materials-in-a-word version first, since the only thing that buys is a
performance comparison against a feature set nobody wants to ship. Planes
are called off only if their performance is unusable, and that will be
obvious from the plane version on its own.

What it needs, all of it designed in
`doc/plan/voxel_data_model_history.md`: the plane view over PolyVox (which
turned out to want only `getVoxelAt` and an unused `Sampler` typedef), the
field registry, lazy per-chunk materialisation -- which for a mixture model
is what makes the memory affordable rather than a nicety, since nearly every
chunk is entirely one material -- and format 4 on the wire.

The section that follows is the reasoning from when this was open. It is
kept because the arguments in it are the ones to check the result against.

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
