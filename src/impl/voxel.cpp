// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel.h"
#include "core/log.h"
#define MODULE "voxel"

namespace std {
template<> struct hash<interface::VoxelName>{
	std::size_t operator()(const interface::VoxelName &v) const {
		return ((std::hash<ss_>() (v.block_name) << 0) ^
				   (std::hash<uint>() (v.segment_x) << 1) ^
				   (std::hash<uint>() (v.segment_y) << 2) ^
				   (std::hash<uint>() (v.segment_z) << 3) ^
				   (std::hash<uint>() (v.rotation_primary) << 4) ^
				   (std::hash<uint>() (v.rotation_secondary) << 5));
	}
};
}

namespace interface {

ss_ VoxelName::dump() const
{
	std::ostringstream os(std::ios::binary);
	os<<"VoxelName(";
	os<<"block_name="<<block_name;
	os<<", segment=("<<segment_x<<","<<segment_y<<","<<segment_z<<")";
	os<<", rotation_primary="<<rotation_primary;
	os<<", rotation_secondary="<<rotation_secondary;
	os<<")";
	return os.str();
}

bool VoxelName::operator==(const VoxelName &other) const
{
	return (
			block_name == other.block_name &&
			segment_x == other.segment_x &&
			segment_y == other.segment_y &&
			segment_z == other.segment_z &&
			rotation_primary == other.rotation_primary &&
			rotation_secondary == other.rotation_secondary
	);
}

struct CVoxelRegistry: public VoxelRegistry
{
	sv_<VoxelDefinition> m_defs;
	sv_<CachedVoxelDefinition> m_cached_defs;
	sm_<VoxelName, VoxelTypeId> m_name_to_id;

	CVoxelRegistry()
	{
		m_defs.resize(1);	// Id 0 is VOXELTYPEID_UNDEFINEDD
	}

	VoxelTypeId add_voxel(const VoxelDefinition &def)
	{
		VoxelTypeId id = m_defs.size();
		// NOTE: This invalidates all previous pointers to cache entries that
		//       were given out
		m_defs.resize(id + 1);
		m_defs[id] = def;
		m_defs[id].id = id;
		m_name_to_id[def.name] = id;
		log_v(MODULE, "CVoxelRegistyr::add_voxel(): Added id=%i name=%s",
				id, cs(def.name.dump()));
		return id;
	}

	const VoxelDefinition* get(const VoxelTypeId &id)
	{
		if(id >= m_defs.size()){
			log_w(MODULE, "CVoxelRegistry::get(): id=%i not found", id);
			return NULL;
		}
		return &m_defs[id];
	}

	const VoxelDefinition* get(const VoxelName &name)
	{
		auto it = m_name_to_id.find(name);
		if(it == m_name_to_id.end()){
			log_w(MODULE, "CVoxelRegistry::get(): name=%s not found",
					cs(name.dump()));
			return NULL;
		}
		VoxelTypeId id = it->second;
		return get(id);
	}

	const CachedVoxelDefinition* get_cached(const VoxelTypeId &id,
			TextureAtlasRegistry *atlas_reg)
	{
		if(id >= m_defs.size()){
			log_w(MODULE, "CVoxelRegistry::get_cached(): id=%i not found", id);
			return NULL;
		}
		if(m_cached_defs.size() < m_defs.size()){
			m_cached_defs.resize(m_defs.size());
		}
		const VoxelDefinition &def = m_defs[id];
		CachedVoxelDefinition &cache = m_cached_defs[id];
		if(!cache.valid){
			update_cache_basic(cache, def);
			cache.valid = true;
		}
		if(!cache.textures_valid && atlas_reg){
			update_cache_textures(cache, def, atlas_reg);
			cache.textures_valid = true;
		}
		return &cache;
	}

	const CachedVoxelDefinition* get_cached(const VoxelInstance &v,
			TextureAtlasRegistry *atlas_reg)
	{
		return get_cached(v.getId(), atlas_reg);
	}

	void update_cache_basic(CachedVoxelDefinition &cache,
			const VoxelDefinition &def)
	{
		log_d(MODULE, "CVoxelRegistry::update_cache_basic(): id=%i", def.id);
		cache.handler_module = def.handler_module;
		cache.face_draw_type = def.face_draw_type;
		cache.edge_material_id = def.edge_material_id;
		cache.physically_solid = def.physically_solid;
		// Caller sets cache.valid = true
	}

	void update_cache_textures(CachedVoxelDefinition &cache,
			const VoxelDefinition &def, TextureAtlasRegistry *atlas_reg)
	{
		log_d(MODULE, "CVoxelRegistry::update_cache_textures(): id=%i", def.id);
		for(size_t i = 0; i<6; i++){
			const AtlasSegmentDefinition &seg_def = def.textures[i];
			if(seg_def.resource_name == ""){
				AtlasSegmentReference seg_ref;	// Use default values
				cache.textures[i] = seg_ref;
			} else {
				AtlasSegmentReference seg_ref =
						atlas_reg->find_or_add_segment(seg_def);
				cache.textures[i] = seg_ref;
			}
		}
		// Caller sets cache.textures_valid = true
	}

	// TODO: Network serialization
	// TODO: Ability to track changes (just some kind of set_dirty()?)
};

VoxelRegistry* createVoxelRegistry()
{
	return new CVoxelRegistry();
}

}
// vim: set noet ts=4 sw=4:
