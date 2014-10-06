// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/block.h"

namespace interface {

struct CBlockRegistry: public BlockRegistry
{
	VoxelRegistry *m_voxel_reg;
	sv_<BlockDefinition> m_defs;

	CBlockRegistry(VoxelRegistry *voxel_reg):
		m_voxel_reg(voxel_reg)
	{}

	BlockTypeId add_block_with_predefined_segments(const BlockDefinition &def)
	{
		throw Exception("Not implemented");
		return BLOCKTYPEID_UNDEFINED;
	}

	BlockTypeId add_block_generate_segments(const BlockSourceDefinition &def)
	{
		throw Exception("Not implemented");
		return BLOCKTYPEID_UNDEFINED;
	}

	const BlockDefinition* get(const BlockTypeId &id)
	{
		return NULL;
	}

	const BlockDefinition* get(const BlockName &name)
	{
		return NULL;
	}

	// TODO: Network serialization
	// TODO: Ability to track changes (just some kind of set_dirty()?)
};

BlockRegistry* createBlockRegistry(VoxelRegistry *voxel_reg)
{
	return new CBlockRegistry(voxel_reg);
}

}
// vim: set noet ts=4 sw=4:
