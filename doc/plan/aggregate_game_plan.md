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

## How it was built

Phases 1 to 5 -- parity with undermine, compaction and water, the wood cycle,
what the first playtest found, and the building menu with its thumbnails and
placement mode -- are in `doc/plan/aggregate_game_history.md`, with what each
one turned out to be.

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
