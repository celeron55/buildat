# Master plan: what is finished

Moved out of `doc/plan/master_plan.md` so that it holds only what is open.
Nothing here is a to-do. It is kept for the reasoning: why each thing was
built the way it was, what doing it turned up, and the measurements that
settled an argument. The numbering is the master plan's own and other plans
still refer to these sections by number.

## 1. Plan the improved voxel data model -- DONE

Turn `doc/plan/buildat_voxel_data_model.md` from a design note into a plan that
can be executed: the interfaces, the order of the changes, and the
**migrations**, which are the part a design note is allowed to hand-wave and
a plan is not:

- `module/voxelworld` and the sample games that use it, whose saved volumes
  are one 32-bit array today.
- `pack_voxel_volume()`'s `field` names, which are a documented Lua-facing
  contract.
- The `luanti_client` extension, which is the one consumer that wants a
  param reaching the mesher; what it can drop once it has one (the
  (definition, param2) pair machinery) and what it keeps (a colour, until a
  colour role exists).
- The registry's serialization, since the format travels to clients.

Done: `doc/plan/voxel_data_model_plan.md`. What it settled, in case only this
file is read: the format lives in the `VoxelRegistry`, which is already
per-world and already serialized to clients, so the 51 volume signatures do
not change; `VoxelFormat::legacy()` is today's cut bit for bit, so nothing
migrates and `module/voxelworld` and the sample games are untouched; stage 1
is a game-chosen cut of the same 32-bit word, which already covers Luanti's
16 + 8 + 8 and a painter's RGBA; planes and the field registry are stage 2,
where the volume stops being `pv::RawVolume<VoxelInstance>` and PolyVox's
templated extractor is the real work. `pack_voxel_volume()`'s `field` names
become role names and keep working.

## 2. A few quick fixes in luanti_client, before the merge -- DONE

Small, visible, low-risk. **The list is the user's to give -- ask.** Not a
place for anything structural: the structural work is step 4.

What the list turned out to be: furnace and other node inventories, nearest
neighbour filtering for pixel art, a pause menu with the key bindings in one
table, F5 debug text hidden by default, and then discoverability -- one
binary, one launch menu, launchable extensions.

## 3. Merge luanti_client -- DONE

It is at its development midpoint, on solid ground, with the next steps
written down. Merging now means the branch stops being a place where the
engine and a game move together in one history.

What the merge should carry with it: `doc/luanti_client.txt` and
`doc/client_api.txt` are up to date as of the last commit on the branch, and
the plan and history files stay out of git on purpose.

Done as PR #46, merged into master.

## 4. Execute the voxel data model plan -- STAGE 1 DONE

On branch `voxel-format`, ten commits: the format, its home in the voxel
registry, the mesher reading through it, `pack_voxel_volume`'s fields as
roles, voxelworld's skylight, `VoxelVariant` so a definition says what its
param means, and luanti_client migrated onto Luanti's own 16 + 8 + 8 cut.
The sample games are untouched and their check images are unchanged, which
was the acceptance test.

Palettes stay on their per-colour-voxel path, decided: a variant's colour
tints the light and a palette tints the texture. See "The blocker" in
`doc/plan/voxel_data_model_plan.md`.

**Stage 2, planes: ADOPTED, as part of step 6.** It was DISCUSSION NEEDED
for a long time and the discussion is over: aggregate needs them, the
decision is to aim for them rather than build a word-sized version first,
and the only thing that would call them off now is performance so bad it is
obvious without a comparison. What follows is the reasoning that kept it
open, which is still worth having on record.

Nothing technical is in the way -- the PolyVox obstacle turned out to be
nothing, since the cube extractor wants only `getVoxelAt` and an unused
`Sampler` typedef from its volume type. What is in the way is that neither
thing undermine measured is actually fixed by planes.

**The chunk-changed fight was real and the cheap fix did most of it.**
Placing one building and letting it settle sent 902 chunk-changed packets
where the appearance changed once. The relaxation was writing every
intermediate value of a voxel's support on the way to the answer; it now
relaxes in a scratch map and writes once, and **902 became 366** with no
engine change. What is left is `voxelworld` having one notion of "this
chunk changed" for three consumers -- the mesher, the client's own reads,
and saving -- and 366 packets for one deliberate building placement, which
is not currently hurting anything. That has a design of its own now, in
"Adjacent: what a chunk publishes, and when" in
`doc/plan/voxel_data_model_plan.md`: a mask of the bits that can change the
picture, computable from the format as it stands; three classes of change
rather than two, since a field no view reads today is read by one tomorrow;
a client that declares what it is interested in, because the server cannot
know; and a client that can work out its own staleness and dim what it has
not got yet.

That design is also where the **first argument for planes that survives
scrutiny** turned up, and it is not one either of these documents started
with. The staleness mask is independent of planes -- it is a mask over
fields, and a field is a bit range today and a plane later -- but with one
word it can only *inform*: the chunk is one array of 32-bit words, so
knowing that a single 8-bit field is behind costs the same whole-chunk
resend as knowing everything is. With planes the same mask names a slice,
and the resend is one byte per voxel instead of four. The cost, which is
not small, is that per-plane transfer is a different channel from the
replicated scene Var that carries chunks today.

So the order stands: the mask first, over bit ranges, since it is useful on
its own and it is what says how much traffic is really left. If what is
left is dominated by whole chunks resent for one field, that is the
measurement that makes planes worth building -- a number rather than an
argument. And none of it matters until undermine stops reading the
simulation's fields in bulk for things that need one voxel at a time, its
HUD and its creak, which is the precondition the whole scheme rests on.

**The width argument is the weak one**, and undermine made that plain by
fitting in 24 bits of 32.

So the order that makes sense: do the two cheap fixes, measure again, and
let planes be decided on what is left rather than on this. What still
argues for them is the capability -- a module keeping a field without
asking the game for bits -- and nothing in the tree exercises that yet.

The measurements and the retraction are in "Phase 2" of
`doc/plan/undermine_plan.md`; the design is "Stage 2" in
`doc/plan/voxel_data_model_plan.md`.

## 4b. The client's chunk physics has a hole in it -- ALL THREE DONE, WATCH IT

All three of the things below are built (2026-09-11). The third, which is
the real fix, turned out to be smaller than either of the shapes the plan
offered: a chunk that *already has* collision is rebuilt in one step rather
than split across frames, so the body never leaves the physics world, and
the split is kept only for the first build, where there is nothing to fall
through yet and every chunk of a loading world is doing it at once. The
cost is both of those times in one frame on the one chunk that changed.

The first of the three was committed broken and is worth the note: a game's
Lua runs in the magic sandbox, and `RigidBody.collisionMask` was not in
`extensions/urho3d/safe_classes.lua`, so the call threw inside the KeyDown
handler, was caught and logged, and free move went on colliding while
looking exactly like a key that does nothing. **When a Lua change to an
Urho3D component has no effect, grep the client log for "does not have
field or property".**

It cannot be called fixed until it has been played: a walking, digging,
pouring harness now exists and does not fall through in aggregate or in
digger, but the fault was always intermittent and the harness is not proof.


Found by playtesting undermine and then confirmed across the sample games,
so it is the engine's and not a game's. `games/digger` drops the player
through the terrain the moment physics is enabled; `games/infidigger` stands
up and then drops through on walking into a neighbouring section;
`games/voxel_physics` is fine, and it is the only one that asks voxelworld
for server-side physics.

The client builds its own chunk collision in three main-thread steps
(`SetPhysicsBoxesTask`, `src/lua_bindings/mesh.cpp`), split because two of
them cost 8 to 18 ms: the body is created in step 1, the shapes are rebuilt
in step 2 after a deliberate `ReleaseBody()`, and the body is put back in
the physics world in step 3. Between 2 and 3 the chunk has shapes attached
to a body that is not in the world -- no collision at all -- and digger's
`floor_has_collision()` gate tests only that the body *component* exists,
which is true from step 1. So the player is let go at the earliest moment
the floor is missing.

Both fixes done in `04ef40d`: chunk nodes carry `buildat_physics_ready`,
set when step 3 has run, and voxelworld's client offers
`chunk_has_physics()` for anything that waits for solid ground; and the
rebuild is skipped entirely when the boxes are the same as the ones already
on the node, which is nearly always, since the boxes come from
`physically_solid` and so from the voxel id.

Measured with a probe in digger at the moment it lets the player go: before,
`body=true shape=true ready=false` -- the shapes were there and the body was
out of the physics world. Checking for a `CollisionShape` would not have
helped either, which the probe also says.

**That was not the whole of it: the playtest still fell through.** The gate
only covers the *first* enabling, and the rebuilds that matter come after
it. The cause of those: `generate_voxel_physics_boxes()` was building
collision for a chunk's padding as well as its own voxels, so a chunk's box
list changed whenever a *neighbour* changed -- which, while a world loads,
is constantly. Every one of those rebuilds took the body out of the physics
world for a step or two. Fixed in `8e7c914` by stopping the boxes at the
chunk's own voxels, which also removes the doubled collision at every chunk
boundary that Bullet was warning about; plus the three games now hold the
player still while the chunk under them is rebuilding rather than letting
them fall.

### What the aggregate playtest adds (2026-09-11)

Still happening, and **aggregate is more exposed to it than undermine was**,
which is worth saying because it points at the cause: the boxes are rebuilt
whenever a chunk changes, and aggregate's world changes far more often --
water moving, wood dying, rot. Every rebuild takes the body out of the
physics world for a step or two. A world that simulates is a world whose
floor blinks.

Three things to do, in this order, and only the last is the real fix:

1. **Free move should not collide with the terrain.** It is an escape hatch
   from every other failure here, and it does not have one today: free move
   turns gravity off and drives `linearVelocity`, but the body still
   collides, so a player who is already inside terrain is stuck in it and
   flying is blocked by what it flies into. The change is the collision
   mask, kept and restored; and **coming out of free move needs a rule** --
   if the capsule is inside something, search upward for the nearest place
   it is not and put the player there before the mask goes back.
2. **Spawn clear of the ground rather than on it.** The player does not
   spawn inside a voxel today -- the capsule bottom is 5 cm above the
   surface (`surface_y + 1.4` for a 1.7 capsule on a voxel whose top is
   `surface_y + 0.5`) -- but 5 cm is inside Bullet's own collision margin,
   so the player begins in resting contact from the first frame, against a
   shape that may not exist yet. Spawning a voxel or two higher turns that
   into a short fall onto a surface, which produces a real contact and does
   not care whether the floor arrived late.

   And the scan wants a second look: it takes the first **structural**
   voxel from the top, and in a mixture world a canopy is structural. A
   spawn column with a tree in it puts the player on the leaves and carves
   the spawn tunnel through the tree. It should look for something with
   bond and capacity -- something to stand on -- rather than for anything
   that is not air.
3. **The rebuild should not take the body out of the world.** Everything
   above is a way of living with that; this is the fix. Either the shapes
   are swapped while the body stays in, or the new body is built beside the
   old one and the two are exchanged in one step.

**It has never reproduced in an automated run** -- the harness lets the
world finish loading, and the window was assumed to be during loading.
aggregate says that assumption was too narrow: a world that keeps changing
keeps rebuilding, so the window is whenever the simulation touches the chunk
you are standing on, which is why it is easy to hit in play and impossible
to hit in a script that stands still. A harness that would catch it has to
dig or pour while walking. The client logs "player held" when the defence
catches it. Full diagnosis in "Phase 1b" of `doc/plan/undermine_plan.md`.

## 5. undermine -- FROZEN

Phases 1, 1b, 2 and 3 are done and the game is playable. **Development is
frozen here.** It has given what it was built to give: a consumer that
exercised the voxel format, and measurements -- 902 chunk-changed packets to
366, twenty of thirty-two bits spent, what adding a field costs a game with
no saves, and where the scarce thing really is.

Two standing exceptions:

- **Keep it compiling and working as the engine changes.** It is a sample
  game and it is the regression test for the voxel format.
- **The player physics fault gets fixed if a working fix turns up**, because
  it is the engine's and every game walking a player around has it. The
  latest attempt is in step 4b and is not confirmed.

Phase 4 -- water as a quantity with pressure -- stays written down in
`doc/plan/undermine_plan.md` and moves in spirit to step 6, where it is the
same idea with more than one material.

`doc/plan/undermine_plan.md`. Digger's world plus structural failure: rock
spans a gap, dirt does not, a prop holds until too much weight stands on it,
rubble holds nothing, and a cascade is the fun. Two per-voxel simulation
fields -- support and load -- of which the engine knows about one, because
binding the `param` role to the load is what makes the stress view free.

Two things make it a game rather than a demo: a **menu of predefined
structures** -- a cathedral, a bridge, a mineshaft -- so that cutting a
pillar to see what happens does not start with an hour of bricklaying; and
a **stress view** on a key, sixteen gradient bands per material as
param-indexed variants, normalised by each material's own capacity for
free. The only builtin change either asks for is two functions in
voxelworld's client_lua, `set_voxel_registry()` and `remesh_all()`.

Phase 1 is built and playable: `games/undermine`, on its own voxel format,
with the three rules, four structures, a menu, a free camera that frames
what it puts up, the stress view, and a creak when what is over your head
has one step of support left.

**Next is phase 1b, what two playtests found.** The player falling through
the terrain turned out to be the engine bug in step 4b above, not this
game's. The rest: the
structures menu comes up unstyled because `ui_utils.vertical_menu()` is the
one menu helper that does not set a default style; free move follows the
camera's axis where it should walk level; the view shows load where this
game fails by support, and wants three modes; and falling should not turn
dirt into rubble. None was limited by the voxel format, and the three views
turned out to *free* bits rather than spend them -- the param carries a load
band and the support in its eight bits, which made two of the game's three
stored numbers unnecessary.

**Phase 4 is planned**: water stops being a material and becomes a quantity,
where the low end of the range is how full or how wet a voxel is and the top
end is pressure -- so water climbs, seeps up from below and fills a cave from
its lower end through porous dirt. It folds moisture into itself, it wants
the `sag` modifier role to draw a partly filled voxel, and it is the first
thing in this game whose simulation sweeps a volume rather than relaxing
around an edit. That last part is the structure-of-arrays argument finding
its first real customer.

**Phase 3 is done too**, and its answer is the useful one: adding moisture
to a game with no saves cost **nothing in the format**, because a game's own
field is not one of the engine's roles. What it did cost was a material id,
since both nibbles of the param were already spoken for and the mesher can
only see a role or an id. So the scarce thing in this game is the param,
not the width of the word -- which is an argument against planes rather than
for them, planes being a way to have more fields and not a second param.

It is here rather than in the "not in this list" pile because it is what
answers step 4's open question. Its three phases are built so that phase 1
runs on the engine as it is today, phase 2 records what that was annoying
about, and phase 3 asks for one more field -- moisture, so water seeping
into dirt makes it collapse -- than a 32-bit word has room for. The
argument for planes is then a diff on a game with saved worlds instead of a
paragraph in a design note.

Honest about its own limits, and the plan says so in its second section: as
scoped it fits in 26 bits, so it proves the extensibility and
structure-of-arrays arguments and not the width one.

## 6. aggregate -- FROZEN (2026-09-12)

Phases 1 to 5 are built and the game is playable; see
`doc/plan/aggregate_game_plan.md`. **Development is frozen here** while
`builtin/luanti` has the attention. It is kept compiling and working as the
engine changes, the way undermine is. What it has not spent yet is in that
plan's "What needs one more idea each" and "Not in this plan"; nothing there
is waiting on anything else.


`doc/plan/aggregate.md`. No material id at all: every voxel holds a portion of
each material, the number of fields is the number of materials, and
overfilling is resolved by pushing material out -- after compaction, which
is the step before it. Light wood is fibre and air; gravel is rock and sand;
soil is sand and rotted fibre; and a mixture with nothing holding it
together is rubble and holds nothing up.

**The engine half is done.** The mesher works out a voxel's look with no id
at all -- thresholds over fields choose a base definition through the
registry's look rules, and per-voxel scalars refine it in the shader -- and
voxels are stored a plane at a time. Steps 1 to 4 below shipped, and the
measurement that was to decide whether planes stayed came out the other way
from the worry: meshing is slightly faster than it was on one word.

The pipeline it uses was already there: `CustomGeometryVertex` carries a
`tangent` the voxel mesher never wrote, and `DefineGeometry()` has the
switch to turn it on. Four floats per vertex, free, because voxel faces are
axis-aligned and a shader derives its tangent from the normal.

**Planes from the start**, rather than four materials in a word first: the
only thing a word-sized version buys is a performance comparison against a
feature set nobody would want to ship. Done, and the comparison against the
one-word build came out in the planes' favour anyway.

The shape of the engine work as it was decided in `doc/plan/aggregate.md`, and
what it turned out to be:

- **A parameterized mesher beside the plain fast one**, semi-generalized on
  purpose -- a hardcoded, parameterized set of modifiers rather than a
  language, so the set can grow without any existing game paying for it.
  Built as it was described.
- **One table per property, each with its own selector.** Built as **one**
  selector and one table, which is a tenth of the size: every property a
  voxel has already lives on its definition, so a selector that finds the
  *definition* answers all of them. The `FIELD` kind is a shift and a mask,
  which is what every existing game uses and was already exactly what the
  registry did -- so that sub-step needed no work at all.
- **Solidity is a derived scalar, thresholded** -- air stops being a
  material and becomes the case where every fraction is near zero, and
  buoyancy falls out of density rather than needing a rule. The game's, not
  the engine's, and it is in the game plan.
- **Four normalised per-voxel scalars reach the shader** in the `tangent`
  slot `CustomGeometry` already carries and the voxel mesher never writes.
  Built, with one correction: the tint is a *colour*, not a scalar, packed
  5-6-5 into its slot, because a tint of the light vanishes in sunlight.
- **Modifier roles**, in two families: geometry (`sag_top`, `sag_bottom`,
  `jitter`, `inset`) and surface (`tint`, `wetness`, `grain`, `gloss`,
  `speckle`, `emission`). A game picks four of the surface ones. Built
  except `jitter` and `inset`, which have no consumer yet.

The eight choices with a recommendation on each are at the end of
`doc/plan/aggregate.md`, all now answered, and the build order is
`doc/plan/aggregate_plan.md`:

1. **The payload, `tint` and `sag`** -- DONE. Modifier roles in the format,
   four surface scalars in the vertex tangent the mesher never used, and
   sag moving faces with the corner averaging a liquid already gets. Its
   consumer was meant to be luanti_client and turned out not to be: a
   palette tints the *texture* and everything reaching the vertex colour
   tints the *light*, which is the blocker that was already on record. So
   the tint became an albedo tint carried in its own slot, and the spike is
   this step's check.
2. **The look spike** -- DONE. `games/aggregate_look`, fifty hand-set
   samples. **Its answer: the base look chosen by a threshold carries
   nearly all of the signal.** Two mixtures on the same side of a threshold
   cannot be told apart by the grain, at any distance -- which is true of
   loose and packed sand in life too, and is why sand is dangerous, so the
   game gets to make the invisible danger its own. What does read: the
   albedo tint, the wetness, and the sag, which changes the silhouette.
   Step 5 wants three or four base looks along rock-to-sand rather than
   two. It also found two engine bugs and one wrong idea about the tint,
   which is the case for spiking.
3. **Per-property selectors and tables** -- DONE, and a tenth of the size it
   was written as. One selector and one table, not four of each: every
   property lives on a definition, so a selector that finds the *definition*
   answers all of them, and a world wanting a finer distinction in one
   property writes rules pointing at definitions that differ in that
   property alone. The `FIELD` sub-step needed no work at all -- indexing
   the registry by the id field already *was* it -- so the refactor the
   plan worried about did not exist. `games/aggregate_look` now stores no
   voxel type id at all. The one thing that did break: PolyVox carries a
   per-face material from the culling pass to the geometry pass and the
   mesher was putting the id role in it.
4. **Planes** -- DONE. A voxel's bits are stored a plane at a time: one
   array over a chunk per plane, materialised only once something writes
   it, carried through `merge_volume` and onto the wire as serialization
   format 4, with formats 2 and 3 still loading. PolyVox needed no patch.
   The mesher had to stop working in words and start working in
   `VoxelSample`, a voxel's planes read together, because the look rules of
   a world whose materials are a plane of their own are a question about
   another plane. **Measured on digger: meshing is slightly faster than
   before** (median 29.0 ms a chunk against 31.2), so the question of
   whether planes stay is answered. `games/aggregate_look` keeps its rock
   and sand fractions in a plane of their own. Not built: the
   module-facing `voxel_field()` registry, which has no consumer -- a game
   declares its planes in `set_format` -- and bulk plane access from Lua,
   which waits for the simulation that wants it.
5. **aggregate itself** -- BUILT to phase 5 and now FROZEN (section 6),
   planned in
   `doc/plan/aggregate_game_plan.md`: five materials, two state fields,
   derived properties, migration under pressure, thresholds for the look.
   Phase 1 is **undermine played again on mixtures** -- same terrain, same
   menu, same collapse -- so that the model is the only variable and the
   diff is the lesson. **Phase 1 is done.** It plays the same, three of
   undermine's rules came out better on the way (falling breaks bond rather
   than making rubble; wet is water in the mixture rather than a material;
   turf and leaves are two fields rather than two materials), and it found
   three places in the engine that still identified a voxel by its first
   plane's word -- the light flood, `merge_volume` and the sky-visibility
   rays -- all of which read a world of mixtures as air. **Phases 2 and 3 are done too**, so the plan's
   definition of a first playable is met: mixtures, water that migrates and
   is conserved, loose material that settles and bulks when it falls, a
   mixture with nothing holding it together that holds nothing, and a wood
   cycle -- cut wood dies, dead wood lying wet rots into the binder that
   makes soil. Three runaways were found and fixed on the way, all the same
   shape: **a local rule with no fixed point**. Water levelling by amount
   rather than by what each mixture holds; bulking unbonding the voxel it
   pushed into; and a life rule that asked each voxel a question it could
   not answer alone. Each showed up as one log line and none of them on
   screen.

   **Phase 4 is what the first playtest found**, and the two things it
   found are one shape: **the model says how much, and never how fast or
   how loosely.** Water has no rate, so a poured voxel of it is inside the
   ground within a second and nothing pools except on the water table; and
   a thin heap of humus stands as a voxel because nothing says a thin heap
   should not. The answer to the first is **conductivity** -- a cap on how
   much crosses a boundary in a step, finest-wins over the composition,
   which needs no new field because rock, sand and binder are already the
   size classes -- and it brings pooling, perched water over clay, seepage
   from a dug wall, runoff and gravel drains with it. The answer to the
   second is that loose material sinks, capacity scales with how full a
   voxel is, and a fine material fits in a coarse one's voids. The order
   and the reasoning are in `doc/plan/aggregate_game_plan.md`.

   **Phase 4 is built**, all five steps, and the one finding worth having
   out here rather than in the game's own plan is that **a rate needs a
   clock and the relaxation is not one**. The dirty queue looks at a voxel
   as many times within a tick as its neighbours dirty it, so a cap per
   visit is not a cap at all; what makes a tick a step is that water moves
   defer what they dirty to a queue emptied once per tick. Any rule here
   that wants a rate has the same problem and wants the same answer. The
   second finding belongs to the format: a model that says how much of a
   voxel is full owes the mesher that number, and `sag_top` was already
   there to take it -- water is drawn at the level it reaches, and the
   solids, whose definitions have no `sag_extent`, pay nothing.

The materials are **rock, sand, water, fibre and binder**, and the rule that
picked them is that **a material may not itself be a mixture**: dirt is
decomposed organic matter mixed with sand, and wood is fibre bound with
lignin, so both are aggregates and neither belongs in the list.

Splitting wood is what makes the list pay. It gives rot something to turn
fibre *into* -- fibre plus water plus time becomes binder, which is
composting -- and binder in sand is soil, so **tree, dead wood, rot, soil,
tree is one cycle in four fields** and dirt is derived rather than placed.
Cohesion is derived from what is there: binder holds a span, and water gives
sand some and takes it away at saturation, which is a damp sandcastle
standing and a soaked one not, for free.

Two fields join them that are **not** materials, because nothing moves when
they change: **`bond`**, how continuous the solid is, which falling destroys
-- so material that falls stays what it was and merely stops holding
anything up -- and **`life`**, whether the fibre here is alive, which is
what makes leaves and sawdust different voxels for the price of one field
nothing has to simulate yet.

What the model deliberately cannot say is **grain size** -- fluffy sand and
packed sand are the same sand. That is the loss the look spike says to take,
since they look the same in life too.

Steps 1 and 2 are a day or two each and stand alone; stopping after any step
leaves the tree better than it found it.

## 7. A definition's extra textures -- BUILT

Built as decided below, with both consumers in one go. What the shape of it
cost: nothing in the cube path, one `if` in the shape path, a count in the
serialization, and `VoxelQuad::tile` no longer clamped to the six.

In the Luanti client the index does the work rather than a second lookup
function: **tile 7 and over is the node's special tiles**, so a rooted plant
is a cube with a plant standing on it wearing `special[1]`, and a liquid's
faces come from the still and flowing tiles instead of from the ordinary
six. The registry logs how many definitions wear an extra texture -- seven
in devtest -- which is the line that says the path is reached at all.

Not seen on screen yet: a rooted plant in VoxeLibre, which is where the
magenta-and-cyan bars were. devtest was what was running; the count says the
definitions are built, and the kelp wants a VoxeLibre session to confirm.


An engine change, driven by two things in the Luanti client but landing in
`interface/voxel.h`, which is why it is here rather than only there.

A voxel's shape quads can only wear that voxel's own six textures
(`VoxelQuad::tile` is clamped to 0...5), and two recorded items need a
seventh: a `plantlike_rooted` node is a cube of ground *plus* a plant, and a
liquid is drawn by Luanti from its *special* tiles -- the animated ones --
where this client draws it from the ordinary six, so VoxeLibre's water wears
its still texture rather than its flowing one.

**Decided (the user's call, 2026-09-11): a variable-sized list of extra
textures on a definition.** An empty list costs nothing, and a definition
that has one is a definition that needed it. The shape, which is a
refinement of that rather than a replacement of what exists:

- `VoxelDefinition::textures[6]` **stays exactly as it is**, so the cube
  mesher's inner loop does not change and pays no indirection.
- `sv_<AtlasSegmentDefinition> extra_textures` beside it, for quads that
  want a texture of their own.
- The mesher's existing `quad.tile < 6 ? quad.tile : 0` becomes the
  dispatch: 6 and over is `extra_textures[tile - 6]`.
- `CachedVoxelDefinition` gains the matching list; the registry
  serialization gains a count and a version bump.

Do both users of it in one go; they are one change and two consumers. The
detail is in `doc/plan/luanti_voxels_plan.md`, sections 0a and 5.

## 8. What playing it turned up (2026-09-12) -- BUILT

Five things, each found by someone walking around in the world rather than
by a harness. Kept together here because the interesting part is that all
five were invisible to every automated run so far -- and that the last of
them took as long as the other four together, because the fault was in which
code path drew a thing rather than in what it drew.

- **No sound in aggregate or undermine.** `creak.wav` is out of both games
  and out of the repository's history; the generator no longer makes it.
  The creak stays written up in the plans as a thing that was tried.
- **The floor-rebuild hold looped at the world's edge.** Out past what the
  world has sent, the chunk under the player never arrives, so the hold
  froze for its two seconds, gave up, reset, and froze again forever -- and
  free move, which is the way out of anywhere, was held by the same check.
  Past the cap the hold now stays given up until a chunk actually turns up,
  and free move is not held at all. **A defence with a cap needs a rule for
  what happens after the cap, not only a timer.**
- **A world that binds surface modifiers drew no LOD geometry at all.** It
  is drawn with a technique that reads the modifiers out of the tangent, and
  the LOD mesher wrote no tangent stream, so everything past `lod_distance`
  -- 80 voxels by default -- was not drawn. It reads like a short fetch
  distance from inside the game: the world ends in a dome a few chunks out.
  The LOD mesher now carries the modifiers the way the full-detail one does,
  and takes the brightest light in each block rather than the light of the
  voxel that won the look, since a block with air in it is a block a face is
  lit through. **Two meshers for the same format is two places to teach
  every field the format gains.**
- **A rooted plant was three faults in a row**, and the last of them is the
  one worth keeping. A liquid drew a surface around the plant's base,
  because the plant's cube was part of a *shape* and a shaped voxel's
  neighbours draw their faces against it. The flag that says otherwise rode
  on the quad list itself -- and `VoxelDefinition.shape` walks every key of
  that table and throws on anything that is not a quad, so every one of the
  forty rooted definitions was thrown away and drawn as the placeholder
  cube. The exception was caught by the sandbox and logged as a bare
  "pcall(): Runtime error", which is why nothing pointed at it. **A flag
  smuggled into a list the engine parses is a flag that breaks the list.**

  With that fixed the base was visibly brighter than the sand beside it, and
  the value was not the problem: **a shape is lit by one flat value for the
  whole voxel, where a face is lit by the voxel in front of it with the
  occlusion of what stands around it.** In a field of plants nearly every
  sand top is occluded by a neighbour and the plant's own base was not. So
  the shape holds only the plant now and the cube is the voxel's own six
  faces, meshed and lit and culled as any solid voxel's. The plant itself
  does want the voxel above -- it stands in it -- which is
  `VoxelDefinition::shape_lit_from_above` (format version 12).

  **Half a day of this was spent reading a value that was right.** The
  question to ask of a thing that looks wrong next to its neighbours is not
  what number it was given but which code path gave it.
- **The client did not notice the server going away.** A closed connection
  left the socket readable at end of file, so every frame read zero bytes
  and logged "Peer disconnected" while the client went on playing a world
  nothing was updating. It says so once and shuts down now, which is what
  leaving a game does.

## Not in this list, and why

The Luanti client's own remaining items -- the PBR mode, object animation,
the world-to-screen path, older servers, the pause menu -- stay in
`doc/plan/luanti_voxels_plan.md` and are picked up after step 4, or during it
where they do not touch the data model. None of them blocks a merge, and
none of them is worth holding the engine work behind.

The exception, and it is now step 7 above: the extra textures a definition
can carry. That one is in this file because it changes `VoxelDefinition`,
which every game and the mesher read.

## 9. Luanti PBR (2026-09-12) -- BUILT; luanti_client FROZEN

**`extensions/luanti_client` is frozen (2026-09-12).** Not finished --
`doc/plan/luanti_voxels_plan.md` still lists what it is missing -- but parked
deliberately, and picked up again **once `builtin/luanti` reaches feature
parity and the client half is what needs doing**. At that point the two are
the same problem: the module's client is forked from this one, and what is
worth fixing in either is worth fixing with both on the table. Working on it
before then would mean improving code that the fork is about to copy.


Merged to master (PR #48): the Luanti client can draw its world with the PBR
shader instead of the unlit one, chosen by a checkbox in the connect dialog.
The four decisions and what doing it turned up are in
`doc/plan/luanti_voxels_plan.md` section 7.

The result looks very nearly like the vanilla render, for two reasons that
are both outside the shader: every node is given the same surface numbers, so
the spots and translucency the shader carries have nothing to do; and there
is no light in the scene at all, so the whole direct half of PBR is off.

The open question -- **the sun as a real directional light**, which Luanti's
skylight already bakes into the vertex colours -- now has an answer. Node
lighting is remapped so it answers only "am I underground": a curve in the
client's own `LIGHT_MAP` reads 11..15 skylight as fully outdoors and falls to
zero by 2, so a leaf canopy is handed to the shadow map, which is the one
thing the shadow map can do and node lighting cannot, while a cave stays dark,
which is the one thing node lighting can do and the shadow map cannot. The
remapped value is then the sun's gate directly, so the shader needs one
multiply and no thresholds of its own.

The whole of it -- per-node surface parameters derived from NODEDEF, a
sky-blue ambient, the light curve, the sun and moon with two shadow cascades,
and the two traps around the shadow pass and ALPHAMASK -- is
`doc/plan/luanti_voxels_plan.md` section 7c, and it is **BUILT**: `surface.lua`,
`PBR_LIGHT_MAP`, `VOXELSUNGATE` in both shader copies, and the sun with two
cascades. That section's "What it turned out to be" is the part worth reading;
the plan did not foresee that drawables cast no shadow unless told one by one,
that a brightness of 2 is nowhere near enough, or that the whole thing wants
HDR and a tone curve to work at all.

## 10. builtin/luanti: a Luanti game as a buildat module (2026-09-12) -- M0, M1, M2 BUILT

Run an unmodified Luanti game inside buildat_server, served to an ordinary
buildat_client, with no Luanti protocol anywhere: the game logic is Luanti's,
everything around it is buildat's. Plus `games/luanti_launcher`, a sample
game that only picks a world and hosts it.

The sizing decision: vendor parts of Luanti into the module, split along
what owns state. Vendored are the leaf, data-shaped pieces -- MapNode, the
VoxelManipulator, the node, item, craft and inventory definitions, noise,
light propagation, and in time the whole of `src/mapgen/` -- plus Luanti's
own `builtin/*.lua`, pinned. Written against buildat is everything stateful:
the environment, active objects, players, networking, the main loop. That is
allowed because buildat compiles each module to its own shared object and
dlopens it, so the LGPL lives in `builtin/luanti.so` and `buildat_server`
stays Apache. The surface still gets found by running it and seeing what is
nil, rather than by specifying Luanti's API up front.

Two things already in hand: `voxelworld` does skylight propagation
server-side, and `extensions/luanti_client` has the whole presentation half
-- mesher, shapes, formspec, texmod, HUD -- which ports across with the
protocol half thrown away.

Mapgen is vendored too, so the work there is not the 9.5k lines but the seam
that writes their output into voxelworld chunks. Staged singlenode, then a
Lua mapgen, then v7 -- an order, not a reduction in scope.

Written out in `doc/plan/luanti_module_plan.md`, with six milestones from "the
Lua environment boots" to the launcher. First testbed: devtest copied into
`cache/luanti/games/devtest`.

M0 and M1 are built and are PR #52: devtest loads, 499 items registered, and
its unittests mod is satisfied. M2 -- `set_node` against voxelworld, a
singlenode world, skylight, and a client that can see a floor -- is where the
module's shape gets decided, and as of 2026-09-12 it is **planned down to an
order of work**: every question it opened has an answer written into "M2 in
detail" there.

The ones worth knowing from here: Luanti's content ids and buildat's
`VoxelTypeId`s are **the same number**, because the module is the engine that
allocates them. `voxelworld`'s 32^3 chunk does not change; Luanti's mapgen
chunksize becomes 4, so a mapgen chunk is exactly one 64^3 section. The Lua
environment lives on the module's own thread, so `run_game()` and
`load_lua()` queue rather than execute. `core.set_node` goes through a
write-behind buffer flushed once per step, because `voxelworld::access()`
commits on exit and a commit is a chunk re-serialize. And **no client fork at
M2** -- the stock `builtin/voxelworld` client draws one generated
solid-colour texture per node, so a failure cannot be the mesher's fault.

Answering them is also what produced section 13.

M3's shape got settled the same day, in "The protocol, and the client" there:
the client half is forked from `extensions/luanti_client` by copying the leaf
files verbatim and rebuilding `world.lua` and `init.lua` from hand-picked
parts, rather than splitting the extension first -- managing a split would
add friction to the job actually at hand, and the two copies get reconciled
afterwards as a project of its own. `world.lua` loses about a fifth of itself
to `builtin/voxelworld`'s client, which already does the block handling and
the light flooding with LOD the extension never had. `PBRVoxel.glsl` is
forked a third time and allowed to diverge. Sky visibility stays client-side,
on a rule worth keeping: **the server does not spend CPU on moment-to-moment
client rendering, and style belongs to the game.** And the same rule settles
textures -- the server decides which voxel types exist, the client decides
what their pixels are -- which is also what `src/interface/voxel.h:112`
already assumed when it made a voxel's textures definitions rather than
references.

## 11. Does a fresh checkout build? (2026-09-12) -- CHECKED, IT DOES

Run on this machine -- Fedora 43, gcc 15.2.1, cmake 3.31.10 -- against a
`git clone` of `master` (b928fbd9) into a directory outside the working tree,
so nothing of the working tree's untracked state could help it:

- `cmake .. -DCMAKE_BUILD_TYPE=Debug && make -j16`: clean. It configures and
  builds the bundled Urho3D into `3rdparty/Urho3D/Build`, produces
  `bin/buildat` and `bin/buildat_server`, and the binaries' RUNPATH points at
  the fresh `libUrho3D.so`, not at any other tree's.
- `-DCMAKE_BUILD_TYPE=Release`, `-DBUILD_CLIENT=false` and
  `-DBUILD_SERVER=false` all configure and build too. The three documented
  option combinations are alive.
- It runs. The launch menu draws; `bin/buildat_server -m ../games/minigame`
  compiles the game's module at runtime and serves it; the client connects,
  transfers files, renders and screenshots. Same again with the Release
  build.

So there is nothing to fix, and the PR is a small one about blemishes:

1. **The compiler probe prints shell errors on every server start.**
   `check_runnable()` in `src/boot/autodetect.cpp:42` runs
   `<root>c++ --version` through `shell_exec()` and lets both streams
   through, so a first run says

       sh: line 1: .../Build/compiler/bin/c++: No such file or directory
       sh: line 1: .../compiler/bin/c++: No such file or directory
       c++ (GCC) 15.2.1 ...

   before the server has said anything of its own. Two paths that were never
   expected to exist, reported as if something were wrong. Redirect the
   probe's output and log the command that won.
2. **`README.md` still says `-DURHO3D_64BIT=true on 64-bit systems`.** The
   clean build never got the flag and is 64-bit.
3. **The dependency lists are short.** The yum line is
   `libX11-devel libXrandr-devel alsa-lib-devel`; the GL headers come from
   `libglvnd-devel` here and are not mentioned, and neither line names cmake
   or a C++ compiler. How short exactly is **not established** -- this machine
   has every dev package already installed, so the only honest check is a
   container with nothing in it, and the docker daemon is not running here.
   Worth doing before the list is rewritten with any confidence.
4. **`make -j4` does not limit the Urho3D sub-build.** `CMakeLists.txt:108`
   runs `cmake --build ... --parallel` with no number, so the sub-build
   ignores the jobserver -- hence the `-j0 forced in submake` warning -- and
   uses every core whatever the outer `-j` said. Fine on a 16-core desktop,
   not fine on the machine the `-j4` in the README was written for.

## 12. Client preferences (2026-09-12) -- BUILT

What the user sets once and every game honours: undersampling of the 3D
render with the UI left at native resolution, plus vsync, a frame limiter,
MSAA, and the sound volume and mute. The fence: the client owns how much the
frame costs and how loud it is, never what the art is. Shadow quality,
texture and material quality, filtering, draw distance and a per-type sound
mix are all art direction or gameplay and stay with the game.

Called preferences rather than settings because `core::Config` already *is*
the settings system -- paths, `server_address`, `boot_to_menu` -- and holds
deployment facts rather than taste. This is the other kind.

The sound half is enforced rather than cooperative, and free: Urho3D's
`Audio` returns `master * type` gain (`Audio.cpp:257`), so the client sets
`"Master"` and every game's own mixing multiplies under it. The one change
is that the sandbox wrapper stops letting a game write `"Master"` itself.

The decision that shapes it: the games make their own viewports in sandboxed
Lua, so the setting has to reach a viewport the game owns. It does that by
**asking rather than taking** -- one call,
`magic.set_preferred_viewports({viewport})`, that a game uses instead of
`renderer:SetViewport()` and that draws its scene at the size the user asked
for, composited under a UI that stays at native resolution. "Preferred" is
the word doing the work: these are the viewports drawn the way the user's
settings ask for, as against the raw `Renderer` ones which are drawn the way
the game says and nothing else. A game that does not call it renders as it does
today, which is the correct amount of authority for a client preference to
have and the same amount `buildat.set_ui_scale()` already has.

The engine reaching into `Renderer` and redirecting whatever it found there
was the alternative, and it loses: it has to guess what a viewport is for, it
has to re-check every frame because a game can change viewports at any time,
and a game with a scope render or a pixel-exact minimap has no way to ask for
one viewport at native resolution. Cooperative deletes the scan and the
guessing, and opting out is not calling it.

Configured in `user_path/preferences.json` -- today's
`cache_path/window.json`, moved because a preference is not cache and renamed
because it now holds more than the window -- and overridden by a
`-o k=v,...` command line flag that is not written back. `-c` ignores the saved file entirely so that a preference
someone left behind can never change a screenshot, and `-o` still wins so the
setting itself can be tested. A `-c` run is muted for the same reason.

Written out in `doc/plan/client_preferences_plan.md`, with the other workflows that
have to keep working listed there because each is a way this can go wrong
quietly.

Built on branch `client-preferences`: the preferences and their file, the two
calls, and all fourteen viewport call sites converted -- twelve games,
`games/bomber_drone`'s two viewports, and `extensions/luanti_client`'s
teardown. `user_path` came along because the file needs somewhere to live;
`-DPORTABLE` and the platform paths stay with the saves. The plan's own
header lists where the build differs from it.

## 13. Saves, paths and an object store (2026-09-12) -- BUILT

`voxelworld` persists nothing: `load_section()` is two TODOs and always
generates. `builtin/luanti` is what makes that untenable -- a Luanti game
expects its world and its mods' data to still be there -- but the feature is
the engine's and every game gets it.

A **save** is what the user names and picks; a **world** is a `voxelworld`
instance, and a save holds zero, one or many. Not the same word, which is
why this is not called world persistence: `voxelworld` already has a scene
reference per instance, so its store keys sections by (world, position) from
the start. Persistence is opt-in -- a game that never opens a save behaves
exactly as today, which is all of them right now.

Two base directories, sorted by one rule: the cache is what the program can
recreate by itself, the user path is what the user made, chose or fetched
deliberately. `$XDG_DATA_HOME/buildat` and `$XDG_CACHE_HOME/buildat` on
Linux, with the Windows and macOS counterparts, and Android later. Of the
900 MB in today's `cache/`, 898 stays; what moves is the Luanti content, the
server address list and the window preferences.

Modules keep their data in a namespaced key-to-blob store backed by sqlite,
vendored and linked into `buildat_server_core` beside zlib and zstd, with
`builtin/storage` the only thing that includes `sqlite3.h`. Not files, because
module data comes in shapes a filesystem is bad at; not SQL, because Luanti's
mod storage is get/set and that has been enough. `open()` and `create()` are
separate calls so a typo in a save name cannot silently start a new game.

`voxelworld`'s value is what `serialize_volume_compressed()` already
produces, and the save also carries the serialized `VoxelRegistry` -- which
makes a save self-describing and settles voxel id stability for every game at
once.

Written out in `doc/plan/world_persistence_plan.md`. Reading Luanti's own world
format is an importer, one direction, and it is M7 of the module plan rather
than part of this.

Built on branch `saves`, steps 1 to 3: the paths and `-DPORTABLE`, the
vendored sqlite and `builtin/storage`, and `voxelworld` reading its sections
back. `games/digger` is the one game that keeps a world. Steps 4 and 5 --
`builtin/luanti` using it, and the Luanti importer -- stay with the module.
The plan's own header lists where the build differs from it, of which the
two that matter are a row per chunk rather than per section, and a new
`core:shutdown` event, since nothing reached the modules after the main loop
ended.

## Third round, step 1: voxelworld's name table, format tag and modified flag -- BUILT

`doc/plan/world_persistence_plan.md` step 4, and it changed what an earlier
step had settled: the save's `VoxelRegistry` used to *replace* the one the
game had just built, so that "the numbering a save was written under is the
numbering it is read under". That is backwards. The game is the only thing
that can decide whether a name still means what it meant, so the running game
owns the numbering and the save stores names -- which is what Luanti has done
for years, per MapBlock, and one table per world is the same idea more
cheaply.

What it cost, beyond the table itself: a six-byte header on each chunk row
carrying the format it was written in; `migrate_volume()` and
`remap_volume_ids()` in `interface/voxel_volume.h`, which are where the rule
that the engine moves data and never reinterprets it actually lives; a
`VoxelFormat::roles()` list that `validate()` now shares, so a role added to
the format cannot be forgotten by either; and a modified flag per section, so
a run that only walks through a world writes nothing.

The check was a reorder: digger's 108-section save read by a build whose
registration order had two voxel types swapped. 2 of 7 names go through the
table, no section is generated, all 108 are written back, and all 864 chunk
blobs come out byte-identical under an in-memory numbering that is not the
save's. What it also turned up is that digger's own generator is not
deterministic between runs -- trees straddle section boundaries and
`merge_volume()` refuses to overwrite, so which section generated first shows
in the result. That is why the check is a round trip of one save and not a
comparison of two generated ones.

Riding along: `games/digger` uses the ids `add_voxel()` returns instead of
the literals 1 to 7 with `// id 1` comments keeping them in step.

## Third round, step 2: builtin/luanti keeps its world and its clock in a save -- BUILT

`doc/plan/world_persistence_plan.md` step 5a. `run_game()` takes the
`storage::Save*` instead of a world path and derives `<save>/luanti/` from
it, so "the world is the save" is what the interface says rather than
something the launcher has to get right. `create_world()` hands the save to
`voxelworld` between building the registry and lighting the world. The clock
goes into the module's own store in the save, read before the mods load --
a mod can ask the time while it loads -- and written at `core:shutdown`.

Two things it turned up:

- **The module asks the world to save after flushing its node writes.**
  `core:shutdown` reaches subscribers in module load order, so voxelworld's
  own handler may have run already and the writes still in the buffer would
  never land. Asking twice costs nothing now that a section is written only
  when it changed.
- **A check that ages the world is a check that breaks what it checks.**
  `check_map.lua`'s clock check rolled the day forward and put only the hour
  back, which was invisible while the clock reset every start. It is
  relative to where the clock stands now, and puts the whole of it back.

devtest: 390 node types, a 14.7 KB name table, 28 sections read back with
none generated, and the clock down to the fourth decimal.
