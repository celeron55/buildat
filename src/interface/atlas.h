// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <Vector2.h>
#include <Ptr.h>

namespace Urho3D
{
	class Context;
	class Texture2D;
	class Image;
}

namespace interface
{
	namespace magic = Urho3D;

	static constexpr uint ATLAS_UNDEFINED = 0;

	struct AtlasSegmentReference
	{
		uint atlas_id = ATLAS_UNDEFINED; // 0 = undefined atlas
		uint segment_id = 0;
	};

	// LOD lower than this will have shadow baked into its texture
	const int MAX_LOD_WITH_SHADOWS = 2;

	const uint8_t ATLAS_LOD_TOP_FACE = 0x10;
	const uint8_t ATLAS_LOD_SEMIBRIGHT1_FACE = 0x20;
	const uint8_t ATLAS_LOD_SEMIBRIGHT2_FACE = 0x40;
	const uint8_t ATLAS_LOD_BAKE_SHADOWS = 0x80;

	struct AtlasSegmentDefinition
	{
		ss_ resource_name; // If "", segment won't be added
		magic::IntVector2 total_segments;
		magic::IntVector2 select_segment;
		// Mask 0x0f: LOD level, mask 0xf0: flags
		uint8_t lod_simulation = 0;
		// TODO: Rotation

		// The atlas derives the normal and surface maps from the segment's
		// image and these six numbers; nothing is authored. See impl/atlas.cpp.
		//   roughness      how wide the highlight is. Brighter texels than the
		//                  segment's mean come out a little smoother.
		//   spec_strength  how much of a highlight there is at all, against
		//                  the 0.08 a dielectric reflects head on. Roughness
		//                  only widens a highlight, so this is the only way to
		//                  make a surface matte. Spots ignore it.
		//   bumpiness      how much of the image's luminance is height. Sets
		//                  how grainy a surface looks, diffuse as much as
		//                  specular.
		//   translucency   how much light passes through from behind at a
		//                  spot, tinted by the surface's own color.
		//   spots          fraction of the surface that at any one moment is
		//                  turned off the face it is on, reflects at full
		//                  strength and passes translucency. Worked out in the
		//                  shader from world position and time, not stored.
		//   static_spots   the same, for spots that hold still: bigger, and on
		//                  or off with no fade.
		//
		// Gloss and transmission share one fraction because they are the same
		// event from two sides; the geometry decides which one shows.
		float roughness = 0.9f;
		float spec_strength = 1.0f;
		float bumpiness = 1.0f;
		float translucency = 0.0f;
		float spots = 0.0f;
		float static_spots = 0.0f;

		bool operator==(const AtlasSegmentDefinition &other) const;
	};

	struct AtlasSegmentCache
	{
		magic::Texture2D *texture = nullptr;
		magic::Vector2 coord0;
		magic::Vector2 coord1;
	};

	struct AtlasDefinition
	{
		uint id = ATLAS_UNDEFINED;
		magic::IntVector2 segment_resolution;
		magic::IntVector2 total_segments;
		sv_<AtlasSegmentDefinition> segments;
	};

	struct AtlasCache
	{
		magic::SharedPtr<magic::Image> image;
		magic::SharedPtr<magic::Texture2D> texture;
		// Derived from the segment images; same layout as the diffuse atlas.
		// normal: tangent space normal in rgb, static_spots in a.
		// spec: roughness in r, where Urho's PBR shaders read it from
		// sSpecMap, and spec_strength, translucency and spots in gba, which
		// only PBRVoxel reads.
		magic::SharedPtr<magic::Image> normal_image;
		magic::SharedPtr<magic::Texture2D> normal_texture;
		magic::SharedPtr<magic::Image> spec_image;
		magic::SharedPtr<magic::Texture2D> spec_texture;
		magic::IntVector2 segment_resolution;
		magic::IntVector2 total_segments;
		sv_<AtlasSegmentCache> segments;
	};

	struct AtlasRegistry
	{
		virtual ~AtlasRegistry(){}

		// These two may only be called from Urho3D main thread
		virtual const AtlasSegmentReference add_segment(
				const AtlasSegmentDefinition &segment_def) = 0;
		virtual const AtlasSegmentReference find_or_add_segment(
				const AtlasSegmentDefinition &segment_def) = 0;

		virtual const AtlasDefinition* get_atlas_definition(
				uint atlas_id) = 0;
		virtual const AtlasSegmentDefinition* get_segment_definition(
				const AtlasSegmentReference &ref) = 0;

		virtual const AtlasCache* get_atlas_cache(uint atlas_id) = 0;

		virtual const AtlasSegmentCache* get_texture(
				const AtlasSegmentReference &ref) = 0;

		virtual void update() = 0;
	};

	AtlasRegistry* createAtlasRegistry(magic::Context *context);
}
// vim: set noet ts=4 sw=4:
