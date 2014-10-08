// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <PolyVoxCore/Vector.h>
#include "interface/voxel.h"

namespace interface
{
	namespace pv = PolyVox;

	typedef ss_ BlockName;
	typedef uint32_t BlockTypeId;
	static constexpr uint32_t BLOCKTYPEID_UNDEFINED = 0;

	struct BlockDefinition
	{
		BlockName name;
		BlockTypeId id = BLOCKTYPEID_UNDEFINED;
		uint8_t num_rotations = 0;	// Supported: 0, 4, 24
		pv::Vector3DUint8 size = pv::Vector3DUint8(0, 0, 0);// Size in voxels
		sv_<VoxelTypeId> segments;	// Rotations*voxels
	};

	// Voxels and a BlockDefinition can be generated based on this
	struct BlockSourceDefinition
	{
		BlockName name;
		uint8_t num_rotations = 0;	// Supported: 0, 4, 24
		pv::Vector3DUint8 size = pv::Vector3DUint8(0, 0, 0);// Size in voxels
		// Definitions for creating voxels
		sv_<ss_> side_textures;	// 6 resource names
		ss_ handler_module;
	};

	struct BlockRegistry
	{
		virtual ~BlockRegistry(){}

		// Add block for which voxels already exists
		virtual BlockTypeId add_block_with_predefined_segments(
				const BlockDefinition &def) = 0;
		// Add block and generate voxels for it
		virtual BlockTypeId add_block_generate_segments(
				const BlockSourceDefinition &def) = 0;

		virtual const BlockDefinition* get(const BlockTypeId &id) = 0;
		virtual const BlockDefinition* get(const BlockName &name) = 0;

		// TODO: Network serialization
		// TODO: Ability to track changes (just some kind of set_dirty()?)
	};

	BlockRegistry* createBlockRegistry(VoxelRegistry *voxel_reg);
}
// vim: set noet ts=4 sw=4:
