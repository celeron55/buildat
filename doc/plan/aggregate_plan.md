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

## The five steps

All built; they are in `doc/plan/aggregate_history.md` with what each turned
out to be. Step 3 came out much smaller than planned, and the look spike of
step 2 is `games/aggregate_look`, which is still in the tree and still runs.
Step 5, the game itself, is frozen -- see
`doc/plan/aggregate_game_plan.md`.

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
