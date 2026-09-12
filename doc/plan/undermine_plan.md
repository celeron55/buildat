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

Kept out of git (`/local`) with the other plans.

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

## How it gets built, in phases

The phases matter more than the details, because they are what make this
answer the stage 2 question instead of assuming it.

### Phase 1: the game, on the engine that exists -- DONE

Stage 1 is enough for all of it, including the stress view.

1. `games/undermine`, copied from `games/digger`: the same worldgen, the same
   client, eight materials instead of seven, and the format above. Playable,
   no physics. **Commit.**
2. The support flood in the game's own `main.cpp`, modelled on
   `update_skylight()`: a seed list fed by every dig and place, an active set
   walked on `core:tick`, and the field written through
   `Instance::set_voxel()`.
3. The load sweep, on the columns the support pass touched.
4. Failure and falling, with the per-tick bound. **Commit, and the game is
   playable as a game.**
5. The structures menu, which is what makes it worth playing for more than a
   minute. **Commit.**
6. The stress registry, the two voxelworld client functions, and the toggle.
   **Commit.**
7. The HUD and the creak. **Commit.**

Two things to watch, both of which decide what phase 2 is about:

- **Whether `get_voxel`/`set_voxel` are fast enough.** They take the module
  lock and look the chunk up per voxel, and `voxelworld/api.h` says directly
  that a bulk interface was tried and was only 53% faster -- a judgement
  made for a mesher, not for a simulation. If the active set stays in the
  hundreds, per-voxel calls are fine and no new engine interface is wanted.
  If a cathedral coming down wants thousands of voxels a tick, the thing to
  reach for is `CommitHook::in_thread()`, which already hands a module a
  whole chunk's volume by reference and which **nothing in the tree uses
  yet**. Measure before adding anything.
- **A trap stage 1 left, and this game walks into it on day one.** In Lua,
  `VoxelInstance.id`, `get_id()`, `get_skylight()` and `get_lamplight()` mean
  the *default* format's bit ranges -- they are hardcoded masks, and nothing
  told them about the game's format. digger's client does `v.id ~= 1` in
  `find_pointed_voxel()`, and under undermine's format that reads the id
  together with the light, the load and the support. So the client reads its
  fields out of `v.data` with the game's own shifts, in one place, and the
  engine-side fix if it grates is `voxel_reg:get_format()` returning the
  table that `set_format()` takes (only `dump_format()` exists today).

### Phase 1b: what the playtest found -- DONE

Played by the user after phase 1. The rules themselves work: things turn to
rubble when what held them up goes away, and the load view shows what it
says it shows. Five things to put right, none of them limited by the voxel
format.

**In this order**, which is by how much each one is in the way rather than
by the numbers below: 3 the player falling through the terrain, since
normal movement is unusable without it; 2 the menu, since a feature is
unreachable; 4 the free-move axis, which is a line; then 1 the three views,
which is the largest; then 5 the rubble rule.

**1. Three views, not one, and the param has to carry both numbers.**

The load view works -- confirmed in the playtest. What is missing is that
this game's dominant failure mode is *support*, not load: a roof one step
from coming down has support 1 and load 0, so the load view draws it as
safe as bedrock. The user wants three modes on the key: load, support, and
a combined one for a quick look.

The obstacle, and it is the interesting part: **the mesher sees only what a
role is bound to, and there is one `param` role.** Three views cannot each
bind their own field.

**They do not have to. Pack both numbers into the one param and let each
view decode it:**

    param  =  (load band 0...15) << 4  |  support 0...15

The load band is the load normalised by the voxel's own material capacity,
which the simulation can do because it knows the material -- and which is
the same normalisation the sixteen variants were doing in the
`variant_of_param` table already. Then all three views are three registries
over the same eight bits, differing only in how their `variant_of_param`
decodes them:

- **load**: the colour of the high nibble
- **support**: the colour of the low nibble, inverted, so 0 is red
- **combined**: the worse of the two

Sixteen variants each, no field of its own, nothing added to the word. And
it *shrinks* the layout rather than growing it, because the separate
support field is then redundant with the param's low nibble and the stored
raw load is not needed by anything: `compute_load()` recomputes it from the
column every time, and the HUD can do the same client-side for the one
voxel it points at.

    id 0...7, light_sky 8...11, param 12...19

Twenty bits of thirty-two, and twelve spare rather than eight -- so phase
3's moisture stops competing with the views for room. The precision cost is
that the failure test reads "the band is at the top" instead of an exact
load, which is a rounding of one sixteenth of a material's capacity.

This supersedes the danger-byte idea that was here: it gives all three
views instead of one, and it buys bits instead of spending them.

**2. The structures menu draws as a white vertical bar.**

`ui_utils.vertical_menu()` builds a Window and Buttons and calls
`SetStyleAuto()` on them, which needs `root.defaultStyle` to have been set.
Every other caller in the tree sets it first --
`__menu/init.lua:49`, `launch_menu/init.lua:107`, and
`ui_utils`' own `show_message_dialog()` and `show_notification()` set it on
what they create -- and undermine's client does not, so the widgets come up
unstyled: a white box with invisible text.

The fix belongs in `vertical_menu()` rather than in the game, next to the
two siblings that already do it: default `root.defaultStyle` to
`__menu/res/main_style.xml` when the root has none. One line, and every
game that reaches for a menu later gets it right.

**3. The player falls through the terrain. It is an engine bug, not this
game's, and it is diagnosed.**

The playtest went further than undermine: **digger does it too**, at the
moment physics is enabled when the world finishes loading. **infidigger**
stands up initially and then falls through when walking into a neighbouring
section. **games/voxel_physics** does not do it at all -- its pieces sit on
the terrain and on each other.

That pattern is the diagnosis. voxel_physics is the one game that asks
voxelworld for physics: `create_instance(scene, region, true)`. digger,
infidigger and undermine all call `create_instance(scene, region)`, so the
*server* builds no chunk bodies and the *client* builds its own -- and the
client's path has a window in it where the chunk has no collision at all.

`SetPhysicsBoxesTask` in `src/lua_bindings/mesh.cpp` spreads its work over
three main-thread steps, deliberately, because two of them are expensive
(the comments there measure 8 to 18 ms for a few hundred boxes):

1. `node->GetOrCreateComponent<RigidBody>(LOCAL)` -- the body exists.
2. `set_voxel_physics_boxes(node, context, result_boxes, false)` -- which
   begins with `body->ReleaseBody()`, again deliberately, because editing
   shapes on a live body makes Bullet recompute the mass every time. The
   `false` is `do_update_mass`, so this step does **not** put the body back.
3. `body->OnSetEnabled()` -- which is what re-creates the internal
   `btRigidBody` and puts it back in the world.

So between steps 2 and 3 -- at least a frame, and more when the task queue
is busy -- **the chunk has a rigid body that is not in the physics world and
shapes attached to nothing.** Anything standing on it is standing on
nothing.

And digger's gate tests the wrong thing. `floor_has_collision()` asks
whether the chunk node has a `RigidBody` component, which becomes true at
**step 1** -- before any shape exists and two steps before the body is in
the world. `enable_physics()` therefore fires at the earliest possible
moment the floor is *not* there. That is why digger falls exactly when the
world finishes loading, and why infidigger falls on walking into a section
whose physics is being built for the first time.

Two fixes, and they are separate:

- **The gate.** It has to test something that is only true after step 3.
  The cheapest honest version is a flag the task sets when it finishes;
  checking for a `CollisionShape` component is closer than what is there now
  and still races with the release in step 2.
- **The window.** Even with a correct gate, a player already standing on a
  chunk falls whenever that chunk's physics is rebuilt -- which is what
  happened to infidigger. The observation that makes this cheap: the physics
  boxes come from `physically_solid`, which is a property of the **voxel
  id**, so a write that only changes a simulation field cannot change the
  box list at all. Keep the previous box list per chunk, compare, and when
  it is unchanged do nothing: no release, no rebuild, no window. For
  undermine that removes the rebuilds almost entirely, and for digger it
  removes every rebuild after the first.

  If the boxes really have changed, the window is still there and the
  honest options are to build the new shapes on a second body and swap it
  in, or to merge steps 2 and 3 and pay both costs in one frame -- which is
  what the three-step split exists to avoid. Measure before choosing.

**This retracts what the previous draft of this plan said**, which was that
the collision rebuild was undermine's simulation dirtying chunks every tick.
The simulation makes it constant rather than occasional, and it would be
worth fixing for that alone, but the bug is in the engine's client physics
path and three games have it. It belongs in the master plan, not here.

**4. Free move should walk the horizontal plane, not the camera's axis.**

W and S follow where the camera points, so looking down and pressing W goes
down. Every other sample game moves level and leaves the vertical to its own
keys, which is what makes it possible to fly along a ceiling while looking
at it -- the common case for a camera whose job is to look at buildings.
W, S, A and D take the yaw only; space and shift stay as up and down.

**5. Falling should not turn everything into rubble.**

The rule is that anything with a span keeps its identity only if it is
already loose, so dirt -- span 2 -- becomes rubble when it falls, which the
user rightly found odd. A loose pile of dirt is dirt.

`MaterialProps` gains a `falls_as`: dirt falls as dirt, grass as dirt (a
clod that lands upside down is not turf any more), rock and brick as
rubble, timber as timber. It is one more column in the table and the rule
reads better for being explicit than for being derived from the span.

### Phase 2: what phase 1 was annoying about -- MEASURED

Written after phase 1, from what actually hurt. Two of the four guesses
this section started with were right, one was wrong, and the thing that
actually costs the most was not on the list at all.

**1. A simulation write pays the mesh's price -- and it is not the layout's
fault.**

Placing one chamber and letting it settle sent **902
`voxelworld:node_volume_updated` packets** to the client. The building is
2336 voxels in a handful of 32-cubed chunks, and about 170 voxels fell, so
what *changed appearance* happened once. The other nine hundred are the
chunk being re-serialized, re-sent over the network and re-meshed by the
client because the simulation wrote a support or a load into a voxel --
bits nothing in the playing registry draws.

**And this is not an argument for planes, which is what the first draft of
this section said.** Thinking it through afterwards, three things are wrong
with that:

- **Most of those writes should not happen at all, and the game was what
  was wrong. Done, and measured.** The relaxation walks a voxel's support
  down through every intermediate value on its way to the answer -- 15,
  then 6, then 5, then 4 -- and wrote each one. It now relaxes in a scratch
  map and writes a voxel once, when the front has passed. **902 packets
  became 366**, and the writes went from about twelve per voxel to under
  two. No engine change at all.
- **An engine fix does not need planes either -- DISCUSSION NEEDED on
  whether it is worth building.** What `voxelworld` lacks is not separate
  arrays, it is a way to ask "can this write change the picture?" --
  answerable from the format and the registry as they are: the id bits, the
  light bits, the colour bits, and the param bits when any definition has
  variants.

  Three things have to be true together for that to pay, and the middle one
  is the work:

  1. The registry has to be able to say whether *any* definition has
     variants. Cheap: a flag maintained as definitions are added. Without
     it the param counts as visible, and for undermine the param **is** the
     simulation, so the mask would gain nothing.
  2. The client's own bulk reads have to go away first -- undermine's HUD
     reads the load and its creak reads the support out of the replicated
     volume, so the mask would correctly conclude that every write must be
     published. They want a query for a handful of voxels, not a field. See
     the precondition in `doc/plan/voxel_data_model_plan.md`.
  3. The views need the staleness machinery designed in that same document,
     or switching to one shows an out-of-date world.

  And the remaining traffic after the game-side fix is 366 packets for one
  deliberate building placement, which nobody has complained about. So this
  is a real design with a real cost and no longer an urgent one: worth
  doing when something is actually hurting, and worth leaving alone until
  then.
- **Planes would not finish the job.** The load is not only the mesher's
  business: this game's own HUD reads it from the client's copy of the
  volume, and the creak reads the support the same way. Stop sending those
  writes and the client goes stale, whatever they are stored in. The real
  shape of the problem is that `voxelworld` has one notion of "this chunk
  changed" serving three different consumers -- the mesher, the client's own
  reads, and saving -- and it is that conflation that costs, not the layout.

So the measurement stands and the conclusion drawn from it did not. It is a
good finding about `voxelworld` and a poor one about planes.

**2. The load sweep reads the same column thirty-two times over.**

A voxel update is 8 to 33 microseconds -- 2048 of them per tick, measured
in the tick line -- and about 38 of the roughly 40 `get_voxel()` calls it
makes are the LOAD_DEPTH column above it, one at a time, each pulling a
whole 32-bit word to read eight bits. That is the structure-of-arrays
argument, in the one loop that actually runs hot, and it is the same shape
as the design note predicted. A plane of `uint8` would make it a strided
read of 32 bytes.

**3. The default-cut accessors are a trap, and they bit five times.**

`VoxelInstance::get_id()` and the Lua `v.id` mean the *default* format's bit
range, so under a game's own cut they read its light, parameter and
simulation bits as part of the id. Building the game found five of these in
`builtin/voxelworld` alone -- `merge_volume()`'s is-this-generated-yet test,
both emptiness tests and the light transmission cache -- where an air voxel
with skylight in it stopped looking like air. Fixed in `d6a6b08`. The
client's own reads go through the game's shifts by hand, which works and
reads badly.

Two more of the same shape, both found by using them: the format's `color`
role was validated, serialized and then read by nothing (`bb75874`), and
the mesher only put vertex colours in a geometry when it was *lighting*
it, so a colour with no light behind it was dropped on the way to the
shader (`b4db33b`).

**4. Handing the bits out was not annoying, and this is the honest part.**

The guess was that the game brokering its simulation's bits would grate.
It did not: the format is nine lines in one file, the fields are named
constants next to it, and nothing had to negotiate with anything. What
would grate is a *second* module wanting a byte -- and that is a thing this
game does not have, so it remains an argument rather than an observation.

**5. Twenty-four of thirty-two bits are spent**, with eight spare -- and
phase 1b's repacking takes that to twenty spent and twelve spare, by
noticing that two of the three stored numbers did not need storing. Which
is its own small lesson about how much a bit budget really binds: the first
serious look at it found a third of it back.

### Phase 3: ask for the fourth field -- DONE, and the answer is interesting

**Wet dirt.** Water seeps into the dirt around it; wet dirt has span 0 and
half the capacity, so digging under a lake floods and then collapses. It is
one more 8-bit field -- moisture, so that it can spread and dry rather than
being a boolean -- and it is a genuinely good addition to the game.

**Built, and it cost nothing in the format.** Moisture is four bits rather
than the eight this plan guessed -- it is a distance from water, 0...5, so a
nibble does -- and, more to the point, **it is not one of the engine's
roles**. So the format did not change at all, nothing in the engine had to
be told, and the layout went from twenty bits spent to twenty-four with
eight still spare.

So the answer to "what does adding a field cost a game that has no saves"
is: nothing. That is the baseline this phase existed to establish, and it
is worth having in writing before anything is claimed about what it costs
later.

**The material id is rejected, and rightly.** The playtest's objection: a
voxel type should not exist for the mesher's benefit, and dirt should just
*look* wetter. That is phase 4 plus the modifier roles in
`doc/plan/voxel_data_model_plan.md` -- bind a `tint` role to the moisture bits
and give the definition a wet colour, and wetness becomes continuous and
costs no id and no extra storage. Until that exists the material stands, as
the only way for the mesher to see anything a definition's param does not
already carry.

**What it cost was a material id, and that is the finding.** Both
nibbles of the param were spoken for by the views, and a definition's
variants are indexed by the param, so there was no way for the mesher to
*see* wetness. Wet dirt had to become its own material, with its own
texture and its own span and capacity. Which is the better answer anyway --
wet dirt is a different thing from dirt, not dirt with a flag -- but it
relocates the wall: **the scarce thing here is the param, not the width of
the word.** A game gets one role the mesher will look at, and everything it
wants drawn differently has to come through that one nibble-and-a-half or
be a material of its own.

That is a better argument against planes than for them, incidentally.
Planes would give the game as many fields as it likes and would not give it
a second param role.

**Do it anyway, and do it before saving exists.** Wet dirt is a good
addition to the game on its own -- digging under a pond floods and then
collapses -- and the point of doing it now is that adding a field to a game
that has no saved worlds costs nothing, which is worth establishing as the
baseline before anything is claimed about what it costs later. After phase
1b's repacking there are twelve spare bits, so moisture is no longer
competing with anything for room.

The field after that is where the room genuinely runs out -- wet timber's
degradation, a crack level so digging is progressive, heat near lava, any of
them.

What used to be here -- "add moisture after the game has saves, and see what
the migration costs" -- has moved to the wishlist, because it needs saving
to exist and saving is not something this game needs.

### Phase 4: water as a quantity, with pressure -- PLANNED

From the playtest, and the most interesting thing left in the game.

**Water stops being a material and becomes a field.** One value per voxel,
read in two regimes:

- below *full*: how much water is in the voxel. In air that is a level to
  draw a surface at; in something porous it is how wet it is, which is what
  moisture already means -- so moisture is not a separate field, it is the
  low end of this one.
- at or above *full*: the voxel is saturated, and what is left of the range
  is **pressure**.

Pressure is what makes it worth doing. With it, water climbs: a voxel can
push into the one above when the pressure below exceeds the height it has to
rise, so water seeps up from underneath and fills a cave or a basement from
its lower end -- even where the lower end looks sealed by dirt, because dirt
is porous and carries pressure at a trickle. Digging into a hillside below a
pond stops being safe in a way that is legible and not arbitrary.

What it changes, and this is why it is phase 4 and not a tweak:

- **The mesher has to draw a partly filled voxel**, at a height that is a
  per-voxel number rather than a per-definition one. That is exactly the
  `sag` modifier role in `doc/plan/voxel_data_model_plan.md` -- and
  `liquid_top` is already that number, reached the discrete way. So this
  phase and the modifier roles are the same piece of work approached from
  two ends.
- **The id space stops carrying liquid state.** No water material, no wet
  dirt material: dirt with water in it is dirt, tinted.
- **The bit budget gets tight for the first time.** id 8, sky 4, param 8,
  water 8 is twenty-eight of thirty-two, and moisture's four go back into
  the pot rather than being spent twice. It still fits. The modifier roles
  cost nothing because they alias what is already there.
- **The simulation stops being local.** Everything undermine does now is a
  relaxation around an edit; flowing water is a sweep, every tick,
  everywhere there is water. That is the first thing in this game that
  wants to read one field over a whole volume in order -- which is the
  structure-of-arrays argument finding its first real customer, and the
  measurement that would actually decide stage 2.

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

## What to decide before starting

- **The name is `undermine`.** Settled.
- **Whether the simulation lives in the game or in a module.** In
  `games/undermine/main/main.cpp` it is simpler and it is what a sample game
  should look like. In `builtin/structure` it is reusable and it is what
  demonstrates "a module keeps per-voxel state without asking the game" --
  the whole extensibility argument. The plan above puts it in the game for
  phase 1 and moves it out in phase 2, because moving it out is easier once
  the rules are settled and because phase 2 is where the argument gets made.
- **Textures.** Eight materials want eight textures. Digger has rock, dirt,
  grass, leaves, tree and water already; sand, rubble, timber and brick are
  new. `games/voxel_lighting/make_client_data.py` generates textures, which
  is where digger's water came from, so this is a script and not an art
  project. The stress view's sixteen bands need no textures at all -- they
  are colours over whatever the material already wears.
