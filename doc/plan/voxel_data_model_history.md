# The voxel data model: what was built

Moved out of `doc/plan/voxel_data_model_plan.md`, which now holds the decision
the whole design turns on, the roles, what a chunk publishes, what stage 3
would be, and the order. Nothing here is a to-do.

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
