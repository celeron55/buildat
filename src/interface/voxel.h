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
		// TODO: Flag for whether all faces should be always drawn (in case the
		//       textures contain holes)
		// TODO: Some kind of property for defining whether this is a thing for
		//       which adjacent voxels of the same thing type don't have faces,
		//       and what thing type that is in this case
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

		uint8_t tile_turns[6] = {};

		bool textures_valid = false;
		AtlasSegmentReference textures[6];
		// The LOD segments are only built for a volume that is actually
		// meshed at a LOD: building one is a texture loaded, scaled and drawn
		// into an atlas, and there are VOXELDEF_NUM_LOD of them per face
		bool lod_textures_valid = false;
		AtlasSegmentReference lod_textures[VOXELDEF_NUM_LOD][6];
	};

	struct VoxelInstance;

	struct VoxelRegistry
	{
		virtual ~VoxelRegistry(){}

		virtual void clear() = 0;
		virtual sv_<VoxelDefinition> get_all() = 0;

		virtual VoxelTypeId add_voxel(const VoxelDefinition &def) = 0;

		virtual const VoxelDefinition* get(const VoxelTypeId &id) = 0;
		virtual const VoxelDefinition* get(const VoxelName &name) = 0;

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
