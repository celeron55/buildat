# undermine: a sample game where digging brings the roof down

**FROZEN.** Phases 1, 1b, 2 and 3 are built and the game is playable; see
`doc/plan/master_plan.md` step 5. It is kept compiling and working as the
engine changes, and the player physics fault is fixed if a working fix turns
up, because that one is the engine's and every game with a player has it.
Nothing else here is scheduled. Phase 4 below -- water as a quantity with
pressure -- lives on in `doc/plan/aggregate.md`, where it is the same idea with
more than one material.

A plan, not a commitment. Digger's world plus structural failure: rock spans
a gap, dirt does not, a timber prop holds a ceiling until too much weight
stands on it, and rubble holds nothing. Dig badly and the mine caves in on
you.

## Why this game and not another

It is the consumer the voxel data model does not have. Stage 1 of
`doc/plan/voxel_data_model_plan.md` shipped, and in shipping it removed every
case that wanted planes: luanti_client now fits Luanti's 16 + 8 + 8 in one
word, and the sample games use one id and two light nibbles. So stage 2 is
blocked on a sizing question -- build a capability nothing asks for, or wait
for something to ask -- and the honest way out of that question is a game
that asks.

It has to be the right kind of asking, and this is the part worth being
straight about before any code:

**What this game proves.** That a module can keep per-voxel state of its own
without the game brokering bits for it, and that the state a simulation
reads is a different shape from the state a mesher reads. Those are the
design note's extensibility and structure-of-arrays arguments, and a working
game makes them concrete.

**What it does not prove.** That 32 bits are not enough. As scoped below it
is 6 bits of id, 4 of light, 8 of load and 4 of support -- 22 bits, with ten
to spare, so phase 3's moisture field fits and the field after it does not.

That number moved while the game was being built, which is worth recording
because it is the honest shape of this argument. The first draft budgeted 8
bits of light, copying the engine's default cut; the user asked why a game
would carry a lamp-light field at all when its lamps are lights in the
scene, and the answer was that nothing in buildat fills one -- only the
Luanti client does, because a Luanti server bakes it and sends it. Four bits
back, and the wall moves out one field.

**So the width argument is the weaker one and always was.** Where the wall
sits depends on how frugal the layout is, and a frugal layout can always
buy one more field. What does not change with frugality is that bits in a
shared word are a negotiated, exhaustible resource and planes are not: a
second module wanting a byte per voxel has to ask the game for it either
way, and the game has to know about it. That is the argument this game is
built to make.

So: this is not a demo built to justify planes. It is a game, built on what
exists, whose second feature is the evidence.

## The game

Digger's shape: a finite voxel world, dig with the left button, place with
the right, no goal but the hole you make. `games/digger` is 529 lines of
server and 601 of client and most of both is reusable as it stands.

What is added is that the world does not hold itself up for free.

### Materials

Eight, replacing digger's seven. Each carries three numbers the simulation
reads -- `span`, how far it reaches unsupported; `density`, what it weighs;
`capacity`, what it can carry -- and nothing else about it is new.

| material | span | density | capacity | what it is for |
|---|---|---|---|---|
| air      | -- | 0  | --  | |
| bedrock  | 15 | -- | inf | the bottom of the world; undiggable, and where support comes from |
| rock     | 6  | 3  | 200 | the good stuff: roofs stand on their own |
| dirt     | 2  | 2  | 60  | a dirt ceiling wants props every few voxels |
| sand     | 0  | 2  | 40  | never holds itself; runs into a tunnel that opens under it |
| rubble   | 0  | 2  | 50  | what everything becomes after it falls, and it holds nothing |
| timber   | 8  | 1  | 30  | a prop: long span, snaps under weight |
| brick    | 3  | 4  | 255 | a pillar: short span, carries a mountain |

Two of those are the whole game design. Timber spans far and carries little,
brick spans little and carries much, so a wide chamber wants timber on the
ceiling *and* brick underneath it, which is a real decision rather than one
resource to spend.

Water stays as digger has it, with no structural role. Wet dirt is phase 3.

### The rules

Three, and they are all the physics there is.

1. **Support.** Bedrock has support 15. A voxel with a supported voxel
   directly below it has support 15 -- a column carries straight down. A
   voxel with nothing under it takes
   `support = min(span, max(support of the four horizontal neighbours) - 1)`.
   Support 0 means nothing holds it and it fails.

   This is a distance-from-the-nearest-wall rule rather than statics, and it
   is the right kind of wrong: a tunnel wider than twice the material's span
   caves in the middle, which is legible from inside the tunnel and is what
   makes the game teachable without a manual.

   It is also, structurally, the same computation as
   `CInstance::update_skylight()` in `builtin/voxelworld`: a seeded flood
   that only raises, plus a recompute of what a removal darkened. That
   function is 150 lines and already solves the hard parts -- seeds, an
   active set, settling before the chunk is meshed -- so the support field
   is that code with a different rule in the middle. Read it before writing
   anything.

2. **Load.** Down each column, `load = load above + density`, and a voxel
   whose load exceeds its capacity fails. One sweep per affected column,
   which is what makes a prop under thirty voxels of rock snap and a brick
   pillar under the same rock hold.

3. **Falling.** A failed voxel becomes falling: next tick it moves down if
   what is below is air or water, and turns to rubble where it stops. A pile
   of rubble spans nothing, so the ceiling above it fails next, which is the
   cascade -- and cascades are the fun.

   Bounded per tick (say 512 moves) so that a bad dig is a rumble that takes
   a second rather than a frame that takes a second.

### The bit layout, and the one trick in it

```
id 0...5, light_sky 6...9, param 10...17, support 18...21
```

`param` **is** the load field. That is not a coincidence to be tidied up
later, it is what makes the stress view free: the engine's `param` role is
the one thing the mesher reads and hands to a definition, so binding it to
load means every voxel's load is already available to the mesher without a
byte of extra storage. See "The stress view" below.

There is no lamp light. A lamp in this game is a light in the scene -- the
player's own lamp already is -- and the shader lights the geometry from it,
so the field would be four bits nothing writes. Only the Luanti client binds
that role, because a Luanti server computes it per voxel and sends it.

`support` is not a role. The engine neither knows nor cares about it; it is
four bits the game reads and writes itself out of `VoxelInstance::data`,
which is exactly what the design note says a game's simulation fields are.
Bits 24...31 are spare.

**Phase 1b revises this**: the param packs a load band and the support into
its eight bits, which makes the separate support field redundant and the
stored raw load unnecessary, and the layout shrinks to twenty bits. See
phase 1b item 1.

## Structures you can place

Building a cathedral by hand to find out what happens when you cut a pillar
is tedium, not a game. So: a menu of predefined structures, placed instantly
where you stand.

- **The list**, each generated by a loop rather than authored as data, so it
  is parametric and each is thirty to sixty lines of C++: a **cathedral**
  (nave, a row of pillars each side, an arched roof), a **bridge** (deck on
  piers, over the nearest valley), a **mineshaft** (a tunnel with timber
  props at a spacing), a **tower**, and an **overhang** (a cantilever that
  is already close to failing). The cathedral and the bridge are the two the
  user named and the two worth having first.
- **Placed with the sim held off, then settled in one pass.** A half-built
  cathedral is an unsupported roof, and it would collapse while being built.
  So a structure writes all of its voxels first -- with a per-tick budget,
  since a cathedral is thousands of them -- and only then seeds the support
  flood over the whole footprint. What comes out is a building that either
  stands or falls down as a whole, which is the correct answer either way.
- **A structure carries its own air.** A cathedral inside a hill is no use,
  so a footprint includes the air it needs and clears as it places. That
  rules out `Instance::merge_volume()`, whose whole contract is that it does
  not overwrite what is already there; this is `set_voxel()` per voxel on a
  budget, which is also what the falling pass already does.
- **The menu** is client-side, a small window with
  `extensions/ui_utils`'s `bind_button_menu` for keyboard selection, opened
  with a key. The client sends `main:place_structure` with a name and the
  player's position, the same shape as digger's existing dig and place
  packets.

This is also the sim's test harness. Place a cathedral, saw through a
pillar, and watch what the three rules make of it -- which is a better
regression test than any screenshot, and more fun to run.

## The stress view

A key toggles the world from its own textures to load-as-a-colour: a
gradient over how close each voxel is to failing.

**I called this a trap in the first draft of this plan and I was wrong.** The
reasoning was that a colour is 24 bits per voxel and 6 + 8 + 4 + 8 + 24 does
not fit a word. That is true of the `color` *role*, and irrelevant, because
a stress view does not need arbitrary colours -- it needs about sixteen. And
sixteen colours keyed by a per-voxel value is precisely what a definition's
param-indexed variant table is, at zero extra storage:

- `param` is bound to the load field, so the mesher already has each voxel's
  load.
- Each material's definition gets **sixteen variants**, one per band of the
  gradient, each with a `color`.
- `variant_of_param` maps all 256 load values onto those sixteen bands
  **per material**, so rock (capacity 200) and timber (capacity 30) each get
  a full gradient over their own range. The normalisation by capacity, which
  is the thing that makes a stress view mean anything, falls out of the
  table being per definition and costs nothing.

How the toggle works, given a format is fixed before the first voxel:

- The game builds **two registries with the same format**: the playing one,
  whose definitions have no variants at all (so the mesher hoists the param
  out and normal play pays nothing), and the stress one, whose definitions
  carry the sixteen bands. The second goes to the client over a packet of
  the game's own, the way digger already sends its worldgen queue size.
- Toggling swaps which registry the client meshes with, sets
  `M.use_skylight = false`, and remeshes. Skylight off is what makes the
  gradient flat and readable: with it on, the vertex colour is light times
  tint and a stress view of a dark mine is a black mine. A variant colour
  tinting the light rather than the albedo is finally the right thing to be
  doing, because in this view the tint *is* the picture.
- The two functions this needs from `builtin/voxelworld/client_lua/module.lua`
  do not exist yet: **`M.set_voxel_registry(reg)`** and
  **`M.remesh_all()`**. The second is `queue_modified_node_update()`, which
  is already there, over every loaded static node. Fifteen lines, and the
  only builtin change the whole game asks for.

"Augment" rather than "replace" -- the gradient over the normal textures --
is the same thing with skylight left on, and is worth a look outdoors where
there is light to spare. Not worth a second key until someone wants it.

### Making the invisible legible, without the view

- The HUD names the pointed voxel's material and prints its support and
  load. That is the whole debug interface between digs and it is enough.
- A creak when the support of anything within a couple of voxels above the
  player drops to 1. Cheap, and it turns the rule into a warning the player
  learns to obey.

## How it was built

Phases 1, 1b, 2 and 3, in `doc/plan/undermine_history.md`. The measurements
they produced -- 902 chunk-changed packets down to 366, twenty of thirty-two
bits spent, what adding a field costs a game -- are what the voxel data model
was argued from.

## Wishlist, not planned

- **Saving, and then migrating a save whose world has grown a field.**
  `voxelworld` has `save_enabled` and it is false, and undermine does not
  need saving to be the game it is. But the interesting question is
  downstream of it: a world saved under one cut of the voxel word, loaded by
  a build whose game has since added a field, has to be migrated -- every
  chunk rewritten, every voxel's bits moved -- and that is the cost the
  whole planes argument turns on.

  It does not need real saves to answer. A **fictitious old save** is enough:
  write a world out under the phase-1 layout, then load it with a build
  whose format has moisture in it, and see what the migration has to do and
  how long it takes for a world of a given size. That is a day's work
  whenever the question is worth answering, and it is a better experiment
  than waiting for the game to accumulate saves, because the sizes and the
  layouts are then chosen rather than inherited.

- **Wet wood.** A timber prop that takes water is just as strong at first
  but heavier than dry timber, and then degrades over time, with the
  degradation showing as moss and fungus spreading across it. The moss is
  free once there is a moisture field and a param the mesher reads -- it is
  the stress view's machinery pointed at a different field. What it needs is
  a *long* session for the degradation to matter, and a game whose interest
  depends on waiting is a game that is boring, so it stays here until a
  reason turns up. If one does, it is another field and another argument for
  planes.
