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

	struct VoxelDefinition
	{
		VoxelName name;
		VoxelTypeId id = VOXELTYPEID_UNDEFINED;
		// Textures (voxels have 6 sides)
		// These must be definitions (not references) because each client has to
		// be able to construct their atlases from different texture sizes
		AtlasSegmentDefinition textures[6];
		// Other properties
		ss_ handler_module;
		FaceDrawType face_draw_type = FaceDrawType::ON_EDGE;
		EdgeMaterialId edge_material_id = EDGEMATERIALID_EMPTY;
		bool physically_solid = false;
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

		bool textures_valid = false;
		AtlasSegmentReference textures[6];
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

		// atlas_reg may only be supplied when called from Urho3D main thread
		virtual const CachedVoxelDefinition* get_cached(const VoxelTypeId &id,
				AtlasRegistry *atlas_reg = nullptr) = 0;
		virtual const CachedVoxelDefinition* get_cached(const VoxelInstance &v,
				AtlasRegistry *atlas_reg = nullptr) = 0;

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
	};
}
// vim: set noet ts=4 sw=4:
