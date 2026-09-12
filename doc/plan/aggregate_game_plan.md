# aggregate: building the game

**FROZEN (2026-09-12).** Phases 1 to 5 are built and the game is playable.
Development is parked while `builtin/luanti` has the attention; the game is
kept compiling and working as the engine changes, the way undermine is. What
it has not spent is in "What needs one more idea each" and "Not in this
plan"; nothing there waits on anything else. See `doc/plan/master_plan.md`
section 6.

How `games/aggregate` gets made and got to a playable state. The engine it
stands on is done -- `doc/plan/aggregate_plan.md` steps 1 to 4, all shipped --
so everything here is the game.

Read `doc/plan/aggregate.md` for why a mixture model at all.

Kept out of git (`/local`) with the other plans.

## The parity target, and why it comes first

**Phase 1 is undermine, played again on mixtures.** The same terrain, the
same menu of structures, the same digging and placing, the same two movement
modes, the same collapse when a pillar is cut, the same three view modes.
Nothing new for the player.

That is the point. The scenario works, so reusing it means **the only
variable is the model underneath**, and what the mixture model costs and
buys shows up as a diff rather than as an argument. It also means phase 1
has a finish line somebody else can check: play both, notice nothing.

So phase 1 starts by **copying `games/undermine` to `games/aggregate`** and
then replacing its material layer. undermine stays frozen and playable
beside it, which is what makes the comparison possible at all.

## The materials

`doc/plan/aggregate_plan.md` settled the rule: **a material may not itself be a
mixture**, and the test is whether the game's own processes take it apart.
Applying that rule to wood -- which is fibre bound with lignin, and is
therefore an aggregate like everything else -- gives five rather than four.

| field | bits | what it is |
|---|---|---|
| `rock` | 4 | coarse mineral. Nothing a player does divides it |
| `sand` | 4 | fine mineral |
| `water` | 8 | the only fluid. Air is the absence of everything |
| `fibre` | 4 | structural organic matter: wood fibre, leaf, root, straw |
| `binder` | 4 | what can hold a mixture together: lignin in wood, humus in soil, cement in concrete, clay |

**`binder` earns its place back** -- it was struck from an earlier draft as
"a function wearing a material's clothes", and that was right when it was
only a function. It is a material once you can say what it is made of and
where it comes from: **rot makes it.** Fibre plus water plus time becomes
binder, which is composting, and binder mixed into sand is soil. So the
whole cycle -- tree, dead wood, rot, soil, tree -- is four fields and one
conversion, and dirt is derived rather than placed, which is what
`doc/plan/aggregate_plan.md` asked for and could not quite reach with four
materials.

What they make:

| | |
|---|---|
| gravel | rock, unbonded |
| bedrock, stone | rock, bonded |
| sand | sand |
| concrete, brick | rock and sand with binder, bonded |
| timber | fibre and binder, bonded, dead |
| a tree | the same, alive |
| leaves | a little fibre, alive |
| sawdust, mulch | a little fibre, dead, unbonded |
| soil, dirt | sand and binder, a little fibre |
| mud | soil with water |
| rubble | any solid, unbonded |
| dirty water | water with a little of anything |

## The two fields that are not materials

The composition of a plank and of a heap of sawdust is the same. So is the
composition of a living branch and a dead one. Neither difference is a
material, and calling them materials would mean a tree dying moves mass
that does not move.

- **`bond`, 4 bits.** How continuous this voxel's solid is. A plank, a rock
  face and cured concrete are bonded; sawdust, gravel, loose soil and fresh
  mix are not. **Bond is what falling destroys** -- which is undermine's
  "everything that falls becomes rubble" as a property rather than as a
  material swap, and it is the better version, because dirt that falls
  stays dirt and only stops holding anything up. Bond is made by growth, by
  curing, and by nothing a player can do by dropping things.
- **`life`, 4 bits.** Whether the fibre here is alive. Live wood draws water
  up and keeps its bond; without water it dies; dead fibre with water rots.

`life` is also the answer to the leaves problem, and it is worth adding in
phase 1 even though nothing simulates it until phase 3: **a little fibre,
alive, is leaves; a little fibre, dead, is sawdust.** Without it the two are
the same voxel and a forest floor is indistinguishable from a workshop
floor. One field, written by the generator, read by a look rule, costing no
simulation at all -- which is the cheapest way to buy a whole base look.

## The storage

One plane of the game's own, 32 bits, beside the engine's:

    rock 4 | sand 4 | fibre 4 | binder 4 | water 8 | bond 4 | life 4

Four bits a solid because **the look spike said which side of a threshold a
mixture is on is what reads**, and the levels are for the arithmetic rather
than the eye. Eight for water because water is the one that migrates and has
to conserve; sixteen levels cannot carry a flood without losing it.

If a solid at sixteen levels turns out too coarse for the simulation,
widening it is a format change and not a rewrite. That is what planes are
for, and it is the first thing to reach for rather than the last.

The engine's own plane carries what it always does -- skylight, and the
modifiers below. No voxel type id is stored anywhere: the look rules answer
that, which `games/aggregate_look` already does.

## What the engine is told

**The look rules**, in order, first match wins. The order is the design:
water is checked first so that a bit of wood in a lot of water is dirty
water and not a soggy plank.

    water > 1/2 and solid < 1/4          -> water
    fibre >= 1/4 and life > 0            -> trunk
    fibre > 0 and life > 0               -> leaves
    fibre >= 1/4 and bond > 1/2          -> timber
    fibre >= 1/4                         -> mulch
    binder >= 1/4 and rock+sand >= 1/2 and bond > 1/2 -> concrete
    rock >= 1/2 and bond > 1/2           -> stone
    rock >= 1/2                          -> gravel
    binder > 0 and sand >= 1/4           -> soil
    sand >= 1/4                          -> sand
    rock+sand+fibre+binder >= 1/8        -> rubble
    -                                    -> air

Eleven rules and twelve base looks, which is the spike's "more base looks
than you think" answered concretely. Each is an ordinary `VoxelDefinition`
with its own texture, and every property the engine asks -- solidity, what
stops light, what draws a face -- comes off the definition the rules picked.

**The modifiers.** `tint` and `wetness` bind; both read on screen. `sag_top`
binds to the water fraction, so a partly filled voxel draws its surface at
the right height for free. Two surface slots are left unbound: the spike
found grain does not read and gloss reads weakly, and spending a slot on
either would be spending it on nothing.

## Phase 1: parity -- DONE

What it is: undermine, in mixtures, with nothing new. Built; `check.txt`
walks it -- spawn tunnel, a dig, a chamber placed from the menu that brings
its own roof down, and the three views over it.

**What the port found, which is the reason for doing it this way.** Three
places in the *engine* still identified a voxel by the first plane's word,
and a world whose looks come from rules over its own fields therefore read
as air everywhere: voxelworld's light flood and `merge_volume`, and
`cast_voxel_rays`, which is how a client works out how much of the sky it
can see. The first made every tunnel as bright at the far end as at its
mouth; the second made every surface reflect an unobstructed sky. Both are
fixed and both were invisible until a game asked the question -- which is
what a parity port is for.

**Three rules came out better than undermine's rather than the same:**

- Falling breaks the bond instead of turning what fell into rubble, so soil
  that falls is still soil and rock that falls is gravel. That is what
  undermine's playtest asked for and could not have.
- Wet is water in the mixture, not a `wet_dirt` material: the tint darkens
  it and it loses half its capacity. That is the thing the user objected to
  in undermine -- "a voxel material id just for the sake of the mesher" --
  gone.
- Turf is soil with something alive in it and leaves are living fibre with
  no mineral under it, which is two fields saying two things rather than two
  materials.

**And one cost, honestly:** a view mode needed the `param` role after all.
The plan said a view would be "a different set of look rules over the same
voxels", and the rules part is true -- three definitions instead of
undermine's sixteen variants on each of twelve materials -- but the gradient
itself still rides on param-indexed variants, because the view technique
draws the vertex colour and nothing else, and the vertex colour is reached
by a variant or by the colour role. The two simulation numbers are adjacent
bits so that a view can bind both as one param, which is undermine's own
trick kept.

**A trap worth writing down:** the first thirty seconds of a run look wrong.
Until the sky-visibility marching settles, every glossy speck reflects a sky
it cannot see and a tunnel is full of glints. Two screenshots taken at
different points look like a rendering bug and are not; `check.txt` waits.

### The steps as they were planned

1. **Copy `games/undermine` to `games/aggregate`** and get it running
   unchanged. A commit on its own, so everything after it is the diff.
2. **The format and the look rules** as above, replacing the voxel ids.
3. **The generator writes fractions.** digger's terrain, as layers of
   mixture: rock below, gravel and sand through the middle, soil where
   binder meets sand at the top, water in the hollows, trees as columns of
   live fibre with a cloud of thin live fibre over them. There is no dirt to
   place and no leaf voxel to place.
4. **The structures menu**, unchanged in shape: a cathedral, a bridge, a
   mineshaft, each now written as mixtures -- stone is bonded rock, timber
   is bonded dead fibre with binder, brick is bonded rock and sand with
   binder.
5. **Support and load**, undermine's relaxation unchanged in shape, with its
   constants derived instead of looked up:
   - `solid` = rock + sand + fibre + binder
   - `density` = each fraction times its own, plus water
   - `cohesion` = bond times (binder plus fibre), which is what makes a
     mixture hold itself together
   - `span` = cohesion, so unbonded material spans nothing and undermine's
     rubble rule is this rule with the numbers filled in
   - `capacity` = cohesion plus rock's own share, since a bonded stone pier
     carries what a bonded timber one does not
6. **Falling breaks bond** rather than turning a material into rubble. Dirt
   that falls is still dirt; it just holds nothing up, which is what
   undermine's playtest asked for and could not have without this.
7. **The three view modes** carried over -- load, support, danger -- and
   they get simpler on the way. undermine drew them by rebuilding the
   registry with sixteen param-indexed gradient variants per material;
   here **a view mode is a different set of look rules over the same
   voxels**, pointing at definitions that are the gradient. Nothing about
   the voxels changes and nothing is re-sent -- only `set_look_selector()`
   and a remesh, which is what the rules were built to make cheap.

Done when both games play the same. The check is the one this tree already
uses: a screenshot sequence per game, and the two read alike.

## Phase 2: compaction, voids, and water -- DONE

Built, with one thing the plan did not have and could not have done without.

**Field capacity.** The plan said water migrates down, sideways and under
pressure; it did not say what stops it. Without an answer every voxel drains
into the one below forever and a world of damp ground never settles -- the
measured version of that was sixty-five thousand voxels a tick of churn and
two million writes for one collapse. What stops it is that **a mixture holds
water against gravity**, up to a capacity that scales with how much solid
there is to hold it, and only what is over that moves. Free water holds
nothing and falls as it should. Sideways, two materials settle at their own
capacities rather than at the same number, which is what stops water
sloshing between a sand bank and a soil one.

**Bulking, and what it taught.** Taking the bond off the voxel that *receives*
pushed material drops that voxel's own limit, makes it overfull in turn, and
unbonds the world one voxel at a time. Loose material only goes into
something already loose or empty.

Both of those are the same lesson and it is worth stating once: **a local
rule needs a fixed point, and the way to find out whether it has one is to
place a chamber and read the tick counter.** Neither was visible on screen;
both were obvious in one log line.

**Not built: water does not climb.** Pressure wants a head, a head wants
either headroom above "full" or a walk up the column, and neither fits in
the eight bits this game gives water. A flooded shaft fills from the bottom
and stops at the level it is poured to.

### As it was planned

The first thing that is not undermine, and the reason the model exists.

**Every fraction is solid volume, not heap volume.** A voxel of loose sand
at `sand = 9/15` is six fifteenths void, and that void is where water goes.

**Each material has a void it keeps**, which is the detail that makes this
worth simulating rather than asserting: sand and gravel still hold water
when fully compacted, because grains do not fit together. Wood does not, and
neither does cured concrete.

| material | loose | compacted | void when compacted |
|---|---|---|---|
| rock (gravel) | ~0.55 | ~0.65 | ~0.35 |
| sand | ~0.55 | ~0.65 | ~0.35 |
| fibre | ~0.15 (mulch) | ~0.90 (timber) | ~0.10 |
| binder | ~0.50 | ~1.00 | ~0.00 |

Three rules, in this order:

1. **Compaction** comes first, and it is what a load does to loose material:
   the same solid in fewer voxels. A column under weight settles, and what
   it settles to is set by the material's own compacted void, not by a
   single number.
2. **Overfull is resolved by pushing material out**, decided and on record:
   a solid that is overfull is an error, not a compaction, because
   compaction is the step before it and has already happened. Water goes
   first, because it is the mobile one; if the voxel is still overfull, the
   solid goes to whichever neighbour has room.
3. **Water migrates** down, sideways, and under pressure up, through
   whatever void there is. It is the first thing in either game that sweeps
   a volume rather than relaxing around an edit, so it is the first real
   customer for bulk plane access -- which is the one piece of the plane
   work deliberately left unbuilt, waiting for exactly this.

What the player sees out of it: a sandcastle that stands damp and slumps
soaked; a gravel bed that drains where soil holds; a flooded mine whose
floor gives way under him.

## Phase 3: the wood cycle -- DONE

Life is **how far living wood is from water it can drink** -- the support
relaxation again, and for the same reason: whether a leaf is part of a
living tree is a question about the way back to the ground, and no voxel can
answer it alone. It only ever goes down, so wood does not come back to life.

What that buys, in the order the plan asked for it: a tree standing in wet
soil is alive; cutting a trunk browns everything above the cut; a felled
trunk stays dead; and dead fibre lying wet rots into binder, which in sand
is soil. A fallen tree becomes ground.

**Not built as described: a tree does not pump water to its leaves.** The
draw is implicit in the distance rather than being a quantity moved, which
is enough for the ecology and avoids a per-voxel cost that a forest pays
every tick whether anything is happening or not. A real pump wants a clock
and the clock is spent on the rot.

**What the phase cost, and it is worth knowing:** two of the three attempts
at the life rule ran away. A per-voxel hydraulic test made every leaf with
air under it die; a per-voxel sip made every live voxel rewrite its chunk
forever. The relaxation is the third, and the thing that distinguishes it is
that it settles.

### As it was planned

The ecology, and the thing five fields buy that four could not.

- **A live tree draws water** from the ground through its trunk to its
  leaves, a little per tick.
- **Wood that cannot get water dies**: `life` falls. A cut trunk is dead
  wood the moment it stops being connected to a root.
- **Dead fibre plus water plus time rots**: `fibre` becomes `binder`. Which
  is composting, and it is why a fallen tree becomes soil rather than
  vanishing.
- **Soil is where that binder ends up**, mixed into sand -- so a forest
  makes its own ground, and cutting the forest eventually stops making it.

None of this needs a field the phase-1 format does not already have, which
is the test of whether the material list was chosen right.

## Phase 4: what the first playtest found -- BUILT

All five steps are in, in the order below, and the three things the plan did
not know are written under "What building it found". What is left out on
purpose is the `humus` base look, and why is at the end of the humus section.

Two things, and they turn out to be one shape: **the model says how much,
and never how fast or how loosely.** A thin heap of humus stands because
nothing says a thin heap should not; water vanishes into the ground because
nothing says how fast it may cross. Both are rules with a quantity and no
rate or no floor.

The order to do them in, and each is a commit that leaves the game playable:

1. **Conductivity**, because it is the one that changes what the game feels
   like. A cap on how much water crosses a boundary in a step, finest-wins
   over the composition. Pooling, seepage, runoff and drains all come out of
   it at once.
2. **Capacity scaled by fill**, which is two lines and is wrong today
   whatever else happens: a voxel that is four fifths void carries as if it
   were solid.
3. **Loose solid sinks**, the complement of the bulking that is already
   there. This is what makes the humus stop standing.
4. **Grading in `packed_limit()`** -- a fine material fitting in a coarse
   one's voids -- which is what lets the ground absorb the humus rather than
   only pass it along, and which explains the recipes instead of leaving
   them hand-tuned. Last because it is the one that moves numbers the rest
   of the game is balanced against.
5. **Capillary rise**, once conductivity is in and its cost is known.

**Getting to where it can be seen.** Pooling needs terrain with a hollow in
it, and walking there each time is most of the test. `PLACES` in
`main/client_lua/init.lua` is a list of positions with `G` going to the next
one, seeded with the pool site at (-79, 62, 167). Add to the list rather
than to the key.

Done, for phase 4: water poured on soil makes a puddle that soaks away at a
rate you can watch, clay perches it, gravel drinks it, a cut tree's remains
end up in the ground rather than standing on it, and a dug wall in a wet
layer weeps.

### What building it found

**A rate needs a clock, and the relaxation is not one.** This is the whole
of why the first conductivity did nothing. The dirty queue is not a sweep:
a voxel that moves water dirties its neighbours, they dirty it back, and it
is looked at hundreds of times within one tick -- so a cap per *visit* let
a voxel of water into the ground as fast as ever. What makes a tick a step
is that anything a water move dirties goes to a queue of its own
(`m_water_next`) which is emptied into the dirty one once per tick. That is
the general shape of it: **anything in this game with a rate has to say
what a step is, and the relaxation will not say it.**

Below the quantum, a rate has to be a frequency. Turf passes 7 of 255 a
second, which is a quarter of a unit a tick and rounds to nothing. So a
boundary too slow to move the quantum every tick opens on the ticks where
its running total crosses another quantum -- exact on average, no per-voxel
accumulator, and deterministic where a dice roll would not be.

**A part-full voxel was drawn full.** Found immediately on seeing the first
pool: a voxel holding a tenth of a voxel of water was a cube of water, so
pouring looked like building. The fix was already in the format and unused
-- `sag_top` is bound to how far from full a voxel is and water's
definition is the one with a `sag_extent` -- and it costs the solids
nothing, since a definition with no extent does not sag. **A model that
says how much of a voxel is full owes the mesher that number.**

**Capacity scales by packing, not by fill.** The plan said fill; fill would
have changed every recipe's numbers, since a recipe is at its packing limit
and not at 15. Scaled by `solid / packed_limit` instead, the recipes are
exactly where they were and only heaps below their limit lose anything --
and compacted ground is stronger than loose ground, which is why it is
compacted.

**Grading had to be per material to buy what it was for.** As a scalar,
`packed_limit()` says a sand voxel full of sand has no room, which is the
opposite of the point: what fits in a sand bank is something *finer*. A
transfer moves one material, so it asks `room_for_class()`. The scalar is
still there for "is this voxel overfull", where the proportions are fixed.

And the payoff the plan predicted is real: walking the classes coarsest
first, each fitting into what the coarser have not taken, **derives the
recipes**. Sand packs to 10, and sand 8 with binder 5 between its grains --
which is the soil recipe -- packs to 14. Nothing was tuned to make that
come out.

**Testing it needs places to stand.** `PLACES` with `G`, and a place with a
`look` is a viewpoint that turns free move on, since the spawn overlook is
over a pond and gravity put the camera on the bottom of it. Pouring water
also needs no aim now: with water selected and nothing pointed, right
button puts it a couple of voxels in front of you, because water is the one
thing you pour at nothing in particular.

### The humus voxel: `binder 3, water 3%, bond 0`

**What it is.** The end of the rot chain. Leaves are fibre 2 and binder 1;
cut off from water they die, fall (which takes the bond to 0), and rot, and
each rot step turns a fibre into a binder. Two steps later there is no fibre
left and three binder, with a little water it kept. So it is **humus** --
leaf mould, the dark crumbly stuff a forest floor is made of. The user's
"splatter of juices from the tree" is the same thing seen at the moment it
happens.

**What the model currently says about it**, which is the problem:

| | |
|---|---|
| solid | 3 of 15 -- **four fifths of the voxel is void** |
| packed limit | 15, because pure binder packs solid, so it has no excess and never moves |
| span | 0, so it holds nothing over a gap. Right |
| capacity | 30, which is half of soil's. **Wrong** |
| density | 0. Weightless |

So it stands there: a voxel that is 20% full, carrying half of what packed
soil carries, and never moving because nothing in the rules says a thin heap
should not stand.

**What should happen, in the order the rules should be written:**

1. **Loose solid sinks.** `migrate_solid` only moves solid *out of* a voxel
   that is over its limit; the complement is missing. A voxel with no bond
   should also fall *into* whatever room is under it -- which is the same
   transfer driven by the receiver's room rather than the giver's excess. A
   spoonful of leaf mould on the ground is not a cube standing on the
   ground, it is part of the ground.
2. **Binder fills the voids of what it lands in**, which is what lets the
   ground absorb it. This is the same observation the whole packing model
   rests on and it is not in the limit yet: a fine material fits between the
   grains of a coarse one, so a sand voxel that is full *of sand* still has
   room for binder. That is why soil (sand 8, binder 5) is denser than sand
   (10) and why concrete is denser than gravel -- **grading** -- and getting
   it into `packed_limit()` would explain the recipes instead of having them
   hand-tuned to it. It is also exactly the cycle closing: humus sinks into
   sand and the sand becomes soil.
3. **Capacity scales with how full the voxel is.** `mix_capacity()` adds up
   material units and never asks what fraction of the voxel they are, so a
   voxel that is four fifths void carries as if it were solid. A thin heap
   should carry almost nothing whatever it is made of.

**And when the ground cannot absorb it** -- bedrock under it, or ground
already fully graded -- it stays, which the user allows. Then it should read
as what it is: a **humus** base look, binder-dominant with no mineral and no
bond. One rule and one texture, and it makes a forest floor read correctly
once rot runs at scale.

**Not built, and the reason is that the other three rules took the need
away.** A binder-only voxel reads as soil today, which is close enough to
leaf mould to pass, and with sinking and grading in, one rarely stands
around long enough to be looked at. It is one rule and one texture whenever
a forest floor looks wrong; it is not worth a texture before then.

**Not to do: a minimum fill to count as structural.** It would fix the
symptom and it is a blunt instrument; sinking and fill-scaled capacity are
the same rules already in the game doing the work, and they are right for
gravel and sand too.

### Water has no rate, and that is why nothing pools

**The symptom.** Pour water on turf and the turf wets and the water is gone.
Only at the water table does a pool stay, and then only because the water
under it is already water.

**The cause, in numbers.** A voxel of water is `loose_water` 255, because a
voxel with no solid holds nothing against gravity. The turf under it has a
void of 34 and 8 in it already, so there is room for 26 -- and
`migrate_water()` moves `min(free, room)` with **no cap on how much crosses
in one step**. So a tick fills the turf to saturation, the next tick sends
the rest sideways into neighbours that each have room for another 26, and a
voxel of water is inside the ground within a second.

The physics of *how much* is roughly right -- a cubic metre of water does
saturate several cubic metres of soil -- but with no rate it happens at
once, and what the player sees is water vanishing rather than soaking in.

**What is missing is conductivity**: how fast water crosses a boundary, as
against how much room there is on the other side. That is one number per
mixture and it is what tells the user's three cases apart:

| | void | conductivity | what happens |
|---|---|---|---|
| coarse sand, gravel | large | high | drains like a drain; only ever looks damp |
| fine soil | small | low | saturates, then water pools on it -- **because the flow is slow, not because the water table is there** |
| clay | ~none | ~none | pools at once, and perches whatever is above it |

**Where the number comes from, and this is the good part: composition
already says it.** The model separates rock, sand and binder, and those *are*
size classes -- the one thing it refuses to model is the size *within* a
class. And the physics is that **the finest material present sets the rate**,
because the smallest pores throttle the flow: a little clay in gravel ruins
its drainage, which no average would give. So conductivity is a
finest-wins function of the composition and needs no new field.

### What else that buys, for free

Each of these falls out of a per-boundary rate cap plus what is already
there. They are listed because they are the reason to do it this way rather
than special-casing pooling:

- **A perched water table.** Clay under topsoil saturates the topsoil
  because the water cannot get past it, with the real water table far
  below. The user's own second case, and it is per-voxel conductivity doing
  it.
- **A seepage face.** Dig into a saturated layer and the wall weeps: the
  tunnel voxel is air with room, the soil beside it has water over field
  capacity, so it flows out. That is the mining behaviour this game exists
  for and nothing has to be written for it.
- **Runoff.** Water arriving faster than the ground takes it spreads
  sideways faster than it sinks, so on a slope it runs downhill and collects
  in the hollows rather than soaking in where it fell.
- **Preferential flow, which is a dig.** A rubble column or a gravel backfill
  has high conductivity, so water finds it: a French drain works because the
  rules work, not because drains were implemented.
- **Compacted ground puddles.** Compaction already raises the packed limit;
  it should lower conductivity with it, and then a trampled path holds water
  where the field beside it does not.

### What needs one more idea each

- **Capillary rise -- BUILT** (in phase 4, as the last step of
  `migrate_water()`). Kept here because the reasoning is: water climbs *into*
  fine material above a wet layer,
  which is why the ground above a water table is damp. The model has no
  upward movement at all. It is not pressure and does not want a head: it is
  diffusion towards field capacity, it only moves water from wetter to
  drier, and it stops when both are at capacity -- so unlike pressure it
  has a fixed point. Cheap, and it is what makes a dry world above a wet one
  look right.
- **Evaporation -- BUILT (2026-09-12).** Without it a world only ever gets
  wetter. A slow loss from voxels that see the sky, which is a number
  voxelworld already keeps.

  Two things it needed that the sentence above does not say. **A rate per
  voxel wants a clock per voxel**: the slow queue's clock is how often a
  voxel comes up in it, which depends on how much else is in it, so a lone
  puddle on that queue would be gone in a frame -- evaporation has a queue of
  its own where each entry carries the tick it is next due. And **a voxel's
  own skylight is the wrong number to ask**: voxelworld gives a voxel that
  stops light a skylight of zero, and everything with water in it stops
  light, so the first build evaporated nothing anywhere. It is the air above
  that carries the number, which is also what evaporation actually is.
- **Infiltration falling as the soil wets -- BUILT (2026-09-12).** The real
  curve: dry soil drinks fast by suction and slows to its saturated rate, so
  a shower soaks into a dry field and stands on a wet one. It is the
  receiver's saturation that scales the boundary's rate, four times the
  saturated rate when bone dry, and it is safe where a head is not for the
  reason capillary rise is: scaling a *rate* cannot change where the water
  ends up, only how fast it gets there.
- **Liquefaction.** Saturated loose sand losing its strength is already in
  the capacity, gradually. The dramatic version -- it goes all at once when
  something lands on it -- is a game decision, not a physics one.

## Phase 5: the building menu, thumbnails and placement -- BUILT (2026-09-12)

Three things at once, because they are one flow: pick a building from a menu
that shows what it looks like, move it around the world, put it down.

### What is in the way

**The structures live only on the server.** `main.cpp`'s `build_chamber()`
and friends are C++ loops that write straight into the world; the client has
never seen a structure's shape. Both the thumbnail and the preview need it,
so the shape has to come over the wire. Duplicating the four builders in Lua
would be two copies of the same thing to keep in step, which is worse than a
packet.

**There is no render to texture anywhere in buildat.** No `RenderSurface` in
the sandbox, no render-target `Texture2D`, nothing in `src/lua_bindings`.
This is the same gap `doc/plan/luanti_voxels_plan.md` section 12 deferred, so
building it here unblocks that too.

What is already there and does not need work: `Scene.new()` is in the
sandbox, so a thumbnail can have a scene of its own; `BorderImage.texture`
takes a `Texture` so a button can wear one; `ui_utils.vertical_menu`'s
`menu:add()` already accepts a ready-made button instead of a label, so an
icon button needs no change there; `buildat.set_voxel_geometry(node, data,
voxel_reg, atlas_reg, use_skylight, cb)` builds voxel geometry into any node
off the thread pool, which is the preview and the thumbnail both.

### The shape protocol

- client -> server `main:request_structure_shape {name}`
- server runs the same builder at origin `(0,0,0)`, and replies
  `main:structure_shape {name, rel_lc, rel_uc, w, h, d, words}` where `words`
  is the flat voxel-word array of that box -- the same thing a mapblock is,
  which is what `pack_voxel_volume` already takes as a source.

Building at a zero origin is what makes the client able to do the arithmetic:
it learns where the builder's origin sits inside the box (`-rel_lc`), so to
centre the thing on an X/Z and sit its bottom on a Y it sends back the origin
that puts it there. No new knowledge on either side.

A structure carries its own air (`MIX_AIR` voxels clearing the footprint), so
the preview has to skip those or it draws a solid box. Filter by
`band_of(v) ~= 0`, the same test `occupied_at()` uses.

Size: a cathedral is about 20x30x14, so ~8400 words, ~34 KB before the
network layer compresses it. Fetched once per structure and cached; requested
for all four at connect rather than at menu-open, so the menu never waits.

### Render to texture: one binding, not a class hierarchy

The lazy version is a single function rather than exposing `RenderSurface`,
its update modes and the texture format enums to the sandbox:

    buildat.render_scene_to_texture(scene, camera_node, w, h) -> Texture2D

It makes the render-target texture, hangs a `Viewport` off its surface and
asks for an update. The upgrade path, if something ever needs a live mirror
or a portal, is to expose `RenderSurface` properly; nothing here does.

One wrinkle worth knowing before it is debugged: `set_voxel_geometry()` is
asynchronous, so the first update can land on an empty node. Keep the
thumbnail scene alive and re-queue the update for a few frames after the
geometry callback, then drop the scene.

Four scenes of their own, one per structure: a zone, a light, a camera framed
on the box by the same arithmetic `overlook()` already does, and the voxel
node. A separate scene rather than view masks, because "in isolation" is then
true by construction and there is no terrain to exclude.

Thumbnails at 96x96. The button is the icon plus the existing label; until a
thumbnail exists the button is the label alone, so a slow round trip degrades
to what the menu is today.

### The camera bugfix

`init.lua`'s update handler calls `magic.input:GetMouseMove()` and yaws the
player with it unconditionally, so the camera swings while the menu is being
clicked. Guarded by the menu and by placement mode.

The delta accumulates whether or not it is read, so the frame the menu closes
has to read it and throw it away, or the camera jumps by however far the
mouse travelled across the menu.

### Placement mode

Entered when a structure is chosen, instead of placing at the player's feet
as the menu does today.

- A node in the main scene with the structure's geometry, snapped to the
  voxel grid. No physics body, not merged into the world, nothing the
  simulation sees: an ordinary drawable that depth-sorts where it is. Built
  with `use_skylight = false` -- a standalone volume has no skylight to read
  and the vertex colours would come out black; without them the material's
  own lighting draws it, which is the "actual look" this wants.
- Mouse movement moves it in X/Z. Relative deltas, not a cursor raycast: the
  cursor is captured in this game, and a raycast over the ~60 voxels the
  camera is now back would be a much longer march than
  `find_pointed_voxel()`'s six.
- Y comes from the terrain at the building's centre X/Z, marched down with
  `occupied_at()`, with the bottom of the box sat on it. Centre only, as
  specified. If a building over uneven ground reads as buried, the
  alternative is the highest of the footprint's four corners -- a one-line
  change, worth trying second rather than first.
- Camera at the building's X/Z plus 15 on each of +X and +Z, `Y + 40`,
  looking at the position currently selected. That is a direction of
  `(-15, -40, -15)`: a yaw of 225 degrees and a pitch of about 62 down, both
  fixed for as long as placement mode is up, with only the position
  following the building.
- Because the yaw is fixed, the mouse deltas have to go through it rather
  than straight onto world X and Z, or moving the mouse right would slide the
  building diagonally across the screen. Mouse right is screen right, which
  under this yaw is world `(+X -Z)` normalised; mouse up is away from the
  camera, world `(-X -Z)`.
- Right button places and leaves; left button or escape leaves without
  placing. Either way the preview node is destroyed and free move begins.
- Escape has to be intercepted: at the moment it disconnects the client.
- The cursor goes back to captured on the way in, since the menu made it
  visible.
- The `main:structure_placed` handler currently calls `overlook()` when free
  move is on, which would yank the camera the moment a building lands.
  Suppressed for a placement made this way: the player already has the view
  they chose.
- A line on screen while it is up: the structure's name and
  "right click to place, escape to cancel".

### Order

The shape protocol first -- both other pieces need it and it is testable on
its own by logging what arrives. Then placement mode, which is the part with
the gameplay in it. Then the thumbnails, which are the part that needs new
engine bindings; the menu works without them. The camera bugfix is
independent and goes in whenever.

### What it turned out to be, against the plan above

Built on branch `aggregate-ux`: `aggregate: place a building by eye instead
of at your feet` and `Render a scene into a texture, and put thumbnails on
the structures menu`.

The shape protocol, the camera bugfix and placement mode are as planned. The
rest came out differently:

- **The binding is `urho3d.render_scene_to_texture()`, not
  `buildat.render_scene_to_texture()`.** What a sandboxed caller gets back
  has to be a wrapped Texture2D, and the wrapping machinery -- `wrap_instance`
  and the class whitelist -- lives in `extensions/urho3d`. `client/api.lua`
  has no access to it and requires nothing. The C function is
  `__buildat_render_scene_to_texture` either way.
- **The surface updates every frame rather than being re-queued for a few.**
  That is what the async geometry needed, and at 96x96 it is cheap. The
  texture and its viewport are deliberately leaked: a container of
  `SharedPtr<Texture2D>` destroyed at exit tears a viewport down after
  Urho3D's context is gone, which is a SIGSEGV on the way out.
- **The preview nodes are built at connect and reused, not built per
  placement.** A mesh asked for when the menu closes queues behind whatever
  chunks are being meshed around a moving camera, which was a twenty-second
  wait. They are built on `voxelworld.sub_ready()`, because the shapes arrive
  before the voxel registry does and meshing without it throws `Undefined
  voxel: 1`.
- **Mouse right is world `(-X +Z)`, not `(+X -Z)`.** Under a yaw of 225 the
  node's right vector is `(cos yaw, 0, -sin yaw)`; the plan had the sign the
  other way. The code derives it from the yaw rather than writing the vector
  down.
- **Nothing checks where a building goes.** Buildings may be placed on top of
  each other and on top of trees: picking a good spot is the player's, and
  stacking them is allowed to be part of the fun. The ground search is the
  first occupied voxel from above, so it already sits one on whatever is
  underneath.
- The thumbnail scenes are lit for low dynamic range (a directional light at
  2.2) because a thumbnail viewport has none of the main viewport's HDR
  tonemapping.

## Decisions on record

- **Overfull pushes material out.** Compaction is the step before it.
- **Sand and gravel keep their void when compacted**, so they hold water
  when fully packed. Per-material, not one number.
- **Life is a state, not a material**, because nothing moves when wood dies.
- **Bond is a state, not a material**, because nothing moves when a plank is
  broken into sawdust.
- **Wood is fibre plus binder**, so rot has something to eat and soil has
  somewhere to come from.
- **Leaves are thin live fibre**, not a material and not a voxel type.
- **Four bits a solid, eight for water.** The look needs fewer; the
  arithmetic needs more; water is the only one that has to conserve.

From the first playtest (2026-09-11):

- **Water gets a rate, not just a room.** Conductivity is a cap on how much
  crosses a boundary in a step, and it is **finest-wins over the
  composition**: the smallest pores throttle the flow, which is why a little
  clay in gravel ruins its drainage and why no average would do. No new
  field -- rock, sand and binder are already the size classes.
- **Capillary rise is allowed where pressure is not.** It moves water only
  from wetter to drier and stops when both are at field capacity, so it has
  a fixed point; a head does not, which is why upward *pressure* is still
  out.
- **Capacity scales with how full the voxel is.** A thin heap carries almost
  nothing whatever it is made of.
- **A loose mixture sinks into whatever room is under it**, which is the
  complement of bulking and is what stops a spoonful of humus standing as a
  cube.
- **A fine material fits in a coarse one's voids.** Grading belongs in
  `packed_limit()`; it is the reason soil is denser than sand and concrete
  denser than gravel, and having it there would explain the recipes rather
  than leave them tuned to match.
- **No minimum fill for being structural.** It would fix the humus symptom
  bluntly, where sinking and fill-scaled capacity are rules already in the
  game doing the work -- and they are right for gravel and sand too.

## Risks

- **It inherits the player physics fault.** Copying undermine copies the
  engine bug in step 4b of `doc/plan/master_plan.md`: the player falls through
  the terrain while the world is still loading. The latest fix is in and
  has never reproduced in an automated run, so it is unverified rather than
  known-broken. It is the engine's, not this game's, and the playtest's
  findings on it are in step 4b of `doc/plan/master_plan.md`.

  **And free move is not the workaround it was assumed to be**: it turns
  gravity off but the body still collides, so a player already inside
  terrain is stuck there. Making free move pass through the world is the
  first of the three things listed in 4b.
- **Phase 1 is a rewrite that must change nothing.** The mitigation is the
  copy-first commit and a screenshot comparison against undermine, which is
  the same net that has caught everything on this branch.
- **Twelve base looks is a lot of textures.** undermine's are reusable for
  most of them; the new ones are gravel, mulch and dirty water.
- **The simulation sweeps.** Measure it at one material before there are
  five. The fallback is coarser ticks and smaller active regions, not a
  faster loop.
- **Sixteen levels of a solid may be too coarse** once material starts
  moving. Widening a plane is a format change; do that rather than
  redesigning around it.

## Not in this plan

- **Water under pressure**, which is what would make it climb a shaft. It
  wants a head, a head wants headroom above "full" or a walk up the column,
  and neither fits in eight bits. Capillary rise in phase 4 covers the part
  of "water climbs" that has a fixed point; the rest waits for a
  measurement.
- **Cement you can make**, and concrete that cures. The field is there and
  the rule is one line, but it wants a way to get cement, which wants
  cooking, which is a game of its own.
- **Fire.** Fibre burns, which would be the second thing that converts one
  material into another, and it wants smoke and heat fields.
- **Particle size.** A log and sawdust are the same fibre at different bond.
  That is as far as the model goes and it is deliberate; the spike says the
  eye cannot tell loose sand from packed sand either.
