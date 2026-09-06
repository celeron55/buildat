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

		// How the surface responds to light. There are no authored normal or
		// roughness maps; the atlas derives both from this segment's image and
		// these three numbers, so a material is described by what it is rather
		// than by extra files. See impl/atlas.cpp.
		//   roughness  the segment's mean perceptual roughness. Texels brighter
		//              than the segment's mean come out smoother than this and
		//              darker ones rougher, which is what gives leaves their
		//              mix of waxy and matte and leaves flat surfaces flat.
		//   metalness  constant over the segment.
		//   bumpiness  how much the image's luminance is taken to be height
		//              when deriving the normal map. 0 is a flat surface.
		//   gloss_spots  fraction of the segment's texels, the brightest ones,
		//              that come out glossy instead of following the rule
		//              above. For a surface that is mostly matte with a few
		//              parts catching the light, like a canopy of leaves of
		//              which a few happen to face the right way. 0 is off.
		//   translucency  how much light passes through the surface from
		//              behind, tinting itself with the surface's own color on
		//              the way. This is what makes a backlit leaf glow.
		float roughness = 0.9f;
		float metalness = 0.0f;
		float bumpiness = 1.0f;
		float gloss_spots = 0.0f;
		float translucency = 0.0f;

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
		// normal is a tangent space normal map, spec is roughness in r and
		// metalness in g (what Urho's PBR shaders read from sSpecMap) and
		// translucency in b (which only PBRVoxel reads).
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
