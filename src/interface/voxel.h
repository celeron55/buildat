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
	static constexpr uint32_t VOXELTYPEID_MAX = 1398101-1;
	static constexpr uint32_t VOXELTYPEID_UNDEFINED = 0;

	struct VoxelName
	{
		ss_ block_name;	// Name of the block this was instanced from
		uint segment_x = 0;	// Which segment of the block this was instanced from
		uint segment_y = 0;
		uint segment_z = 0;
		uint rotation_primary = 0;	// 4 possible rotations when looking at a face
		uint rotation_secondary = 0;// 6 possible directions for a face to point to
	};

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
		// TODO: Flag for whether all faces should be always drawn (in case the
		//       textures contain holes)
		// TODO: Flag for whether this voxel is physically solid
		// TODO: Some kind of property for defining whether this is a thing for
		//       which adjacent voxels of the same thing type don't have faces,
		//       and what thing type that is in this case
	};

	// This definition should be as small as practical so that large portions of
	// the definition array can fit in CPU cache
	// (the absolute maximum number of these is VOXELTYPEID_MAX+1)
	struct CachedVoxelDefinition
	{
		const AtlasSegmentCache *textures[6] = {NULL};
		ss_ handler_module;
	};

	struct VoxelRegistry
	{
		virtual ~VoxelRegistry(){}

		virtual VoxelTypeId add_voxel(const VoxelDefinition &def) = 0;

		virtual const VoxelDefinition* get(const VoxelTypeId &id) = 0;
		virtual const VoxelDefinition* get(const VoxelName &name) = 0;
		virtual const CachedVoxelDefinition* get_cached(const VoxelTypeId &id) = 0;

		// TODO: Network serialization
		// TODO: Ability to track changes (just some kind of set_dirty()?)
	};

	VoxelRegistry* createVoxelRegistry(TextureAtlasRegistry *atlas_reg);

	struct VoxelInstance
	{
		uint32_t data;

		VoxelTypeId getId(){return data & 0x001fffff; }
		uint8_t getMSB(){return (data>>24) & 0xff; }
	};
}
// vim: set noet ts=4 sw=4:
