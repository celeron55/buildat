// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel.h"

namespace interface {

struct CVoxelRegistry: public VoxelRegistry
{
	TextureAtlasRegistry *m_atlas_reg;
	sv_<VoxelDefinition> m_defs;
	sv_<CachedVoxelDefinition> m_cached_defs;

	CVoxelRegistry(TextureAtlasRegistry *atlas_reg):
		m_atlas_reg(atlas_reg)
	{}

	VoxelTypeId add_voxel(const VoxelDefinition &def)
	{
		throw Exception("Not implemented");
		return VOXELTYPEID_UNDEFINED;
	}

	const VoxelDefinition* get(const VoxelTypeId &id)
	{
		return NULL;
	}

	const VoxelDefinition* get(const VoxelName &name)
	{
		return NULL;
	}

	const CachedVoxelDefinition* get_cached(const VoxelTypeId &id)
	{
		return NULL;
	}


	// TODO: Network serialization
	// TODO: Ability to track changes (just some kind of set_dirty()?)
};

VoxelRegistry* createVoxelRegistry(TextureAtlasRegistry *atlas_reg)
{
	return new CVoxelRegistry(atlas_reg);
}

}
// vim: set noet ts=4 sw=4:
