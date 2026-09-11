#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/voxel_selector.h"
#include "interface/noise.h"
#include "interface/voxel_volume.h"
#include <Scene.h>
#include <Context.h>
#include <StaticModel.h>
#include <Material.h>
#include <Texture2D.h>
#include <Technique.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <sstream>
#include <deque>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <chrono>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using main_context::SceneReference;

// TODO: Move to a header (core/types_polyvox.h or something)
#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

// TODO: Move to a header (core/cereal_polyvox.h or something)
namespace cereal {

template<class Archive>
void save(Archive &archive, const pv::Vector3DInt32 &v){
	archive((int32_t)v.getX(), (int32_t)v.getY(), (int32_t)v.getZ());
}
template<class Archive>
void load(Archive &archive, pv::Vector3DInt32 &v){
	int32_t x, y, z;
	archive(x, y, z);
	v.setX(x); v.setY(y); v.setZ(z);
}

}

namespace main {

using namespace Urho3D;

// Everything at or below this that the terrain did not fill is water. The
// generator's surface runs from about y=13 to y=100 over the generated area,
// and this line puts water in the lowest 6% of it: a handful of ponds in the
// hollows rather than a sea with islands in it.
static const int WATER_LEVEL = 25;

// The bottom of the world, and the only thing in it that cannot be dug:
// where support ultimately comes from.
static const int BEDROCK_TOP = -60;

// This game's own cut of a voxel. See local/aggregate_game_plan.md.
//
// Two planes. The first is the engine's, and holds what the engine reads
// plus the two numbers the simulation keeps; the second is this game's, and
// holds what a voxel is made of.
//
//   plane 0
//     id       0...1    not a material id: there are no material ids here.
//                       One bit that says a voxel has been generated at
//                       all, which is what voxelworld means by
//                       VOXELTYPEID_UNDEFINED and the only thing it needs
//     sky      2...5    light, as voxelworld maintains it
//     tint     6...9    the albedo tint, driven by how wet it is
//     wetness 10...13   the same number again, for the shader
//     support 14...17   how far this voxel is from something holding it up
//     band    18...21   how much of what it can carry is on it, 1...15;
//                       0 means "nothing structural here", which is what
//                       the view registries key on
//
//   plane 1, "aggregate:mix"
//     rock     0...3    coarse mineral
//     sand     4...7    fine mineral
//     fibre    8...11   structural organic matter: wood, leaf, root
//     binder  12...15   lignin, humus, clay, cement -- what holds a mixture
//                       together, and what rot turns fibre into
//     water   16...23   the only fluid; air is the absence of everything
//     bond    24...27   how continuous the solid is. Not a material: a
//                       plank and a heap of sawdust are the same mixture
//     life    28...31   whether the fibre here is alive. Not a material
//                       either: nothing moves when wood dies
//
// What a voxel *looks* like is not stored anywhere. The registry's look
// rules pick a definition out of the fractions, and every property the
// engine asks -- what is drawn, what is solid, what light passes -- comes
// off the definition they picked. See look_selector().
static const uint8_t P_MIX = 1;

static const interface::VoxelField F_ID(0, 0, 2);
static const interface::VoxelField F_LIGHT_SKY(0, 2, 4);
static const interface::VoxelField F_TINT(0, 6, 4);
static const interface::VoxelField F_WETNESS(0, 10, 4);
static const interface::VoxelField F_SUPPORT(0, 14, 4);
static const interface::VoxelField F_BAND(0, 18, 4);

static const interface::VoxelField F_ROCK(P_MIX, 0, 4);
static const interface::VoxelField F_SAND(P_MIX, 4, 4);
static const interface::VoxelField F_FIBRE(P_MIX, 8, 4);
static const interface::VoxelField F_BINDER(P_MIX, 12, 4);
static const interface::VoxelField F_WATER(P_MIX, 16, 8);
static const interface::VoxelField F_BOND(P_MIX, 24, 4);
static const interface::VoxelField F_LIFE(P_MIX, 28, 4);

// Written into every voxel the generator touches, air included, because
// voxelworld tells a generated voxel from one nothing has reached by the id
// role and nothing else. It says nothing about what the voxel is.
static const uint8_t PRESENT_ID = 1;

static interface::VoxelFormat aggregate_format()
{
	interface::VoxelFormat f;
	f.id = F_ID;
	f.light_sky = F_LIGHT_SKY;
	// The two modifiers the look spike found read at a glance. The tint is
	// how wet a material looks and the wetness is the same number again for
	// the shader to put a sheen on.
	f.tint = F_TINT;
	f.wetness = F_WETNESS;
	f.planes.push_back(interface::VoxelPlane("aggregate:mix", 32));
	return f;
}

// A fraction of a voxel, full at FRACTION_MAX. What a fraction measures is
// the *solid volume* the material takes up, so a voxel of loose sand at 9 is
// six fifteenths void -- which is where water goes, and is what phase 2 is
// about.
static const uint8_t FRACTION_MAX = 15;
static const uint8_t WATER_MAX = 255;
static const uint8_t BOND_MAX = 15;
static const uint8_t LIFE_MAX = 15;

// What a voxel is made of, and the two states that are not materials
struct Mix
{
	uint8_t rock, sand, fibre, binder, water, bond, life;

	Mix(): rock(0), sand(0), fibre(0), binder(0), water(0), bond(0), life(0){}
	Mix(uint8_t rock, uint8_t sand, uint8_t fibre, uint8_t binder,
			uint8_t water, uint8_t bond, uint8_t life):
		rock(rock), sand(sand), fibre(fibre), binder(binder), water(water),
		bond(bond), life(life){}

	// How much of the voxel is solid at all
	uint8_t solid() const
	{
		int t = (int)rock + sand + fibre + binder;
		return (uint8_t)(t > FRACTION_MAX ? FRACTION_MAX : t);
	}
};

// The recipes. Not materials and not ids: names for mixtures, so that a
// generator and a structure can say "timber" and mean something the look
// rules will agree with.
//                            rock sand fibr bind water bond life
static const Mix MIX_AIR;
static const Mix MIX_WATER   (  0,   0,   0,   0,  255,   0,   0);
static const Mix MIX_BEDROCK (15,   0,   0,   0,    0,  15,   0);
static const Mix MIX_STONE   (15,   0,   0,   0,    0,  12,   0);
static const Mix MIX_GRAVEL  (12,   2,   0,   0,    0,   0,   0);
static const Mix MIX_SAND    ( 0,  12,   0,   0,    0,   0,   0);
static const Mix MIX_SOIL    ( 0,   9,   1,   4,    0,   8,   0);
static const Mix MIX_TURF    ( 0,   9,   2,   4,    0,   8,  12);
static const Mix MIX_BRICK   (10,   3,   0,   2,    0,  15,   0);
static const Mix MIX_TIMBER  ( 0,   0,   9,   4,    0,  14,   0);
static const Mix MIX_TRUNK   ( 0,   0,   9,   4,    0,  14,  15);
static const Mix MIX_LEAVES  ( 0,   0,   2,   1,    0,  12,  15);

// What the simulation reads about a voxel. Where undermine looked this up in
// a table by material id, it is worked out here from the mixture -- which is
// the whole point of the game, and costs a handful of multiplies per voxel.
//
//   span      how far it reaches out over nothing before it fails, which is
//             what decides how wide a tunnel it will roof
//   density   what one voxel of it weighs, in the same units as capacity
//   capacity  how much weight it carries before it is crushed
//   porous    whether water gets into it
struct MaterialProps
{
	bool structural;
	bool diggable;
	uint8_t span;
	uint8_t density;
	uint8_t capacity;
	bool porous;
};

// Fill, in 255ths of a voxel, which is the unit the water field is already
// in: a solid fraction of 15 is a full voxel, so a fraction converts by 17.
//
// **A fraction is solid volume, not heap volume.** A voxel of loose sand at
// 9 is nine fifteenths solid and six fifteenths void, and that void is where
// water goes. So how much water a mixture can hold is not a property of the
// material at all -- it is what is left of the voxel.
static const int FILL_FULL = 255;

static int solid_fill(const Mix &m)
{
	return 17 * ((int)m.rock + m.sand + m.fibre + m.binder);
}

// How much of the voxel is neither solid nor water
static int void_fill(const Mix &m)
{
	int v = FILL_FULL - solid_fill(m);
	return v < 0 ? 0 : v;
}

// How much more water would go in
static int water_room(const Mix &m)
{
	int r = void_fill(m) - (int)m.water;
	return r < 0 ? 0 : r;
}

// How wet it is, as how much of the void is taken, 0...15. What the tint and
// the wetness modifiers carry, and what takes a mixture's capacity away --
// so a material with little void is soaked by a little water, which is why
// soil gives long before gravel does.
static uint8_t saturation(const Mix &m)
{
	const int v = void_fill(m);
	if(v <= 0)
		return 0;
	int s = 15 * (int)m.water / v;
	return (uint8_t)(s > 15 ? 15 : s);
}

// Whether water can get into it at all. Anything bonded is closed: a stone
// wall holds water out, and a timber hull floats.
static bool takes_water(const Mix &m)
{
	return m.bond < 12 && water_room(m) > 0;
}

// How far a mixture reaches out over nothing.
//
// Two things decide it: what is holding the solid together, which is `bond`
// -- a heap of the same stuff spans nothing at all -- and what the solid is,
// since fibre is strong in tension where rock is strong in compression. Live
// tissue holds itself up as well, which is what lets a canopy hang.
static uint8_t mix_span(const Mix &m)
{
	int stuff = 2 * (int)m.fibre + 2 * (int)m.binder + 3 * (int)m.rock / 2;
	int span = (int)m.bond * stuff / 40 + (int)m.life / 8;
	return (uint8_t)(span > 15 ? 15 : (span < 0 ? 0 : span));
}

// What a voxel of it weighs. Rock is the heavy one, fibre the light one, and
// water is carried along with whatever is holding it.
static uint8_t mix_density(const Mix &m)
{
	int d = (3 * (int)m.rock + 2 * (int)m.sand + 3 * (int)m.binder +
			(int)m.fibre) / FRACTION_MAX + 2 * (int)m.water / WATER_MAX;
	return (uint8_t)(d > 15 ? 15 : d);
}

// How much weight it carries before it is crushed. Unlike the span this does
// not need bond: a heap of loose sand carries what stands on it perfectly
// well, it just cannot reach out over a hole. What does take it away is
// water -- saturated sand gives, which is the sandcastle rule and is why
// digging under a pond is a bad idea.
static uint8_t mix_capacity(const Mix &m)
{
	int c = 17 * (int)m.rock + 10 * (int)m.binder + 3 * (int)m.sand +
			3 * (int)m.fibre;
	if(c > 255)
		c = 255;
	// Half of it, at saturation -- and saturation is how much of the *void*
	// the water has taken, not how much of the voxel, so a material with
	// little room in it gives way to a little water
	c -= c * (int)saturation(m) / 30;
	return (uint8_t)(c < 0 ? 0 : c);
}

static MaterialProps props_of(const Mix &m)
{
	MaterialProps p;
	const uint8_t solid = m.solid();
	// Water on its own is walked into rather than stood on, as it was
	p.structural = solid >= 2;
	// The one thing that cannot be dug is rock that is both pure and whole,
	// which is what the bottom of the world is made of. A property of the
	// mixture rather than a flag on a material.
	p.diggable = !(m.rock >= 12 && m.bond >= BOND_MAX);
	p.span = mix_span(m);
	p.density = mix_density(m);
	p.capacity = mix_capacity(m);
	// Anything loose enough to have voids between its grains
	p.porous = m.bond < 12 && solid > 0;
	return p;
}

static Mix mix_of(const interface::VoxelSample &v)
{
	return Mix(
			(uint8_t)F_ROCK.get(v), (uint8_t)F_SAND.get(v),
			(uint8_t)F_FIBRE.get(v), (uint8_t)F_BINDER.get(v),
			(uint8_t)F_WATER.get(v), (uint8_t)F_BOND.get(v),
			(uint8_t)F_LIFE.get(v));
}

static void set_mix(interface::VoxelSample &v, const Mix &m)
{
	F_ROCK.set(v, m.rock);
	F_SAND.set(v, m.sand);
	F_FIBRE.set(v, m.fibre);
	F_BINDER.set(v, m.binder);
	F_WATER.set(v, m.water);
	F_BOND.set(v, m.bond);
	F_LIFE.set(v, m.life);
	// How wet it looks, which the mesher reads and nothing else does
	const uint8_t wet = saturation(m);
	F_TINT.set(v, wet);
	F_WETNESS.set(v, wet);
}

// A voxel of one recipe, generated and with nothing worked out about it yet
static interface::VoxelSample mix_voxel(const Mix &m)
{
	interface::VoxelSample v;
	F_ID.set(v, PRESENT_ID);
	set_mix(v, m);
	return v;
}

// What the player builds with, by the number the client sends. An index
// rather than a material id, because there are no material ids: the client
// says "the second thing on the list" and this is the list.
enum BuildMaterial {
	B_STONE = 1,
	B_TIMBER,
	B_BRICK,
	B_SOIL,
	B_WATER,
	B_COUNT
};

static const Mix& build_mix(int32_t which)
{
	switch(which){
	case B_TIMBER: return MIX_TIMBER;
	case B_BRICK: return MIX_BRICK;
	case B_SOIL: return MIX_SOIL;
	case B_WATER: return MIX_WATER;
	default: return MIX_STONE;
	}
}

static const uint8_t SUPPORT_MAX = 15;
static const uint8_t LOAD_MAX = 255;
// How many steps of "how loaded is it" fit in the nibble. One less than
// sixteen because 0 is reserved for "nothing structural here", which is how
// a view registry tells a solid voxel from air without being able to add up
// the fractions in a rule.
static const uint8_t BAND_MAX = 15;

// How far up a voxel is asked to carry.
//
// simplified: the weight on a voxel is the column immediately above it and
// no further, so nothing carries the whole mountain and a prop's failure
// depends on what is locally above it. That is what makes the number local
// enough to work out anywhere, including at generation time, and stable
// enough that digging far overhead does not change it. The upgrade path, if
// a game wants the real thing, is a load that accumulates down the column
// without a limit -- which means the whole column has to be recomputed
// whenever anything in it changes.
static const int LOAD_DEPTH = 32;

static bool is_generated(const interface::VoxelSample &v)
{
	return F_ID.get(v) != interface::VOXELTYPEID_UNDEFINED;
}

static uint8_t support_of(const interface::VoxelSample &v)
{
	return (uint8_t)F_SUPPORT.get(v);
}

// How much of what this voxel can carry is already on it, 1...15, or 0 for
// a voxel that is not structural at all
static uint8_t band_of(const interface::VoxelSample &v)
{
	return (uint8_t)F_BAND.get(v);
}

static void set_state(interface::VoxelSample &v, uint8_t support, uint8_t band)
{
	F_SUPPORT.set(v, support);
	F_BAND.set(v, band);
}

// A weight, as the fraction of a capacity that a nibble can hold, 1...15.
// Rounded down, so a band of 15 means "at or over what it can carry" only
// when the weight really is; the rules test the weight itself and not this.
static uint8_t load_band(uint32_t load, uint8_t capacity)
{
	if(capacity == 0)
		return 1;
	uint32_t band = 1 + load * (uint32_t)(BAND_MAX - 1) /
			((uint32_t)capacity + 1);
	return (uint8_t)(band > BAND_MAX ? BAND_MAX : band);
}

// The base looks. Not materials: these are the definitions the look rules
// choose between, and the only thing they carry is how a voxel of that
// mixture is drawn and what the engine makes of it. Added in this order.
enum Look {
	L_AIR = 1,
	L_WATER,
	L_BEDROCK,
	L_STONE,
	L_GRAVEL,
	L_SAND,
	L_SOIL,
	L_TURF,
	L_BRICK,
	L_TIMBER,
	L_TRUNK,
	L_LEAVES,
	L_MULCH,
	L_COUNT
};

// Which of them a voxel wears, as an ordered list of thresholds over the
// fractions. First match wins, so the order is the design:
//
// - water is looked at first, so a bit of wood in a lot of water is dirty
//   water and not a soggy plank;
// - what is alive is looked at before what is not, so that a thin canopy of
//   living fibre is leaves where the same fibre dead is mulch -- which is
//   the whole reason `life` is stored;
// - the last few rules are one per material, and they are what a voxel with
//   a trace of something in it falls through to.
//
// A clause is a range over one field, and a rule is clauses ANDed, so an
// "or" is written as two rules with the same result. That is what the last
// group is.
static void rule(interface::VoxelSelector &s, uint8_t result,
		const interface::VoxelField &f0, uint32_t lo0, uint32_t hi0,
		const interface::VoxelField *f1 = nullptr,
		uint32_t lo1 = 0, uint32_t hi1 = 0,
		const interface::VoxelField *f2 = nullptr,
		uint32_t lo2 = 0, uint32_t hi2 = 0)
{
	interface::VoxelRule r;
	r.clauses.push_back(interface::VoxelRuleClause(f0, lo0, hi0));
	if(f1)
		r.clauses.push_back(interface::VoxelRuleClause(*f1, lo1, hi1));
	if(f2)
		r.clauses.push_back(interface::VoxelRuleClause(*f2, lo2, hi2));
	r.result = result;
	s.rules.push_back(r);
}

static interface::VoxelSelector look_selector()
{
	interface::VoxelSelector s;
	s.kind = interface::VoxelSelector::RULES;
	s.fallback = L_AIR;

	// Water, and nothing much in it
	{
		interface::VoxelRule r;
		r.clauses.push_back(interface::VoxelRuleClause(F_WATER, 128, 255));
		r.clauses.push_back(interface::VoxelRuleClause(F_ROCK, 0, 1));
		r.clauses.push_back(interface::VoxelRuleClause(F_SAND, 0, 1));
		r.clauses.push_back(interface::VoxelRuleClause(F_FIBRE, 0, 1));
		r.clauses.push_back(interface::VoxelRuleClause(F_BINDER, 0, 1));
		r.result = L_WATER;
		s.rules.push_back(r);
	}
	// Wood, alive and dead. Turf comes before leaves and not after: living
	// fibre with mineral under it in the same voxel is the top of the
	// ground, and living fibre with nothing else in it is a canopy. Getting
	// that the wrong way round drew the whole surface of the world as
	// leaves, which is what the check at the end of on_start() is for.
	rule(s, L_TRUNK,  F_FIBRE, 4, 15, &F_LIFE, 8, 15);
	rule(s, L_TURF,   F_SAND, 4, 15, &F_BINDER, 2, 15, &F_LIFE, 4, 15);
	rule(s, L_LEAVES, F_FIBRE, 1, 15, &F_LIFE, 8, 15);
	rule(s, L_TIMBER, F_FIBRE, 4, 15, &F_BOND, 8, 15);
	rule(s, L_MULCH,  F_FIBRE, 4, 15);
	// Mineral, bonded and loose
	rule(s, L_BEDROCK, F_ROCK, 12, 15, &F_BOND, 15, 15);
	rule(s, L_BRICK,   F_ROCK, 4, 15, &F_BINDER, 2, 15, &F_BOND, 12, 15);
	rule(s, L_STONE,   F_ROCK, 8, 15, &F_BOND, 8, 15);
	rule(s, L_GRAVEL,  F_ROCK, 8, 15);
	// Soil is sand with binder in it; turf is soil with something growing on
	// it, and is above with the rest of what is alive
	rule(s, L_SOIL, F_SAND, 4, 15, &F_BINDER, 2, 15);
	rule(s, L_SAND, F_SAND, 4, 15);
	// A trace of anything, which is what is left
	rule(s, L_GRAVEL, F_ROCK, 1, 15);
	rule(s, L_MULCH,  F_FIBRE, 1, 15);
	rule(s, L_SOIL,   F_BINDER, 1, 15);
	rule(s, L_SAND,   F_SAND, 1, 15);
	rule(s, L_WATER,  F_WATER, 32, 255);
	return s;
}

struct Worldgen: public worldgen::GeneratorInterface
{
	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		{
			const pv::Region region = volume.getEnclosingRegion();

			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();

			log_t(MODULE, "on_generation_request(): lc: (%i, %i, %i)",
					lc.getX(), lc.getY(), lc.getZ());
			// The volume arrives with the engine's plane; the mixture is
			// this game's own and it asks for its plane here
			volume.add_planes(aggregate_format().planes);

			log_t(MODULE, "on_generation_request(): uc: (%i, %i, %i)",
					uc.getX(), uc.getY(), uc.getZ());

			interface::v3f spread(160, 160, 160);
			interface::NoiseParams np(0, 20, spread, 0, 7, 0.4);

			int w = uc.getX() - lc.getX() + 1;
			int d = uc.getZ() - lc.getZ() + 1;

			interface::Noise noise(&np, 3, w, d);
			noise.fbmMap2D(lc.getX() + spread.X/2, lc.getZ() + spread.Z/2);
			noise.transformNoiseMap(); // ?

			size_t noise_i = 0;
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					double a = noise.result[noise_i];
					noise_i++;
					// Where the ground stops, in the same terms the layers
					// below are written in
					const int surface = (int)(a + 11.0);
					for(int y = lc.getY(); y <= uc.getY(); y++){
						pv::Vector3DInt32 p(x, y, z);
						// Layers of mixture rather than layers of material.
						// There is no dirt to place: soil is where binder
						// meets sand, and what is under it is the same sand
						// with less in it.
						Mix m;
						if(y <= BEDROCK_TOP){
							m = MIX_BEDROCK;
						} else if(y < a + 5){
							m = MIX_STONE;
						} else if(y < a + 10){
							m = MIX_SOIL;
						} else if(y < a + 11){
							// A shore is sand rather than turf: it is what
							// gives the ponds an edge that behaves
							// differently when it is dug
							m = (surface <= WATER_LEVEL + 1) ?
									MIX_SAND : MIX_TURF;
						} else if(y <= WATER_LEVEL){
							m = MIX_WATER;
						}
						// Ground at or under the water line starts
						// saturated. Not a detail: without it the first
						// thing that disturbs a pond is the pond draining
						// into its own bed, because the bed is dry and has
						// room. It is also what makes digging under water a
						// bad idea, saturated ground carrying half of what
						// dry ground does.
						if(y <= WATER_LEVEL && m.solid() > 0){
							m.water = (uint8_t)void_fill(m);
						}
						volume.set_sample_at(p.getX(), p.getY(), p.getZ(),
								mix_voxel(m));
					}
				}
			}

			// Trees, for something to look at above ground -- and for
			// something whose trunk can be cut through, which the support
			// rule makes an event rather than a decoration
			auto extent = uc - lc + pv::Vector3DInt32(1, 1, 1);
			int area = extent.getX() * extent.getZ();
			auto pr = interface::PseudoRandom(13241);
			for(int i = 0; i < area / 100; i++){
				int x = pr.range(lc.getX(), uc.getX());
				int z = pr.range(lc.getZ(), uc.getZ());
				size_t ni = (z - lc.getZ()) * d + (x - lc.getX());
				int y = (int)(noise.result[ni] + 11.0);
				if(y < lc.getY() - 5 || y > uc.getY() - 5)
					continue;
				// The trunk would start in a pond
				if(y <= WATER_LEVEL + 1)
					continue;
				for(int y1 = y; y1 < y + 4; y1++)
					volume.set_sample_at(x, y1, z, mix_voxel(MIX_TRUNK));
				for(int x1 = x - 2; x1 <= x + 2; x1++){
					for(int y1 = y + 3; y1 <= y + 7; y1++){
						for(int z1 = z - 2; z1 <= z + 2; z1++){
							// Leaves are the same fibre as the trunk, thin
							// and alive; the trunk is where there is enough
							// of it to be wood
							Mix at = mix_of(volume.sample_at(x1, y1, z1));
							if(at.fibre >= 4)
								continue;
							volume.set_sample_at(x1, y1, z1,
									mix_voxel(MIX_LEAVES));
						}
					}
				}
			}

			// What the simulation starts from. Generated terrain is a
			// heightfield standing on bedrock, so every solid voxel of it is
			// held up -- there are no overhangs to work out -- and the one
			// number that has to be computed is the weight each voxel
			// carries. Both are exact here except within LOAD_DEPTH of the
			// top of the volume, where the column above is in a section this
			// generator cannot see; digging near one fixes it locally.
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					// The densities of the LOAD_DEPTH voxels above the one
					// being written, as a ring: what leaves the window is
					// subtracted rather than the whole column being summed
					// again per voxel
					int window[LOAD_DEPTH] = {};
					int carried = 0;
					int depth = 0;
					for(int y = uc.getY(); y >= lc.getY(); y--){
						interface::VoxelSample v = volume.sample_at(x, y, z);
						const MaterialProps m = props_of(mix_of(v));
						if(!m.structural){
							carried = 0;
							depth = 0;
							continue;
						}
						set_state(v, SUPPORT_MAX,
								load_band(carried > LOAD_MAX ?
										LOAD_MAX : carried, m.capacity));
						volume.set_sample_at(x, y, z, v);
						int &slot = window[depth % LOAD_DEPTH];
						carried -= slot;
						slot = m.density;
						carried += slot;
						depth++;
					}
				}
			}
		}
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;

	SceneReference m_main_scene;

	static const int SPAWN_X = -5;
	static const int SPAWN_Z = 257;
	static const int SPAWN_Y_MAX = 127;
	static const int SPAWN_Y_MIN = -64;
	static constexpr float PLAYER_HEIGHT = 1.7f;

	bool m_spawn_ready = false;
	float m_spawn_y = 0;

	// Voxels whose support and load have to be worked out again, and the
	// ones that have already been found to be failing. The set is what keeps
	// a queue from filling up with the same position: a cave-in reaches the
	// same voxel from several directions.
	std::deque<pv::Vector3DInt32> m_dirty;
	std::unordered_set<int64_t> m_dirty_set;
	std::vector<pv::Vector3DInt32> m_falling;
	std::unordered_set<int64_t> m_falling_set;

	// What the relaxation has worked out but not written into the world yet.
	//
	// A voxel's support walks down through every intermediate value on its
	// way to the answer -- 15, then 6, then 5 -- and writing each one costs
	// a chunk re-serialized, sent and remeshed, for a number that is about
	// to change again. So the relaxation reads and writes here and the world
	// gets one write per voxel, once the front has passed.
	// Keyed by position, and carrying the position, so that flushing does not
	// have to take a key apart again
	struct Pending { pv::Vector3DInt32 p; interface::VoxelSample v; };
	std::unordered_map<int64_t, Pending> m_scratch;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place_structure"));
		m_server->sub_event(this, Event::t("worldgen:queue_modified"));
		m_server->sub_event(this, Event::t("core:tick"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:dig_voxel",
				on_dig_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:place_structure",
				on_place_structure, network::Packet)
		EVENT_TYPEN("worldgen:queue_modified",
				on_worldgen_queue_modified, worldgen::QueueModifiedEvent);
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent);
	}

	// The six numbers after solid describe the surface; see interface/atlas.h.
	// visible is the edge material: an invisible voxel is also one light
	// passes through. top_texture, when given, goes on the +Y and -Y faces.
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool visible, bool solid,
			bool fully_empty, float roughness = 0.9f, float spec_strength = 1.0f,
			float bumpiness = 1.0f, float translucency = 0.0f,
			float spots = 0.0f, float static_spots = 0.0f,
			const ss_ &top_texture = "", uint32_t soaked = 0xffffff)
	{
		interface::VoxelDefinition vdef;
		vdef.name.block_name = name;
		vdef.name.segment_x = 0;
		vdef.name.segment_y = 0;
		vdef.name.segment_z = 0;
		vdef.name.rotation_primary = 0;
		vdef.name.rotation_secondary = 0;
		vdef.handler_module = "";
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = vdef.textures[i];
			seg.resource_name = (i < 2 && !top_texture.empty()) ?
					top_texture : texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = roughness;
			seg.spec_strength = spec_strength;
			seg.bumpiness = bumpiness;
			seg.translucency = translucency;
			seg.spots = spots;
			seg.static_spots = static_spots;
		}
		vdef.edge_material_id = visible ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = fully_empty;
		// Dry at one end and soaked at the other; the tint field says where
		// along it this voxel is
		vdef.tint_ramp[0] = 0xffffff;
		vdef.tint_ramp[1] = soaked;
		reg->add_voxel(vdef);
	}

	// The views
	// ---------
	//
	// A view is a registry over the same voxels with three definitions and
	// three rules: air, water, and one gradient that everything structural
	// wears. The rules are what tell those three apart, and the band a
	// voxel gets is its `param` -- which in a view is the simulation's two
	// numbers, bound as a role so that a definition's variants index it.
	//
	// It costs no storage at all, which is the trick worth knowing, and
	// under look rules it costs almost no definitions either: undermine
	// needed sixteen variants on every one of its twelve materials, and
	// this needs sixteen on one. Nothing about a voxel changes and nothing
	// is re-sent; switching a view is a registry and a remesh.
	//
	// The client meshes with one of these instead of the playing registry
	// and turns skylight off while it does, so the vertex colour is the band
	// and nothing else.
	static const size_t VIEW_BANDS = 16;

	enum ViewMode {
		VIEW_LOAD = 0,   // how much of what it can carry is on it
		VIEW_SUPPORT,    // how far it is from something holding it up
		VIEW_DANGER,     // the worse of the two
		VIEW_COUNT
	};

	// Green through yellow to red: nothing the matter, through about to go.
	static uint32_t band_color(size_t band)
	{
		float t = (float)band / (float)(VIEW_BANDS - 1);
		float r = t < 0.5f ? t * 2.0f : 1.0f;
		float g = t < 0.5f ? 1.0f : (1.0f - t) * 2.0f;
		uint32_t ri = (uint32_t)(r * 255.0f + 0.5f);
		uint32_t gi = (uint32_t)(g * 255.0f + 0.5f);
		return (ri << 16) | (gi << 8) | 0x18;
	}

	// The two numbers the simulation keeps, as one field. They are adjacent
	// on purpose: a view binds this as the `param` role, and a definition's
	// variants are indexed by it, so one definition wears sixteen colours
	// and which one a voxel gets falls out of a table rather than being
	// computed anywhere. The band is the high nibble and the support the
	// low one.
	static interface::VoxelFormat view_format()
	{
		interface::VoxelFormat f;
		f.id = F_ID;
		f.light_sky = F_LIGHT_SKY;
		f.param = interface::VoxelField(0, 14, 8);
		f.planes.push_back(interface::VoxelPlane("aggregate:mix", 32));
		return f;
	}

	// Which band a voxel whose param says this belongs in
	static size_t view_band(int mode, uint8_t param)
	{
		size_t load = param >> 4;
		size_t support = param & 0x0f;
		size_t from_support = SUPPORT_MAX - support;
		switch(mode){
		case VIEW_SUPPORT: return from_support;
		case VIEW_DANGER: return load > from_support ? load : from_support;
		default: return load;
		}
	}

	void build_view_registry(interface::VoxelRegistry *reg, int mode)
	{
		reg->set_format(view_format());
		// 1: air and 2: water, so that a view leaves alone what the
		// simulation has nothing to say about
		add_voxel(reg, "air", "", false, false, true);
		add_voxel(reg, "water", "main/water.png", true, false, false,
				0.28f, 1.0f, 6.0f, 0.0f, 0.05f);
		// 3: everything else, in sixteen bands of a gradient
		{
			interface::VoxelDefinition vdef;
			vdef.name.block_name = "view_band";
			vdef.handler_module = "";
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[i];
				seg.resource_name = "main/white.png";
				seg.total_segments = magic::IntVector2(1, 1);
				seg.select_segment = magic::IntVector2(0, 0);
				seg.roughness = 1.0f;
				seg.spec_strength = 0.0f;
				seg.bumpiness = 0.0f;
			}
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			vdef.physically_solid = true;
			for(size_t band = 0; band < VIEW_BANDS; band++){
				interface::VoxelVariant var;
				var.color = band_color(band);
				vdef.variants.push_back(var);
			}
			for(size_t param = 0; param < 256; param++){
				size_t band = view_band(mode, (uint8_t)param);
				vdef.variant_of_param[param] = (uint8_t)(
						band < VIEW_BANDS ? band : VIEW_BANDS - 1);
			}
			reg->add_voxel(vdef);
		}

		// And three rules to tell the three apart. A voxel that is not
		// structural has a band of 0, which is what says so without a rule
		// having to add up the fractions -- see load_band().
		const uint8_t VIEW_AIR = 1, VIEW_WATER = 2, VIEW_SOLID = 3;
		interface::VoxelSelector s;
		s.kind = interface::VoxelSelector::RULES;
		s.fallback = VIEW_SOLID;
		rule(s, VIEW_WATER, F_BAND, 0, 0, &F_WATER, 128, 255);
		rule(s, VIEW_AIR, F_BAND, 0, 0);
		reg->set_look_selector(s);
	}

	void send_view_registries(network::PeerInfo::Id peer)
	{
		for(int mode = 0; mode < VIEW_COUNT; mode++){
			sp_<interface::VoxelRegistry> reg(
					interface::createVoxelRegistry());
			build_view_registry(reg.get(), mode);
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar((int32_t)mode, reg->serialize());
			}
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "main:view_registry", os.str());
			});
		}
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();
		});

		// Worldgen must be created before the voxelworld; otherwise initial
		// generation request events are lost
		worldgen::access(m_server, [&](worldgen::Interface *iworldgen)
		{
			iworldgen->create_instance(m_main_scene);

			auto instance = iworldgen->get_instance(m_main_scene);
			instance->set_generator(new Worldgen());
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			//pv::Region region(0, 0, 0, 0, 0, 0); // Use this for valgrind
			//pv::Region region(-1, 0, -1, 1, 0, 1);
			//pv::Region region(-1, -1, -1, 1, 1, 1);
			//pv::Region region(-2, -1, -2, 2, 1, 2);
			//pv::Region region(-3, -1, -3, 3, 1, 3);
			pv::Region region(-5, -1, 0, 0, 1, 5);
			//pv::Region region(-5, -1, -5, 5, 1, 5);
			//pv::Region region(-6, -1, -6, 6, 1, 6);
			//pv::Region region(-8, -1, -8, 8, 1, 8);
			ivoxelworld->create_instance(m_main_scene, region);
		});

		// Define voxels on core:start (woxelworld will restore them on reload)
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world =
					ivoxelworld->get_instance(m_main_scene);
			interface::VoxelRegistry *voxel_reg = world->get_voxel_reg();
			// roughness, spec_strength, bumpiness, translucency, spots,
			// static_spots; see interface/atlas.h. The values are
			// voxel_lighting's, which is where they were chosen.
			// The game's own cut of a voxel word, before anything is
			// added: everything saved in this world is bits under it
			voxel_reg->set_format(aggregate_format());
			log_i(MODULE, "Voxel format: %s",
					cs(voxel_reg->get_format().dump()));

			// In Look's order, and nothing may be inserted in the middle:
			// the look rules point at these by number. The six numbers
			// after solid describe the surface; see interface/atlas.h.
			//
			// The tint ramps are how wet a material looks. The first end is
			// dry and the second is soaked, and the mesher moves along it
			// with the tint field -- which is where undermine's wet_dirt
			// material went.
			add_voxel(voxel_reg, "air", "", false, false, true);
			// Walked into rather than stood on: the player sinks to the pond
			// floor and can dig or climb out. Nothing simulates flow yet, so
			// a dug shore leaves a hole in the water rather than draining
			// it; that is phase 2.
			add_voxel(voxel_reg, "water", "main/water.png", true, false, false,
					0.28f, 1.0f, 6.0f, 0.0f, 0.05f);
			add_voxel(voxel_reg, "bedrock", "main/bedrock.png",
					true, true, false,
					0.98f, 0.10f, 0.7f, 0.0f, 0.0f, 0.02f);
			add_voxel(voxel_reg, "stone", "main/rock.png", true, true, false,
					0.95f, 0.15f, 0.5f, 0.0f, 0.0f, 0.04f);
			// Rock with nothing holding it together. undermine's rubble, and
			// it wears that texture, but here it is what unbonded rock *is*
			// rather than a material a falling one turns into.
			add_voxel(voxel_reg, "gravel", "main/rubble.png",
					true, true, false,
					0.97f, 0.20f, 1.1f, 0.0f, 0.0f, 0.05f, "", 0xd8d0c8);
			add_voxel(voxel_reg, "sand", "main/sand.png", true, true, false,
					0.96f, 0.25f, 0.45f, 0.0f, 0.0f, 0.03f, "", 0xa89880);
			add_voxel(voxel_reg, "soil", "main/dirt.png", true, true, false,
					0.98f, 0.15f, 0.6f, 0.0f, 0.0f, 0.04f, "", 0x907058);
			add_voxel(voxel_reg, "turf", "main/grass.png", true, true, false,
					0.90f, 1.0f, 0.75f, 0.06f, 0.012f, 0.0f, "", 0xa0a090);
			add_voxel(voxel_reg, "brick", "main/brick.png", true, true, false,
					0.92f, 0.30f, 0.9f, 0.0f, 0.0f, 0.02f);
			add_voxel(voxel_reg, "timber", "main/timber.png",
					true, true, false,
					0.85f, 0.35f, 1.4f, 0.0f, 0.0f, 0.0f, "", 0xa08868);
			add_voxel(voxel_reg, "trunk", "main/tree.png", true, true, false,
					0.85f, 0.35f, 2.0f, 0.0f, 0.0f, 0.0f,
					"main/tree_top.png");
			add_voxel(voxel_reg, "leaves", "main/leaves.png",
					true, true, false,
					0.95f, 1.0f, 1.5f, 0.11f, 0.03f);
			// Fibre with nothing holding it together: sawdust, mulch, a
			// rotted-through beam. It wears what undermine drew wet dirt
			// with, which is about the right colour for it.
			add_voxel(voxel_reg, "mulch", "main/wet_dirt.png",
					true, true, false,
					0.80f, 0.45f, 0.6f, 0.0f, 0.0f, 0.04f);

			// And what says which of them a voxel wears
			voxel_reg->set_look_selector(look_selector());

			// Every recipe reads back as the look it is named for. The
			// rules are ordered and their clauses are ANDed, which is easy
			// to get subtly wrong, and this is what says so at startup
			// rather than after a screenshot.
			{
				static const struct { const char *name; const Mix &mix;
						uint8_t want; } CHECK[] = {
					{"air", MIX_AIR, L_AIR},
					{"water", MIX_WATER, L_WATER},
					{"bedrock", MIX_BEDROCK, L_BEDROCK},
					{"stone", MIX_STONE, L_STONE},
					{"gravel", MIX_GRAVEL, L_GRAVEL},
					{"sand", MIX_SAND, L_SAND},
					{"soil", MIX_SOIL, L_SOIL},
					{"turf", MIX_TURF, L_TURF},
					{"brick", MIX_BRICK, L_BRICK},
					{"timber", MIX_TIMBER, L_TIMBER},
					{"trunk", MIX_TRUNK, L_TRUNK},
					{"leaves", MIX_LEAVES, L_LEAVES},
				};
				const interface::VoxelSelector &sel =
						voxel_reg->get_look_selector();
				const interface::VoxelFormat &fmt = voxel_reg->get_format();
				for(const auto &c : CHECK){
					interface::VoxelSample v = mix_voxel(c.mix);
					interface::VoxelTypeId got = sel.id_of(v, fmt);
					if(got != c.want){
						log_w(MODULE, "look rules: %s reads as %i and not "
								"%i", c.name, (int)got, (int)c.want);
					}
				}
			}

			world->set_skylight_enabled(true);
		});

		// Enable world generation now that the voxels are defined
		worldgen::access(m_server, m_main_scene, [&](worldgen::Instance *instance)
		{
			instance->enable();
		});
	}

	void on_unload()
	{
		// TODO: Store main scene reference
		// Just do this for now
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_main_scene);
		});
	}

	void on_continue()
	{
		// TODO: Restore main scene reference
		// Just do this for now
		on_start();
	}

	// Standing-height air along -X (player facing). No path check; long enough
	// that it is likely to hit a slope, pocket, or the world edge.
	void carve_spawn_tunnel(int floor_y)
	{
		const int length = 96;
		const int height = 3;
		const int half_w = 1;
		const int back = 2;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int dx = -back; dx < length; dx++){
				int x = SPAWN_X - dx;
				for(int dz = -half_w; dz <= half_w; dz++){
					int z = SPAWN_Z + dz;
					for(int dy = 1; dy <= height; dy++){
						world->set_sample(
								pv::Vector3DInt32(x, floor_y + dy, z),
								mix_voxel(MIX_AIR), true);
					}
				}
			}
		});
		log_i(MODULE, "Spawn tunnel: x=%i..%i y=%i..%i z=%i..%i",
				SPAWN_X + back, SPAWN_X - (length - 1),
				floor_y + 1, floor_y + height,
				SPAWN_Z - half_w, SPAWN_Z + half_w);
	}

	void send_spawn(network::PeerInfo::Id peer)
	{
		if(!m_spawn_ready)
			return;
		std::ostringstream os(std::ios::binary);
		cereal::PortableBinaryOutputArchive ar(os);
		double x = SPAWN_X;
		double y = m_spawn_y;
		double z = SPAWN_Z;
		ar(x, y, z);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:spawn", os.str());
		});
		log_v(MODULE, "Sent spawn (%.2f, %.2f, %.2f) to peer %zu",
				x, y, z, peer);
	}

	// The surface the player stands on: the first of the terrain materials
	// looking down. Air and water are not stood on.
	void try_resolve_spawn()
	{
		if(m_spawn_ready)
			return;
		int surface_y = SPAWN_Y_MIN - 1;
		bool column_ready = true;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int y = SPAWN_Y_MAX; y >= SPAWN_Y_MIN; y--){
				interface::VoxelSample v = world->get_sample(
						pv::Vector3DInt32(SPAWN_X, y, SPAWN_Z), true);
				if(!is_generated(v)){
					column_ready = false;
					return;
				}
				if(props_of(mix_of(v)).structural){
					surface_y = y;
					return;
				}
			}
		});
		if(!column_ready)
			return;
		if(surface_y < SPAWN_Y_MIN){
			log_w(MODULE, "Spawn column (%i, *, %i) has no terrain",
					SPAWN_X, SPAWN_Z);
			return;
		}
		carve_spawn_tunnel(surface_y);
		// Voxel n is a 1x1x1 cube centered at n; stand on its top face.
		m_spawn_y = (float)surface_y + 0.5f + PLAYER_HEIGHT / 2.0f + 0.05f;
		m_spawn_ready = true;
		log_i(MODULE, "Spawn at (%i, %.2f, %i) (terrain y=%i)",
				SPAWN_X, m_spawn_y, SPAWN_Z, surface_y);

		network::access(m_server, [&](network::Interface *inetwork){
			std::ostringstream os(std::ios::binary);
			cereal::PortableBinaryOutputArchive ar(os);
			double x = SPAWN_X;
			double y = m_spawn_y;
			double z = SPAWN_Z;
			ar(x, y, z);
			ss_ data = os.str();
			for(auto peer : inetwork->list_peers())
				inetwork->send(peer, "main:spawn", data);
		});
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		size_t queue_size = 0;
		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			queue_size = instance->get_num_sections_queued();
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
			inetwork->send(event.recipient, "main:worldgen_queue_size",
					itos(queue_size));
		});
		send_view_registries(event.recipient);
		send_spawn(event.recipient);
	}


	// The simulation
	// --------------
	//
	// One queue of voxels whose support and load are out of date, walked with
	// a budget per tick. Recomputing a voxel is a pure function of its
	// neighbours, so a change spreads outward by whatever it actually
	// changes: a dig into solid rock settles in a handful of voxels, and a
	// dig that takes a roof away walks as far as the roof reached.
	//
	// Support goes down rather than up when what was holding it goes away,
	// which the same relaxation handles by running to a fixed point: with no
	// source left, each round takes another step off what is left, so the
	// front dies out after at most SUPPORT_MAX rounds. That is why there is
	// no separate take-it-back-out pass of the kind update_skylight() needs
	// -- support is cheap to be wrong about for a tick, and light is not.
	static const size_t SIM_PER_TICK = 2048;
	static const size_t FALL_PER_TICK = 256;

	static int64_t pos_key(const pv::Vector3DInt32 &p)
	{
		// The world is far smaller than 2^20 on any axis
		return ((int64_t)(p.getX() & 0xfffff) << 40) |
				((int64_t)(p.getY() & 0xfffff) << 20) |
				(int64_t)(p.getZ() & 0xfffff);
	}

	void mark_dirty(const pv::Vector3DInt32 &p)
	{
		if(m_dirty_set.insert(pos_key(p)).second)
			m_dirty.push_back(p);
	}

	// What has to be looked at again after the voxel at p changed: itself,
	// the six around it -- support reaches sideways and up -- and the
	// LOAD_DEPTH voxels under it, which are the ones carrying it.
	void mark_changed(const pv::Vector3DInt32 &p)
	{
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		mark_dirty(p);
		for(size_t k = 0; k < 6; k++)
			mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
					p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		for(int i = 1; i <= LOAD_DEPTH; i++)
			mark_dirty(pv::Vector3DInt32(p.getX(), p.getY() - i, p.getZ()));
	}

	void mark_falling(const pv::Vector3DInt32 &p)
	{
		if(m_falling_set.insert(pos_key(p)).second)
			m_falling.push_back(p);
	}

	// The voxel at p as the simulation currently understands it: what the
	// relaxation has worked out, or what the world holds if it has not been
	// touched.
	interface::VoxelSample peek(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		auto it = m_scratch.find(pos_key(p));
		if(it != m_scratch.end())
			return it->second.v;
		return world->get_sample(p, true);
	}

	// How far the voxel at p is from something holding it up, 0 for nothing.
	//
	// A voxel standing on something supported is supported itself, whatever
	// it is made of: a column carries straight down and does not span
	// anything. Otherwise it reaches out sideways from its neighbours,
	// losing one step per voxel and never further than its material's span,
	// which is what decides how wide a tunnel a material will roof.
	uint8_t compute_support(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p, const MaterialProps &m)
	{
		if(!m.diggable)
			return SUPPORT_MAX; // Bedrock, and anything else immovable
		interface::VoxelSample below = peek(world,
				pv::Vector3DInt32(p.getX(), p.getY() - 1, p.getZ()));
		const MaterialProps bm = props_of(mix_of(below));
		if(bm.structural && support_of(below) > 0)
			return SUPPORT_MAX;
		if(m.span == 0)
			return 0;
		static const int SIDE[4][2] = {{1,0}, {-1,0}, {0,1}, {0,-1}};
		uint8_t best = 0;
		for(size_t k = 0; k < 4; k++){
			interface::VoxelSample n = peek(world, pv::Vector3DInt32(
					p.getX() + SIDE[k][0], p.getY(),
					p.getZ() + SIDE[k][1]));
			if(!props_of(mix_of(n)).structural)
				continue;
			uint8_t s = support_of(n);
			if(s > best)
				best = s;
		}
		if(best == 0)
			return 0;
		uint8_t reach = best - 1;
		return reach < m.span ? reach : m.span;
	}

	// Water, moved rather than assumed
	// -------------------------------
	//
	// Where phase 1 had a relaxation that made a voxel near a pond *look*
	// wet without taking the water from anywhere, this moves a quantity and
	// conserves it: what soaks into a bank comes out of the pond.
	//
	// Two rules, in order, and both are local:
	//
	//   down      into whatever room is under it
	//   sideways  towards the lower of two neighbours, half the difference,
	//             which is what levels a surface without oscillating
	//
	// simplified: **water does not climb.** Pressure wants a head, and a
	// head wants either a field with room above "full" to carry it or a
	// walk up the column to find one; neither fits in the eight bits this
	// game gives water, and both want measuring before they are written.
	// So a flooded shaft fills from the bottom and stops at the level it is
	// poured to. What that costs is the plan's "water climbs and seeps up
	// from below"; what it buys is a rule that cannot run away.
	//
	// Nothing here sweeps a volume: it rides the same dirty set the support
	// does, so the work is proportional to where water is actually moving.
	// A sweep is what the plan expected and it is not needed yet.

	// The least that is worth moving. Without it two neighbours a drop
	// apart trade that drop back and forth forever and the dirty set never
	// empties.
	static const int WATER_QUANTUM = 4;

	// Move water out of p if it has anywhere to go. mix is updated in place;
	// the neighbours are written straight into the scratch, so the next
	// voxel the relaxation looks at sees them.
	bool migrate_water(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p, Mix &mix)
	{
		if(mix.water < WATER_QUANTUM)
			return false;
		bool moved = false;

		// Down first, and as much as will go
		{
			const pv::Vector3DInt32 down(p.getX(), p.getY() - 1, p.getZ());
			interface::VoxelSample bv = peek(world, down);
			if(is_generated(bv)){
				Mix bmix = mix_of(bv);
				const int room = takes_water(bmix) ? water_room(bmix) : 0;
				const int move = (int)mix.water < room ? (int)mix.water : room;
				if(move >= WATER_QUANTUM){
					mix.water -= (uint8_t)move;
					bmix.water += (uint8_t)move;
					write_mix(bv, down, bmix);
					moved = true;
				}
			}
		}
		if(mix.water < WATER_QUANTUM)
			return moved;

		// Then level sideways. Half the difference, which settles rather
		// than sloshes.
		static const int SIDE[4][2] = {{1,0}, {-1,0}, {0,1}, {0,-1}};
		for(size_t k = 0; k < 4; k++){
			const pv::Vector3DInt32 n(p.getX() + SIDE[k][0], p.getY(),
					p.getZ() + SIDE[k][1]);
			interface::VoxelSample nv = peek(world, n);
			if(!is_generated(nv))
				continue;
			Mix nmix = mix_of(nv);
			if(!takes_water(nmix))
				continue;
			const int diff = (int)mix.water - (int)nmix.water;
			if(diff < WATER_QUANTUM * 2)
				continue;
			int move = diff / 2;
			const int room = water_room(nmix);
			if(move > room)
				move = room;
			if(move < WATER_QUANTUM)
				continue;
			mix.water -= (uint8_t)move;
			nmix.water += (uint8_t)move;
			write_mix(nv, n, nmix);
			moved = true;
			if(mix.water < WATER_QUANTUM)
				break;
		}
		return moved;
	}

	// A neighbour the migration changed: into the scratch, and dirty, so
	// that the water carries on moving next time round
	void write_mix(interface::VoxelSample v, const pv::Vector3DInt32 &p,
			const Mix &m)
	{
		set_mix(v, m);
		m_scratch[pos_key(p)] = Pending{p, v};
		mark_dirty(p);
	}

	// The weight resting on the voxel at p: the column immediately above it,
	// as far as LOAD_DEPTH. See LOAD_DEPTH for why it stops.
	uint8_t compute_load(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		int carried = 0;
		for(int i = 1; i <= LOAD_DEPTH; i++){
			interface::VoxelSample v = peek(world,
					pv::Vector3DInt32(p.getX(), p.getY() + i, p.getZ()));
			const MaterialProps m = props_of(mix_of(v));
			if(!m.structural)
				break;
			carried += m.density;
			if(carried >= LOAD_MAX)
				return LOAD_MAX;
		}
		return (uint8_t)carried;
	}

	// Work out one voxel again, write it if either number moved, and say
	// whether anything around it has to be looked at as a result.
	void update_voxel(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		interface::VoxelSample v = peek(world, p);
		if(!is_generated(v))
			return; // Not generated yet; whoever generates it computes both
		Mix mix = mix_of(v);
		const uint8_t water_was = mix.water;

		// Water first, and before the structural test: a voxel of water is
		// not structural and would otherwise never be looked at again. Where
		// undermine turned dirt into a wet_dirt material so that the mesher
		// could see the difference, here the water is simply part of what
		// the voxel is made of -- the tint darkens it and the capacity
		// drops, and no material changed into another one.
		migrate_water(world, p, mix);
		const bool wetness_moved = mix.water != water_was;

		MaterialProps m = props_of(mix);
		if(!m.structural){
			if(wetness_moved){
				interface::VoxelSample nv = v;
				set_mix(nv, mix);
				// Nothing structural: no load on it and none of it on
				// anything else, which is what a band of 0 says
				set_state(nv, 0, 0);
				m_scratch[pos_key(p)] = Pending{p, nv};
				mark_dirty(pv::Vector3DInt32(p.getX(), p.getY() + 1,
						p.getZ()));
			}
			return;
		}

		uint8_t support = compute_support(world, p, m);
		uint8_t load = compute_load(world, p);
		uint8_t band = load_band(load, m.capacity);
		bool support_moved = support != support_of(v);
		if(support_moved || wetness_moved || band != band_of(v)){
			interface::VoxelSample nv = v;
			set_mix(nv, mix);
			set_state(nv, support, band);
			m_scratch[pos_key(p)] = Pending{p, nv};
		}
		// A support that moved changes what the voxels around it can reach,
		// and so does water arriving or leaving
		if(support_moved || wetness_moved){
			static const int OFF[6][3] = {
				{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
			};
			for(size_t k = 0; k < 6; k++)
				mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
						p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		}
		// Nothing holds it, or what does cannot carry what is on it
		if(m.diggable && (support == 0 || load > m.capacity)){
			log_t(MODULE, "fails: " PV3I_FORMAT " support=%i load=%i",
					PV3I_PARAMS(p), (int)support, (int)load);
			mark_falling(p);
		}
	}

	// Move what is falling down one voxel, or turn it to rubble where it
	// stops. Lowest first, so a column comes down without opening a gap in
	// the middle of itself.
	size_t m_moved = 0;
	size_t m_landed = 0;

	void step_falling(voxelworld::Instance *world)
	{
		if(m_falling.empty())
			return;
		std::sort(m_falling.begin(), m_falling.end(),
				[](const pv::Vector3DInt32 &a, const pv::Vector3DInt32 &b){
			return a.getY() < b.getY();
		});
		size_t n = m_falling.size() < FALL_PER_TICK ?
				m_falling.size() : FALL_PER_TICK;
		std::vector<pv::Vector3DInt32> rest(m_falling.begin() + n,
				m_falling.end());
		std::vector<pv::Vector3DInt32> batch(m_falling.begin(),
				m_falling.begin() + n);
		m_falling = rest;
		for(const pv::Vector3DInt32 &p : batch){
			m_falling_set.erase(pos_key(p));
			interface::VoxelSample v = world->get_sample(p, true);
			Mix mix = mix_of(v);
			const MaterialProps m = props_of(mix);
			// It may have been dug, or held up again, since it was queued
			if(!m.structural || !m.diggable)
				continue;
			// The weight itself, not the band: the band is a fifteenth of a
			// capacity coarse and this is the test that decides whether
			// something comes down
			if(support_of(v) != 0 &&
					compute_load(world, p) <= m.capacity)
				continue;
			pv::Vector3DInt32 down(p.getX(), p.getY() - 1, p.getZ());
			interface::VoxelSample bv = world->get_sample(down, true);
			if(!is_generated(bv))
				continue; // Falling out of the loaded world; leave it be
			if(!props_of(mix_of(bv)).structural){
				// Down one. What it lands in is displaced rather than
				// simulated: nothing here flows.
				//
				// **Falling breaks the bond.** Where undermine turned
				// whatever fell into a rubble material, here the mixture is
				// unchanged and only the thing that was holding it together
				// is gone -- so soil that falls is still soil and merely
				// holds nothing up, which is what a heap of it should do,
				// and rock that falls is gravel because that is what
				// unbonded rock is.
				mix.bond = 0;
				interface::VoxelSample nv = v;
				set_mix(nv, mix);
				set_state(nv, 0, 1);
				world->set_sample(down, nv, true);
				world->set_sample(p, mix_voxel(MIX_AIR), true);
				mark_changed(p);
				mark_changed(down);
				mark_falling(down);
				m_moved++;
			} else {
				// It has come to rest on something. It keeps whatever it
				// became on the way down.
				m_landed++;
			}
		}
	}

	// Everything the relaxation worked out, into the world in one go.
	//
	// simplified: the whole scratch goes at once rather than on a budget. It
	// is one set_sample() per voxel the front passed over, which is the work
	// that used to happen several times each.
	void flush_scratch(voxelworld::Instance *world)
	{
		if(m_scratch.empty())
			return;
		for(auto &e : m_scratch)
			world->set_sample(e.second.p, e.second.v, true);
		m_wrote += m_scratch.size();
		m_scratch.clear();
	}

	size_t m_wrote = 0;

	void on_tick(const interface::TickEvent &event)
	{
		if(m_dirty.empty() && m_falling.empty())
			return;
		auto t0 = std::chrono::steady_clock::now();
		size_t done = 0;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			while(!m_dirty.empty() && done < SIM_PER_TICK){
				pv::Vector3DInt32 p = m_dirty.front();
				m_dirty.pop_front();
				m_dirty_set.erase(pos_key(p));
				update_voxel(world, p);
				done++;
			}
			// Into the world once the front has passed, or when something
			// is about to move and the relaxation's answers are needed
			if(m_dirty.empty() || !m_falling.empty() ||
					m_scratch.size() > 8192)
				flush_scratch(world);
			step_falling(world);
		});
		if(done >= SIM_PER_TICK || !m_falling.empty()){
			log_v(MODULE, "sim: %zu done in %i us, %zu dirty, %zu pending, "
					"%zu falling, %zu fell, %zu came to rest, %zu written",
					done, (int)std::chrono::duration_cast<
							std::chrono::microseconds>(
							std::chrono::steady_clock::now() - t0).count(),
					m_dirty.size(), m_scratch.size(), m_falling.size(),
					m_moved, m_landed, m_wrote);
		}
	}


	// Structures
	// ----------
	//
	// Finding out what happens when a pillar is cut should not start with an
	// hour of bricklaying, so the game can put a building up for you. Each is
	// a loop rather than a table of voxels: parametric, a few dozen lines,
	// and no data to keep in step with the material ids.
	//
	// A structure carries its own air. A cathedral inside a hill is no use,
	// so the footprint is cleared as it is written -- which is why this is
	// set_voxel() per voxel and not Instance::merge_volume(), whose whole
	// contract is that it does not overwrite what is already there.
	//
	// Everything is written first and only then handed to the simulation.
	// Halfway through, a cathedral is an unsupported roof, and it would come
	// down while it was being built.
	struct Build
	{
		std::vector<std::pair<pv::Vector3DInt32, Mix>> voxels;

		void box(int x0, int y0, int z0, int x1, int y1, int z1,
				const Mix &material)
		{
			for(int y = y0; y <= y1; y++)
				for(int z = z0; z <= z1; z++)
					for(int x = x0; x <= x1; x++)
						voxels.push_back(
								{pv::Vector3DInt32(x, y, z), material});
		}
	};

	// A hollow room with a flat roof, wide enough that rock cannot span it:
	// the middle of the roof has nothing to reach and comes down as soon as
	// the simulation looks at it. The smallest thing that shows the rules
	// working, and the one to place first when they change.
	static void build_chamber(Build &b, const pv::Vector3DInt32 &o)
	{
		const int half = 7; // 15 across, and rock spans 6
		const int height = 5;
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half, y0, z0 - half,
				x0 + half, y0 + height, z0 + half, MIX_AIR);
		b.box(x0 - half - 1, y0 - 1, z0 - half - 1,
				x0 + half + 1, y0 - 1, z0 + half + 1, MIX_BRICK);
		b.box(x0 - half - 1, y0 + height + 1, z0 - half - 1,
				x0 + half + 1, y0 + height + 1, z0 + half + 1, MIX_STONE);
		for(int y = y0; y <= y0 + height; y++){
			b.box(x0 - half - 1, y, z0 - half - 1,
					x0 - half - 1, y, z0 + half + 1, MIX_STONE);
			b.box(x0 + half + 1, y, z0 - half - 1,
					x0 + half + 1, y, z0 + half + 1, MIX_STONE);
			b.box(x0 - half - 1, y, z0 - half - 1,
					x0 + half + 1, y, z0 - half - 1, MIX_STONE);
			b.box(x0 - half - 1, y, z0 + half + 1,
					x0 + half + 1, y, z0 + half + 1, MIX_STONE);
		}
	}

	// A nave with a row of brick pillars down each side carrying a rock roof,
	// and timber tie beams across between the pillars. The pillars are what
	// hold it up: cut one and the roof over it has to reach the next one,
	// which is further than rock spans.
	static void build_cathedral(Build &b, const pv::Vector3DInt32 &o)
	{
		const int half_w = 6;   // 13 across inside
		const int length = 28;
		const int height = 10;
		const int spacing = 4;  // pillars this far apart along the nave
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half_w - 1, y0, z0 - 1,
				x0 + half_w + 1, y0 + height + 2, z0 + length + 1, MIX_AIR);
		b.box(x0 - half_w - 1, y0 - 1, z0 - 1,
				x0 + half_w + 1, y0 - 1, z0 + length + 1, MIX_BRICK);
		for(int z = z0; z <= z0 + length; z += spacing){
			for(int side = -1; side <= 1; side += 2){
				int x = x0 + side * half_w;
				b.box(x, y0, z, x, y0 + height, z, MIX_BRICK);
			}
			// A tie beam across, which is what a timber prop is for: long
			// span, and it carries only the roof over the nave
			b.box(x0 - half_w + 1, y0 + height, z,
					x0 + half_w - 1, y0 + height, z, MIX_TIMBER);
		}
		b.box(x0 - half_w, y0 + height + 1, z0,
				x0 + half_w, y0 + height + 1, z0 + length, MIX_STONE);
	}

	// A deck on piers. Saw through a pier and the deck over it is left
	// spanning twice the distance, which rock will not do.
	static void build_bridge(Build &b, const pv::Vector3DInt32 &o)
	{
		const int length = 40;
		const int half_w = 2;
		const int spacing = 10;
		const int depth = 12; // how far down the piers reach for ground
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half_w, y0 + 1, z0,
				x0 + half_w, y0 + 4, z0 + length, MIX_AIR);
		b.box(x0 - half_w, y0, z0, x0 + half_w, y0, z0 + length, MIX_STONE);
		// Parapets, so it reads as a bridge from on it
		b.box(x0 - half_w, y0 + 1, z0,
				x0 - half_w, y0 + 1, z0 + length, MIX_BRICK);
		b.box(x0 + half_w, y0 + 1, z0,
				x0 + half_w, y0 + 1, z0 + length, MIX_BRICK);
		for(int z = z0; z <= z0 + length; z += spacing)
			b.box(x0 - 1, y0 - depth, z, x0 + 1, y0 - 1, z, MIX_BRICK);
	}

	// A mineshaft: a corridor with a timber prop frame every few voxels,
	// which is what the game teaches you to build by hand.
	static void build_mineshaft(Build &b, const pv::Vector3DInt32 &o)
	{
		const int length = 40;
		const int half_w = 2;   // 5 across, which dirt cannot roof alone
		const int height = 3;
		const int spacing = 3;
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half_w, y0, z0,
				x0 + half_w, y0 + height, z0 + length, MIX_AIR);
		for(int z = z0; z <= z0 + length; z += spacing){
			b.box(x0 - half_w, y0, z, x0 - half_w, y0 + height, z, MIX_TIMBER);
			b.box(x0 + half_w, y0, z, x0 + half_w, y0 + height, z, MIX_TIMBER);
			b.box(x0 - half_w, y0 + height, z,
					x0 + half_w, y0 + height, z, MIX_TIMBER);
		}
	}

	void on_place_structure(const network::Packet &packet)
	{
		ss_ name;
		pv::Vector3DInt32 p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(name, p);
		}
		Build b;
		if(name == "chamber")
			build_chamber(b, p);
		else if(name == "cathedral")
			build_cathedral(b, p);
		else if(name == "bridge")
			build_bridge(b, p);
		else if(name == "mineshaft")
			build_mineshaft(b, p);
		else {
			log_w(MODULE, "C%i: no structure called \"%s\"",
					packet.sender, cs(name));
			return;
		}
		log_i(MODULE, "C%i: %s at " PV3I_FORMAT ", %zu voxels",
				packet.sender, cs(name), PV3I_PARAMS(p), b.voxels.size());

		// simplified: the whole thing goes in on one tick. A cathedral is a
		// few thousand set_voxel() calls, which is a hitch and not a stall,
		// and it is a deliberate action rather than something that happens
		// while playing. A budget over ticks is the upgrade path, and it
		// would have to keep the simulation off the footprint until the last
		// voxel is in.
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(auto &vp : b.voxels){
				interface::VoxelSample v = mix_voxel(vp.second);
				// Held up until the simulation says otherwise, so that the
				// building does not fall over as it is written
				set_state(v, SUPPORT_MAX, 1);
				world->set_sample(vp.first, v, true);
			}
		});
		// And now let it stand or fall as a whole
		for(auto &vp : b.voxels)
			mark_changed(vp.first);

		// What it takes up, so that a client in free move can put itself
		// somewhere the whole thing is in frame instead of the player having
		// to fly around looking for it
		pv::Vector3DInt32 lc = b.voxels[0].first, uc = b.voxels[0].first;
		for(auto &vp : b.voxels){
			lc.setX(std::min(lc.getX(), vp.first.getX()));
			lc.setY(std::min(lc.getY(), vp.first.getY()));
			lc.setZ(std::min(lc.getZ(), vp.first.getZ()));
			uc.setX(std::max(uc.getX(), vp.first.getX()));
			uc.setY(std::max(uc.getY(), vp.first.getY()));
			uc.setZ(std::max(uc.getZ(), vp.first.getZ()));
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(lc, uc);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:structure_placed", os.str());
		});
	}

	void on_place_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		int32_t material = B_STONE;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p, material);
		}
		// Water is placeable even though the rules do not treat it as
		// structural: pouring some next to soil is how you find out what
		// water does to soil, which is most of what there is to find out.
		if(material < B_STONE || material >= B_COUNT){
			log_w(MODULE, "C%i: on_place_voxel(): material %i is not one to "
					"build with", packet.sender, material);
			return;
		}
		log_v(MODULE, "C%i: on_place_voxel(): p=" PV3I_FORMAT " material=%i",
				packet.sender, PV3I_PARAMS(voxel_p), material);

		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			interface::VoxelSample v = mix_voxel(build_mix(material));
			// Something just placed is held up by whatever it was placed
			// against until the simulation says otherwise, which keeps a
			// prop from falling in the tick before it is looked at
			set_state(v, SUPPORT_MAX, 1);
			instance->set_sample(voxel_p, v);
		});
		mark_changed(voxel_p);
	}

	void on_dig_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		}
		log_v(MODULE, "C%i: on_dig_voxel(): p=" PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(voxel_p));

		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			interface::VoxelSample old = instance->get_sample(voxel_p, true);
			if(!props_of(mix_of(old)).diggable){
				log_v(MODULE, "C%i: on_dig_voxel(): not diggable",
						packet.sender);
				return;
			}
			instance->set_sample(voxel_p, mix_voxel(MIX_AIR));
		});
		mark_changed(voxel_p);
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &event)
	{
		log_t(MODULE, "on_worldgen_queue_modified()");
		network::access(m_server, [&](network::Interface *inetwork){
			sv_<network::PeerInfo::Id> peers = inetwork->list_peers();
			for(auto &peer: peers){
				inetwork->send(peer, "main:worldgen_queue_size",
						itos(event.queue_size));
			}
		});
		if(event.queue_size == 0)
			try_resolve_spawn();
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
