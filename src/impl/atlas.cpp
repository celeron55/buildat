// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/atlas.h"
#include "core/log.h"
#include <Context.h>
#include <ResourceCache.h>
#include <Texture2D.h>
#include <Graphics.h>
#include <Image.h>
#define MODULE "atlas"

namespace interface {

bool AtlasSegmentDefinition::operator==(const AtlasSegmentDefinition &other) const
{
	return (
			resource_name == other.resource_name &&
			total_segments == other.total_segments &&
			select_segment == other.select_segment &&
			lod_simulation == other.lod_simulation
	);
}

struct CTextureAtlasRegistry: public TextureAtlasRegistry
{
	magic::Context *m_context;
	sv_<TextureAtlasDefinition> m_defs;
	sv_<TextureAtlasCache> m_cache;

	CTextureAtlasRegistry(magic::Context *context):
		m_context(context)
	{
		m_defs.resize(1); // id=0 is ATLAS_UNDEFINED
	}

	const AtlasSegmentReference add_segment(
			const AtlasSegmentDefinition &segment_def)
	{
		// Get Texture2D resource
		magic::ResourceCache *magic_cache =
				m_context->GetSubsystem<magic::ResourceCache>();
		magic::Image *seg_img = magic_cache->GetResource<magic::Image>(
				segment_def.resource_name.c_str());
		if(seg_img == nullptr)
			throw Exception("CTextureAtlasRegistry::add_segment(): Couldn't "
						  "find image \""+segment_def.resource_name+"\" when adding "
						  "segment");
		// Get resolution of texture
		magic::IntVector2 seg_img_size(seg_img->GetWidth(), seg_img->GetHeight());
		// Try to find a texture atlas for this texture size
		TextureAtlasDefinition *atlas_def = nullptr;
		for(TextureAtlasDefinition &def0 : m_defs){
			if(def0.id == ATLAS_UNDEFINED)
				continue;
			if(def0.segment_resolution == seg_img_size){
				size_t max = def0.total_segments.x_ * def0.total_segments.y_;
				if(def0.segments.size() >= max)
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
			magic::IntVector2 seg_res(
					seg_img_size.x_ / segment_def.total_segments.x_,
					seg_img_size.y_ / segment_def.total_segments.y_
			);
			atlas_def->segment_resolution = seg_res;
			// Calculate total segments based on segment resolution
			const int max_res = 2048;
			atlas_def->total_segments = magic::IntVector2(
					max_res / seg_res.x_ / 2,
					max_res / seg_res.y_ / 2
			);
			magic::IntVector2 atlas_resolution(
					atlas_def->total_segments.x_ * seg_res.x_ * 2,
					atlas_def->total_segments.y_ * seg_res.y_ * 2
			);
			// Create image for new atlas
			magic::Image *atlas_img = new magic::Image(m_context);
			atlas_img->SetSize(atlas_resolution.x_, atlas_resolution.y_, 4);
			// Create texture for new atlas
			magic::Texture2D *atlas_tex = new magic::Texture2D(m_context);
			// TODO: Make this configurable
			atlas_tex->SetFilterMode(magic::FILTER_NEAREST);
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

	const AtlasSegmentReference find_or_add_segment(
			const AtlasSegmentDefinition &segment_def)
	{
		// Find an atlas that contains this segment; return reference if found
		for(auto &atlas_def : m_defs){
			for(uint seg_id = 0; seg_id<atlas_def.segments.size(); seg_id++){
				auto &segment_def0 = atlas_def.segments[seg_id];
				if(segment_def0 == segment_def){
					AtlasSegmentReference ref;
					ref.atlas_id = atlas_def.id;
					ref.segment_id = seg_id;
					return ref;
				}
			}
		}
		// Segment was not found; add a new one
		return add_segment(segment_def);
	}

	const TextureAtlasDefinition* get_atlas_definition(uint atlas_id)
	{
		if(atlas_id == ATLAS_UNDEFINED)
			return nullptr;
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
		magic::IntVector2 total_segs = atlas.total_segments;
		uint seg_iy = seg_id / total_segs.x_;
		uint seg_ix = seg_id - seg_iy;
		magic::IntVector2 seg_size = atlas.segment_resolution;
		magic::IntVector2 dst_p00(
				seg_ix * seg_size.x_ * 2,
				seg_iy * seg_size.y_ * 2
		);
		magic::IntVector2 dst_p0 = dst_p00 + seg_size / 2;
		magic::IntVector2 dst_p1 = dst_p0 + seg_size;
		// Set coordinates in cache
		cache.coord0 = magic::Vector2(
				(float)dst_p0.x_ / (float)(total_segs.x_ * seg_size.x_ * 2),
				(float)dst_p0.y_ / (float)(total_segs.y_ * seg_size.y_ * 2)
		);
		cache.coord1 = magic::Vector2(
				(float)dst_p1.x_ / (float)(total_segs.x_ * seg_size.x_ * 2),
				(float)dst_p1.y_ / (float)(total_segs.y_ * seg_size.y_ * 2)
		);
		// Draw segment into atlas image
		magic::IntVector2 seg_img_size(seg_img->GetWidth(), seg_img->GetHeight());
		magic::IntVector2 src_off(
				seg_img_size.x_ / def.total_segments.x_ * def.select_segment.x_,
				seg_img_size.y_ / def.total_segments.y_ * def.select_segment.y_
		);
		// Draw main texture
		if(def.lod_simulation == 0){
			for(int y = 0; y<seg_size.y_ * 2; y++){
				for(int x = 0; x<seg_size.x_ * 2; x++){
					magic::IntVector2 src_p = src_off + magic::IntVector2(
							(x + seg_size.x_ / 2) % seg_size.x_,
							(y + seg_size.y_ / 2) % seg_size.y_
					);
					magic::IntVector2 dst_p = dst_p00 + magic::IntVector2(x, y);
					magic::Color c = seg_img->GetPixel(src_p.x_, src_p.y_);
					atlas.image->SetPixel(dst_p.x_, dst_p.y_, c);
				}
			}
		} else {
			int lod = def.lod_simulation & 0x0f;
			uint8_t flags = def.lod_simulation & 0xf0;
			for(int y = 0; y<seg_size.y_ * 2; y++){
				for(int x = 0; x<seg_size.x_ * 2; x++){
					if(flags & ATLAS_LOD_TOP_FACE){
						// Preserve original colors
						magic::IntVector2 src_p = src_off + magic::IntVector2(
								((x + seg_size.x_ / 2) * lod) % seg_size.x_,
								((y + seg_size.y_ / 2) * lod) % seg_size.y_
						);
						magic::IntVector2 dst_p = dst_p00 + magic::IntVector2(x, y);
						magic::Color c = seg_img->GetPixel(src_p.x_, src_p.y_);
						if(flags & ATLAS_LOD_BAKE_SHADOWS){
							c.r_ *= 0.8f;
							c.g_ *= 0.8f;
							c.b_ *= 0.8f;
						} else {
							c.r_ *= 1.0f;
							c.g_ *= 1.0f;
							c.b_ *= 0.875f;
						}
						atlas.image->SetPixel(dst_p.x_, dst_p.y_, c);
					} else {
						// Simulate sides
						magic::IntVector2 src_p = src_off + magic::IntVector2(
								((x + seg_size.x_ / 2) * lod) % seg_size.x_,
								((y + seg_size.y_ / 2) * lod) % seg_size.y_
						);
						magic::IntVector2 dst_p = dst_p00 + magic::IntVector2(x, y);
						magic::Color c = seg_img->GetPixel(src_p.x_, src_p.y_);
						// Leave horizontal edges look like they are bright
						// topsides
						// TODO: This should be variable according to the
						// camera's height relative to the thing the atlas
						// segment is representing
						int edge_size = lod * seg_size.y_ / 16;
						bool is_edge = (
								src_p.y_ <= edge_size ||
								src_p.y_ >= seg_size.y_ - edge_size
						);
						if(flags & ATLAS_LOD_BAKE_SHADOWS){
							if(is_edge){
								if(flags & ATLAS_LOD_SEMIBRIGHT1_FACE){
									c.r_ *= 0.75f;
									c.g_ *= 0.75f;
									c.b_ *= 0.8f;
								} else if(flags & ATLAS_LOD_SEMIBRIGHT2_FACE){
									c.r_ *= 0.75f;
									c.g_ *= 0.75f;
									c.b_ *= 0.8f;
								} else {
									c.r_ *= 0.8f * 0.49f;
									c.g_ *= 0.8f * 0.49f;
									c.b_ *= 0.8f * 0.52f;
								}
							} else {
								if(flags & ATLAS_LOD_SEMIBRIGHT1_FACE){
									c.r_ *= 0.70f * 0.75f;
									c.g_ *= 0.70f * 0.75f;
									c.b_ *= 0.65f * 0.8f;
								} else if(flags & ATLAS_LOD_SEMIBRIGHT2_FACE){
									c.r_ *= 0.50f * 0.75f;
									c.g_ *= 0.50f * 0.75f;
									c.b_ *= 0.50f * 0.8f;
								} else {
									c.r_ *= 0.5f * 0.15f;
									c.g_ *= 0.5f * 0.15f;
									c.b_ *= 0.5f * 0.16f;
								}
							}
						} else {
							if(is_edge){
								c.r_ *= 1.0f;
								c.g_ *= 1.0f;
								c.b_ *= 0.875f;
							} else {
								if(flags & ATLAS_LOD_SEMIBRIGHT1_FACE){
									c.r_ *= 0.70f;
									c.g_ *= 0.70f;
									c.b_ *= 0.65f;
								} else if(flags & ATLAS_LOD_SEMIBRIGHT2_FACE){
									c.r_ *= 0.50f;
									c.g_ *= 0.50f;
									c.b_ *= 0.50f;
								} else {
									c.r_ *= 0.5f;
									c.g_ *= 0.5f;
									c.b_ *= 0.5f;
								}
							}
						}
						atlas.image->SetPixel(dst_p.x_, dst_p.y_, c);
					}
				}
			}
		}
		// Update atlas texture from atlas image
		atlas.texture->SetData(atlas.image);

		// Debug: save atlas image to file
		/*ss_ atlas_img_name = "/tmp/atlas_"+itos(seg_size.x_)+"x"+
		        itos(seg_size.y_)+".png";
		magic::File f(m_context, atlas_img_name.c_str(), magic::FILE_WRITE);
		atlas.image->Save(f);*/
	}

	const TextureAtlasCache* get_atlas_cache(uint atlas_id)
	{
		if(atlas_id == ATLAS_UNDEFINED)
			return nullptr;
		if(atlas_id >= m_cache.size()){
			// Cache is always up-to-date
			return nullptr;
		}
		return &m_cache[atlas_id];
	}

	const AtlasSegmentCache* get_texture(const AtlasSegmentReference &ref)
	{
		const TextureAtlasCache *cache = get_atlas_cache(ref.atlas_id);
		if(cache == nullptr)
			return nullptr;
		if(ref.segment_id >= cache->segments.size()){
			// Cache is always up-to-date
			return nullptr;
		}
		const AtlasSegmentCache &seg_cache = cache->segments[ref.segment_id];
		return &seg_cache;
	}

	void update()
	{
		// Re-create textures if a device reset has destroyed them
		for(uint atlas_id = ATLAS_UNDEFINED + 1;
				atlas_id < m_cache.size(); atlas_id++){
			TextureAtlasCache &cache = m_cache[atlas_id];
			if(cache.texture->IsDataLost()){
				log_v(MODULE, "Atlas %i texture data lost - re-creating",
						atlas_id);
				cache.texture->SetData(cache.image);
				cache.texture->ClearDataLost();
			}
		}
	}
};

TextureAtlasRegistry* createTextureAtlasRegistry(magic::Context *context)
{
	return new CTextureAtlasRegistry(context);
}

}
// vim: set noet ts=4 sw=4:
