// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/atlas.h"
#include <Context.h>
#include <ResourceCache.h>
#include <Texture2D.h>
#include <Graphics.h>
#include <Image.h>

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
		// Get Texture2D resource
		magic::ResourceCache *magic_cache =
				m_context->GetSubsystem<magic::ResourceCache>();
		magic::Image *seg_img = magic_cache->GetResource<magic::Image>(
				segment_def.resource_name.c_str());
		if(seg_img == nullptr)
			throw Exception("Couldn't find image: "+segment_def.resource_name);
		// Get resolution of texture
		magic::IntVector2 seg_img_size(seg_img->GetWidth(), seg_img->GetHeight());
		// Try to find a texture atlas for this texture size
		TextureAtlasDefinition *atlas_def = nullptr;
		for(TextureAtlasDefinition &def0 : m_defs){
			if(def0.segment_resolution == seg_img_size){
				size_t max = def0.total_segments.x_ * def0.total_segments.y_;
				if(atlas_def->segments.size() >= max)
					continue;	// Full
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
					seg_img_size.x_ / segment_def.total_segments.x_,
					seg_img_size.y_ / segment_def.total_segments.y_
			);
			// Calculate total segments based on segment resolution
			const int max_res = 2048;
			atlas_def->total_segments = magic::IntVector2(
					max_res / atlas_def->segment_resolution.x_,
					max_res / atlas_def->segment_resolution.y_
			);
			magic::IntVector2 atlas_resolution(
					atlas_def->total_segments.x_ * atlas_def->segment_resolution.x_,
					atlas_def->total_segments.y_ * atlas_def->segment_resolution.y_
			);
			// Create image for new atlas
			magic::Image *atlas_img = new magic::Image(m_context);
			atlas_img->SetSize(atlas_resolution.x_, atlas_resolution.y_, 4);
			// Create texture for new atlas
			magic::Texture2D *atlas_tex = new magic::Texture2D(m_context);
			// TODO: Use TEXTURE_STATIC or TEXTURE_DYNAMIC?
			atlas_tex->SetSize(atlas_resolution.x_, atlas_resolution.y_,
					magic::Graphics::GetRGBAFormat(), magic::TEXTURE_STATIC);
			// Add new atlas to cache
			const auto &id = atlas_def->id;
			m_cache.resize(id+1);
			TextureAtlasCache *cache = &m_cache[id];
			cache->image = atlas_img;
			cache->texture = atlas_tex;
			cache->segment_resolution = atlas_def->segment_resolution;
			cache->total_segments = atlas_def->total_segments;
		}
		// Add this segment to the atlas definition
		uint seg_id = atlas_def->segments.size();
		atlas_def->segments.resize(seg_id + 1);
		atlas_def->segments[seg_id] = segment_def;
		// Update this segment in cache
		TextureAtlasCache &atlas_cache = m_cache[atlas_def->id];
		atlas_cache.segments.resize(seg_id + 1);
		AtlasSegmentCache &seg_cache = atlas_cache.segments[seg_id];
		update_segment_cache(seg_id, seg_img, seg_cache, segment_def, atlas_cache);
		// Return reference to new segment
		AtlasSegmentReference ref;
		ref.atlas_id = atlas_def->id;
		ref.segment_id = seg_id;
		return ref;
	}

	const TextureAtlasDefinition* get_atlas_definition(uint atlas_id)
	{
		if(atlas_id >= m_defs.size())
			return nullptr;
		return &m_defs[atlas_id];
	}

	const AtlasSegmentDefinition* get_segment_definition(
			const AtlasSegmentReference &ref)
	{
		const TextureAtlasDefinition *atlas = get_atlas_definition(ref.atlas_id);
		if(!atlas)
			return nullptr;
		if(ref.segment_id >= atlas->segments.size())
			return nullptr;
		return &atlas->segments[ref.segment_id];
	}

	void update_segment_cache(uint seg_id, magic::Image *seg_img,
			AtlasSegmentCache &cache, const AtlasSegmentDefinition &def,
			const TextureAtlasCache &atlas)
	{
		// Check if atlas is full
		size_t max_segments = atlas.total_segments.x_ * atlas.total_segments.y_;
		if(atlas.segments.size() >= max_segments)
			throw Exception("Atlas is full");
		// Set segment texture
		cache.texture = atlas.texture;
		// Calculate segment's position in atlas texture
		uint seg_iy = seg_id / atlas.total_segments.x_;
		uint seg_ix = seg_id - seg_iy;
		magic::IntVector2 seg_size = atlas.segment_resolution;
		magic::IntVector2 dst_p0(seg_ix * seg_size.x_, seg_iy * seg_size.y_);
		magic::IntVector2 dst_p1 = dst_p0 + seg_size;
		// Set coordinates in cache
		cache.coord0 = magic::Vector2(
				(float)dst_p0.x_ / (float)(atlas.total_segments.x_ * seg_size.x_),
				(float)dst_p0.y_ / (float)(atlas.total_segments.y_ * seg_size.y_)
		);
		cache.coord0 = magic::Vector2(
				(float)dst_p1.x_ / (float)(atlas.total_segments.x_ * seg_size.x_),
				(float)dst_p1.y_ / (float)(atlas.total_segments.y_ * seg_size.y_)
		);
		// Draw segment into atlas image
		magic::IntVector2 seg_img_size(seg_img->GetWidth(), seg_img->GetHeight());
		magic::IntVector2 src_off(
				seg_img_size.x_ / def.total_segments.x_ * def.select_segment.x_,
				seg_img_size.y_ / def.total_segments.y_ * def.select_segment.y_
		);
		for(int y = 0; y<seg_size.y_; y++){
			for(int x = 0; x<seg_size.x_; x++){
				magic::IntVector2 src_p = src_off + magic::IntVector2(x, y);
				magic::IntVector2 dst_p = dst_p0 + magic::IntVector2(x, y);
				magic::Color c = seg_img->GetPixel(src_p.x_, src_p.y_);
				atlas.image->SetPixel(dst_p.x_, dst_p.y_, c);
			}
		}
		// Update atlas texture from atlas image
		// TODO: Does this require something more?
		atlas.texture->SetData(atlas.image);
	}

	const AtlasSegmentCache* get_texture(const AtlasSegmentReference &ref)
	{
		if(ref.atlas_id >= m_cache.size()){
			// Cache is always up-to-date
			return nullptr;
		}
		TextureAtlasCache &cache = m_cache[ref.atlas_id];
		if(ref.segment_id >= cache.segments.size()){
			// Cache is always up-to-date
			return nullptr;
		}
		AtlasSegmentCache &seg_cache = cache.segments[ref.segment_id];
		return &seg_cache;
	}
};

TextureAtlasRegistry* createTextureAtlasRegistry(magic::Context *context)
{
	return new CTextureAtlasRegistry(context);
}

}
// vim: set noet ts=4 sw=4:
