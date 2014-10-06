// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/atlas.h"
#include <Context.h>
#include <ResourceCache.h>
#include <Texture2D.h>

namespace interface {

struct CTextureAtlasRegistry: public TextureAtlasRegistry
{
	magic::Context *m_context;
	sv_<TextureAtlasDefinition> m_defs;
	sv_<TextureAtlasCache> m_cache;

	CTextureAtlasRegistry(magic::Context *context):
		m_context(context)
	{}

	const AtlasSegmentReference add_segment(
			const AtlasSegmentDefinition &segment_def)
	{
		throw Exception("Not implemented");
		// Get Texture2D resource
		magic::ResourceCache *magic_cache =
				m_context->GetSubsystem<magic::ResourceCache>();
		magic::Texture2D *texture = magic_cache->GetResource<magic::Texture2D>(
				segment_def.resource_name);
		// Get resolution of texture
		magic::IntVector2 texture_size(texture->GetWidth(), texture->GetHeight());
		// Try to find a texture atlas for this texture size
		TextureAtlasDefinition *atlas_def = NULL;
		for(TextureAtlasDefinition &def0 : m_defs){
			if(def0.segment_resolution == texture_size){
				size_t max = def0.total_segments.x_ * def0.total_segments.y_;
				if(atlas_def->segments.size() >= max)
					continue; // Full
				atlas_def = &def0;
				break;
			}
		}
		// If not found, create a texture atlas for this texture size
		if(!atlas_def){
			// Create a new texture atlas
			m_defs.resize(m_defs.size()+1);
			atlas_def = &m_defs[m_defs.size()-1];
			atlas_def->id = m_defs.size()-1;
			// Calculate segment resolution
			atlas_def->segment_resolution = magic::IntVector2(
					texture_size.x_ / segment_def.total_segments.x_,
					texture_size.y_ / segment_def.total_segments.y_
			);
			// Calculate total segments based on segment resolution
			int max_res = 2048;
			atlas_def->total_segments = magic::IntVector2(
					max_res / atlas_def->segment_resolution.x_,
					max_res / atlas_def->segment_resolution.y_,
			);
			// Create texture for new atlas
			// TODO: Extend cache to fit this atlas if it doesn't yet
			// TODO: Set texture of cached atlas
		}
		// TODO: Add this definition to the atlas
	}

	const TextureAtlasDefinition* get_atlas_definition(uint atlas_id)
	{
		if(atlas_id >= m_defs.size())
			return NULL;
		return &m_defs[atlas_id];
	}

	const AtlasSegmentDefinition* get_segment_definition(
			const AtlasSegmentReference &ref)
	{
		const TextureAtlasDefinition *atlas = get_atlas_definition(ref.atlas_id);
		if(!atlas)
			return NULL;
		if(ref.segment_id >= atlas->segments.size())
			return NULL;
		return &atlas->segments[ref.segment_id];
	}

	void update_segment_cache(AtlasSegmentCache &cache,
			const AtlasSegmentDefinition &def, const TextureAtlasDefinition &atlas)
	{
		// TODO
		// TODO: Get Texture2D resource
		// TODO: Check that resolution of texture matches with atlas
		// TODO: 
	}

	const AtlasSegmentCache* get_texture(const AtlasSegmentReference &ref)
	{
		if(ref.atlas_id >= m_cache.size()){
			if(ref.atlas_id >= m_defs.size())
				return NULL;
			// New atlases are left with valid=false
			m_cache.resize(m_defs.size());
		}
		TextureAtlasCache &cache = m_cache[ref.atlas_id];
		if(!cache.valid){
			const auto &id = ref.atlas_id;
			cache.segment_resolution = m_defs[id].segment_resolution;
			cache.total_segments     = m_defs[id].total_segments;
			// New segments are left with valid=false
			cache.segments.resize(m_defs[id].segments.size());
			cache.valid = true;
		}
		if(ref.segment_id >= cache.segments.size())
			return NULL;
		AtlasSegmentCache &seg_cache = cache.segments[ref.segment_id];
		if(seg_cache.valid)
			return &seg_cache;
		TextureAtlasDefinition &atlas_def = m_defs[ref.atlas_id];
		const AtlasSegmentDefinition &seg_def = atlas_def.segments[ref.segment_id];
		update_segment_cache(seg_cache, seg_def, atlas_def);
		seg_cache.valid = true;
		return &seg_cache;
	}
};

TextureAtlasRegistry* createTextureAtlasRegistry(magic::Context *context)
{
	return new CTextureAtlasRegistry(context);
}

}
// vim: set noet ts=4 sw=4:
