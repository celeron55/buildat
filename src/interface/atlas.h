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

	struct AtlasSegmentReference
	{
		uint atlas_id = 0;
		uint segment_id = 0;
	};

	struct AtlasSegmentDefinition
	{
		ss_ resource_name;
		magic::IntVector2 total_segments;
		magic::IntVector2 select_segment;
		// TODO: Rotation

		bool operator==(const AtlasSegmentDefinition &other) const;
	};

	struct AtlasSegmentCache
	{
		magic::Texture2D *texture = nullptr;
		magic::Vector2 coord0;
		magic::Vector2 coord1;
	};

	struct TextureAtlasDefinition
	{
		uint id;
		magic::IntVector2 segment_resolution;
		magic::IntVector2 total_segments;
		sv_<AtlasSegmentDefinition> segments;
	};

	struct TextureAtlasCache
	{
		magic::SharedPtr<magic::Image> image;
		magic::Texture2D *texture = nullptr;
		magic::IntVector2 segment_resolution;
		magic::IntVector2 total_segments;
		sv_<AtlasSegmentCache> segments;
	};

	struct TextureAtlasRegistry
	{
		virtual ~TextureAtlasRegistry(){}

		virtual const AtlasSegmentReference add_segment(
				const AtlasSegmentDefinition &segment_def) = 0;
		virtual const AtlasSegmentReference find_or_add_segment(
				const AtlasSegmentDefinition &segment_def) = 0;

		virtual const TextureAtlasDefinition* get_atlas_definition(
				uint atlas_id) = 0;
		virtual const AtlasSegmentDefinition* get_segment_definition(
				const AtlasSegmentReference &ref) = 0;

		virtual const AtlasSegmentCache* get_texture(
				const AtlasSegmentReference &ref) = 0;
	};

	TextureAtlasRegistry* createTextureAtlasRegistry(magic::Context *context);
}
// vim: set noet ts=4 sw=4:
