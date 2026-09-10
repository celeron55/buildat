// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/atlas.h"
#include <PolyVoxCore/Vector.h>

namespace interface
{
	namespace pv = PolyVox;

	typedef uint32_t VoxelTypeId;
	static constexpr VoxelTypeId VOXELTYPEID_MAX = 1398101-1;
	static constexpr VoxelTypeId VOXELTYPEID_UNDEFINED = 0;

	struct VoxelName
	{
		ss_ block_name; // Name of the block this was instanced from
		uint8_t segment_x = 0; // Which segment of the block this was instanced from
		uint8_t segment_y = 0;
		uint8_t segment_z = 0;
		// 4 possible rotations when looking at a face
		uint8_t rotation_primary = 0;
		// 6 possible directions for a face to point to
		uint8_t rotation_secondary = 0;

		ss_ dump() const;
		bool operator==(const VoxelName &other) const;
	};

	enum class FaceDrawType {
		NEVER = 0,
		ALWAYS = 1,
		ON_EDGE = 2,
	};

	// A thing that allows distinguishing which voxel faces generate edges
	typedef uint8_t EdgeMaterialId;
	static constexpr EdgeMaterialId EDGEMATERIALID_EMPTY = 0;
	static constexpr EdgeMaterialId EDGEMATERIALID_GROUND = 1;
	// Values at and above 10 are freely usable.

	// One quad of a shape a voxel has instead of being a cube.
	//
	// The corners are in the voxel's own cube, which runs -0.5...0.5 on each
	// axis, wound so that the quad faces the way its winding says. The
	// texture coordinates are in the tile's own 0...1, with 0,0 at its top
	// left, and the mesher maps them into wherever the atlas put that tile.
	// tile is which of the voxel's six textures this quad wears.
	//
	// This is deliberately not a box, a mesh name or anything else with a
	// shape of its own: a game that wants stairs, fences, plants, rails or a
	// pane of glass builds the quads it wants and the mesher copies them.
	struct VoxelQuad
	{
		float p[4][3] = {};
		float uv[4][2] = {};
		uint8_t tile = 0;
		// When this quad is drawn at all:
		//   0     always
		//   1...6 only when the neighbour in that direction connects, the
		//         faces in their usual order, so 1 is +Y and 6 is -Z
		//   7     only when none of the six connects
		// What wants it is a fence, which is a post plus a rail per
		// direction that has something to reach, and a pane, which is a
		// short post when it stands alone. See connect_group below for what
		// "connects" means.
		uint8_t connect_dir = 0;
	};

	// What a voxel's param changes about how it is drawn.
	//
	// The engine hands a definition the param and the definition answers with
	// one of these; what the param *means* is the game's business, and the
	// engine's job stops at "look it up and draw that". This is what keeps a
	// voxel that faces one of twenty-four directions, or wears one of eight
	// palette colours, from needing a voxel type of its own for every case.
	//
	// A variant carries no textures. It permutes the definition's own six --
	// tile_order[f] is which of them face f wears -- because a turned cube
	// wears the same textures as an unturned one, in a different order.
	struct VoxelVariant
	{
		// Quads of the voxel's own instead of the definition's; empty for
		// the definition's own shape. See VoxelDefinition::shape.
		sv_<VoxelQuad> shape;
		uint8_t tile_order[6] = {0, 1, 2, 3, 4, 5};
		uint8_t tile_turns[6] = {};
		// Multiplied into the vertex colour, 0xRRGGBB.
		//
		// The vertex colour is light, not albedo -- the mesher packs it as
		// interface/mesh.h says -- so this tints the light a voxel receives
		// and *not* its texture. What that is right for is a voxel that
		// glows or sits in coloured shade. What it is not right for is a
		// palette: a palette multiplies the texture, and the sky's own
		// contribution to the lighting is a scalar here and cannot be
		// tinted, so a palette entry would show in shade and vanish in
		// sunlight. An albedo tint wants a channel of its own; see
		// local/voxel_data_model_plan.md.
		uint32_t color = 0xffffff;
		// Where a liquid's surface stands in the voxel; see
		// VoxelDefinition::liquid_top. Luanti's flowing liquids put their
		// level in param2.
		float liquid_top = 0.5f;
	};

	struct VoxelDefinition
	{
		VoxelName name;
		VoxelTypeId id = VOXELTYPEID_UNDEFINED;
		// Textures (voxels have 6 sides)
		// These must be definitions (not references) because each client has to
		// be able to construct their atlases from different texture sizes
		AtlasSegmentDefinition textures[6];
		// Quarter turns anticlockwise to give each face's texture inside the
		// face, 0...3. What wants this is a voxel that faces a direction: the
		// texture of the top of a turned cube is turned with it, and the same
		// texture is shared with the cube that is not turned, so the turn
		// belongs to the face rather than to the atlas segment.
		uint8_t tile_turns[6] = {};
		// Other properties
		ss_ handler_module;
		FaceDrawType face_draw_type = FaceDrawType::ON_EDGE;
		EdgeMaterialId edge_material_id = EDGEMATERIALID_EMPTY;
		bool physically_solid = false;
		// Nothing whatsoever occupies this voxel: it is air, or something
		// that behaves as air and only differs in what the game makes of it.
		//
		// This is not the same as EDGEMATERIALID_EMPTY, which only says that
		// the cube faces against this voxel are not drawn; a voxel can do
		// that and still hold a mesh of its own shape inside itself. What
		// wants to know whether a voxel is free is this flag.
		bool fully_empty = false;
		// A shape of the voxel's own instead of a cube. Empty for a cube,
		// which is what most voxels are and the fast path the voxel mesher
		// exists for; a voxel with quads has them copied into the chunk's
		// mesh, which costs about what its own faces would have.
		//
		// A voxel with a shape usually wants face_draw_type NEVER and
		// edge_material_id EMPTY as well: the cube faces it would otherwise
		// have are not what it looks like, and its neighbours should draw
		// their faces against it.
		sv_<VoxelQuad> shape;
		// Draw the shape's quads from both sides. What wants it is a shape
		// made of single quads -- a plant, a rail, a sign -- which is
		// otherwise invisible from behind. A shape made of boxes does not.
		bool shape_double_sided = false;
		// The voxel's faces are alpha blended rather than opaque or alpha
		// masked, so they belong in a pass drawn after the solid world and
		// back to front: water, and glass a game gave an alpha to. The
		// mesher puts them in a geometry of their own; what technique that
		// gets is the game's business, as with the rest of the materials.
		bool translucent = false;
		// Which family of shapes this voxel's shape belongs to, or 0 for
		// none. A shape's quad is not drawn when the neighbour it faces has
		// the same group: that is what keeps the faces inside a body of water
		// out of the mesh, where the cube case has edge_material_id for the
		// same job. Water and lava are different groups, so the face between
		// them is drawn.
		//
		// Only an axis-aligned quad on the voxel's own boundary is tested;
		// the neighbour looked at is the one the quad's normal points into.
		uint8_t shape_group = 0;
		// A liquid, and where its surface stands inside the voxel:
		// -0.5...0.5, which is 0.5 for a liquid drawn as a full cube. Two
		// liquid voxels are the same liquid when their shape_group matches.
		//
		// A liquid that has a shape gets the top corners of that shape moved
		// to the average of the surfaces around each corner, so that a
		// sloping surface is continuous rather than stepped. That is Luanti's
		// getCornerLevel, and it is the one thing here the mesher works out
		// per voxel instead of per definition.
		bool is_liquid = false;
		float liquid_top = 0.5f;
		// Which family of connecting voxels this one belongs to, 1...32, or
		// 0 for one nothing reaches out to; and which families this one
		// reaches out to, as a bit per family. A fence and its gates are one
		// family, a wall another, panes and bars a third.
		//
		// The mesher looks at the six neighbours of a voxel whose shape has
		// quads with a connect_dir and draws each of those quads only when
		// its own direction connects. The cost of that is the same whatever
		// the families are, and the mask is where the two ends meet: the
		// game works out the families once, from whatever its own rules are,
		// and the mesher only tests a bit.
		uint8_t connect_group = 0;
		uint32_t connect_mask = 0;
		// A whole shape per neighbour mask, for a voxel that does not gain a
		// piece per direction but changes altogether: a rail, which is one
		// quad wearing one of four tiles turned one of four ways. When this
		// is not empty it is used instead of `shape`.
		//
		// Masks 0...15 are the four horizontal connections, in Luanti's own
		// bit order for them: +Z is 1, -Z is 2, -X is 4 and +X is 8. Masks
		// 16...19 are for a voxel that has one of itself a step up in that
		// direction -- +Z, -Z, -X, +X in that order -- which is what a rail
		// climbing a slope is; they win over the flat ones.
		//
		// The quads of mask m are shape_masked[begin[m]...begin[m + 1] - 1],
		// which is one vector and twenty-one offsets rather than twenty
		// vectors: this struct is read by the mesher a definition at a time
		// and wants to stay in cache.
		sv_<VoxelQuad> shape_masked;
		uint16_t shape_masked_begin[21] = {};
		// Also connect to any neighbour that is solid, whatever family it is
		// in. Luanti's connect_sides, which is how a fence reaches into the
		// stone next to it.
		//
		// simplified: Luanti says which of the six sides may be reached that
		// way and this is all of them.
		bool connect_to_solid = false;
		// What the voxel's param does to how it is drawn, if anything. Empty
		// means the param is ignored here, which is the common case and the
		// one the mesher hoists out of its inner loop.
		//
		// variant_of_param maps a param value to an entry of variants, so
		// that the twenty-four turns of a facedir are twenty-four variants
		// behind two hundred and fifty-six bytes of index rather than two
		// hundred and fifty-six variants. Only a param up to 8 bits wide is
		// looked up this way; a wider one is storage for the game to read
		// itself, not something the mesher indexes.
		sv_<VoxelVariant> variants;
		uint8_t variant_of_param[256] = {};
		// TODO: Flag for whether all faces should be always drawn (in case the
		//       textures contain holes)
	};

	static constexpr size_t VOXELDEF_NUM_LOD = 3;

	// This definition should be as small as practical so that large portions of
	// the definition array can fit in CPU cache
	// (the absolute maximum number of these is VOXELTYPEID_MAX+1)
	struct CachedVoxelDefinition
	{
		bool valid = false;
		ss_ handler_module;
		FaceDrawType face_draw_type = FaceDrawType::ON_EDGE;
		EdgeMaterialId edge_material_id = EDGEMATERIALID_EMPTY;
		bool physically_solid = false;
		bool fully_empty = false;
		// Copied from the definition; see VoxelDefinition::shape
		sv_<VoxelQuad> shape;
		bool shape_double_sided = false;
		bool translucent = false;
		uint8_t shape_group = 0;
		bool is_liquid = false;
		float liquid_top = 0.5f;
		uint8_t connect_group = 0;
		uint32_t connect_mask = 0;
		bool connect_to_solid = false;
		// Copied from the definition; see VoxelDefinition::shape_masked
		sv_<VoxelQuad> shape_masked;
		uint16_t shape_masked_begin[21] = {};
		// Copied from the definition; see VoxelDefinition::variants
		sv_<VoxelVariant> variants;
		uint8_t variant_of_param[256] = {};

		uint8_t tile_turns[6] = {};

		// What a param value says about drawing this voxel, or nullptr when
		// the param changes nothing about it
		const VoxelVariant* variant(uint32_t param) const {
			if(variants.empty())
				return nullptr;
			size_t i = variant_of_param[param & 0xff];
			return i < variants.size() ? &variants[i] : nullptr;
		}

		bool textures_valid = false;
		AtlasSegmentReference textures[6];
		// The LOD segments are only built for a volume that is actually
		// meshed at a LOD: building one is a texture loaded, scaled and drawn
		// into an atlas, and there are VOXELDEF_NUM_LOD of them per face
		bool lod_textures_valid = false;
		AtlasSegmentReference lod_textures[VOXELDEF_NUM_LOD][6];
	};

	// Where one of the engine's roles lives inside a voxel.
	//
	// width 0 means the role is not bound at all, which is not the same as a
	// role that is always zero: a world with no light bound is not a dark
	// world, it is one where nothing asks about light.
	struct VoxelField
	{
		uint8_t plane = 0;
		uint8_t shift = 0;
		uint8_t width = 0;

		// Not an aggregate: the members have initializers and this is C++11
		VoxelField(){}
		VoxelField(uint8_t plane, uint8_t shift, uint8_t width):
			plane(plane), shift(shift), width(width){}

		bool bound() const { return width != 0; }

		uint32_t mask() const {
			return width >= 32 ? 0xffffffffUL : ((1UL << width) - 1);
		}

		uint32_t get(uint32_t word) const {
			return (word >> shift) & mask();
		}

		void set(uint32_t &word, uint32_t value) const {
			uint32_t m = mask() << shift;
			word = (word & ~m) | ((value << shift) & m);
		}

		bool operator==(const VoxelField &o) const {
			return plane == o.plane && shift == o.shift && width == o.width;
		}
	};

	// How a game cuts up a voxel: which bits are the type id, which are
	// light, which are a parameter the definitions interpret, which are a
	// colour, and what is left over for the game's own use.
	//
	// A format belongs to a VoxelRegistry, is set before the first voxel is
	// added to it and never after, and travels to clients with it. So a
	// volume plus its world's registry is self-describing, and nothing that
	// takes a volume needs to take a format as well.
	//
	// The default is legacy(), which is the cut the engine had before this
	// existed, bit for bit. A game that says nothing keeps it.
	struct VoxelFormat
	{
		VoxelField id;
		VoxelField light_sky;
		VoxelField light_lamp;
		// What a definition's own rule interprets: which way a voxel faces,
		// how high a liquid stands in it, which entry of a palette it wears.
		// The engine hands it to the definition and the definition says what
		// it means; see VoxelDefinition::variants.
		VoxelField param;
		// A colour multiplied into the vertex colour, as 0xRRGGBB or
		// 0xAARRGGBB by its width. What wants it is a game whose voxels are
		// colours rather than types.
		VoxelField color;

		// The voxel is one 32-bit word for now. Planes are the next step;
		// this is the field that becomes a list.
		uint8_t plane_bits = 32;

		static VoxelFormat legacy()
		{
			VoxelFormat f;
			f.id = VoxelField{0, 0, 21};
			f.light_sky = VoxelField{0, 24, 4};
			f.light_lamp = VoxelField{0, 28, 4};
			return f;
		}

		// Luanti's own cut, which fits the same word exactly: a 16-bit node
		// id, param1 as two light nibbles, and param2.
		static VoxelFormat luanti()
		{
			VoxelFormat f;
			f.id = VoxelField{0, 0, 16};
			f.light_sky = VoxelField{0, 16, 4};
			f.light_lamp = VoxelField{0, 20, 4};
			f.param = VoxelField{0, 24, 8};
			return f;
		}

		// The type id of a voxel. A format with no id bound has exactly one
		// voxel type -- what wants that is a painter, whose voxels are all
		// the same kind of thing wearing a colour -- and it is type 1 rather
		// than 0 because 0 is VOXELTYPEID_UNDEFINED, which means "nothing
		// has generated this yet".
		VoxelTypeId id_of(uint32_t word) const {
			return id.bound() ? (VoxelTypeId)id.get(word) : 1;
		}

		// Both light roles as one field, for a caller that writes them
		// together (pack_voxel_volume's "light"). Only when they are
		// adjacent in the same plane with the sky light in the low bits,
		// which is the only arrangement that can be one write.
		bool light_pair(VoxelField *out) const;

		// Every bound field is inside its plane, no two overlap, and the id
		// fits VOXELTYPEID_MAX. why, when given, gets the first reason it
		// did not.
		bool validate(ss_ *why = nullptr) const;

		ss_ dump() const;
	};

	// Asserts the invariants of VoxelField and VoxelFormat: the accessors
	// round-trip, the built-in formats validate, malformed ones do not, and
	// legacy() read through a format agrees with VoxelInstance's own
	// hardcoded cut. Runs once, from createVoxelRegistry().
	bool voxel_format_self_test();

	struct VoxelInstance;

	struct VoxelRegistry
	{
		virtual ~VoxelRegistry(){}

		virtual void clear() = 0;
		virtual sv_<VoxelDefinition> get_all() = 0;

		// How a voxel word is cut up; see VoxelFormat. The default is
		// VoxelFormat::legacy().
		//
		// set_format() may only be called while the registry holds no voxel
		// definitions, which in practice means before a world generates
		// anything: everything saved in the world, and every volume on its
		// way to a client, is bits under this format, and there is no
		// migration for changing it underneath them. It throws on a format
		// that does not validate and on one that arrives too late.
		virtual const VoxelFormat& get_format() = 0;
		virtual void set_format(const VoxelFormat &format) = 0;

		virtual VoxelTypeId add_voxel(const VoxelDefinition &def) = 0;

		virtual const VoxelDefinition* get(const VoxelTypeId &id) = 0;
		virtual const VoxelDefinition* get(const VoxelName &name) = 0;

		// Every method is safe to call from a worker thread while the main
		// thread adds voxels, and a pointer handed out stays valid; the
		// contents of a definition do not change once it has been added.
		//
		// atlas_reg may only be supplied when called from Urho3D main thread.
		// with_lod also builds the segments a LOD mesh samples, which is
		// most of the cost of a voxel type's textures.
		virtual const CachedVoxelDefinition* get_cached(const VoxelTypeId &id,
				AtlasRegistry *atlas_reg = nullptr, bool with_lod = false) = 0;
		virtual const CachedVoxelDefinition* get_cached(const VoxelInstance &v,
				AtlasRegistry *atlas_reg = nullptr, bool with_lod = false) = 0;

		virtual bool is_dirty() = 0;
		virtual void clear_dirty() = 0;

		void serialize(std::ostream &os);
		void deserialize(std::istream &is);
		ss_  serialize();
		void deserialize(const ss_ &s);
	};

	VoxelRegistry* createVoxelRegistry();

	// One voxel, as the engine's default format cuts it up.
	//
	// The accessors below are that format's bit ranges written out by hand,
	// and they are only right for a world that kept it. Anything that reads
	// a voxel of a world whose format the game chose goes through
	// VoxelFormat instead -- get_format() on the world's registry -- and the
	// mesher does. What is left using these is code that only ever sees the
	// default cut: the sample games, and the modules built for them.
	struct VoxelInstance
	{
		uint32_t data;

		VoxelInstance(){}
		// Create voxel from raw data (MSBs are preserved)
		VoxelInstance(uint32_t id): data(id){}

		VoxelTypeId get_id() const {return data & 0x001fffff; }
		uint8_t getMSB() const {return (data>>24) & 0xff; }

		// Bits 24..27 hold skylight. It is only meaningful in transparent
		// voxels: the mesher reads it from the voxel in front of each face.
		// Nothing computes it by default; a world opts in by filling it.
		static const uint8_t SKYLIGHT_MAX = 15;
		uint8_t get_skylight() const {return (data>>24) & 0x0f; }
		void set_skylight(uint8_t l){
			data = (data & ~0x0f000000UL) | ((uint32_t)(l & 0x0f) << 24);
		}

		// Bits 28..31 hold lamplight: light that reaches the voxel from
		// something other than the sky, which is a torch or a lava flow or
		// whatever else a world has. Read the same way as skylight, and
		// separate from it because the sky's contribution changes with the
		// time of day and a lamp's does not: a shader that is handed both can
		// move the sun without anything being meshed again.
		static const uint8_t LAMPLIGHT_MAX = 15;
		uint8_t get_lamplight() const {return (data>>28) & 0x0f; }
		void set_lamplight(uint8_t l){
			data = (data & ~0xf0000000UL) | ((uint32_t)(l & 0x0f) << 28);
		}
	};
}
// vim: set noet ts=4 sw=4:
