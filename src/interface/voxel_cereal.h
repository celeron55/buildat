// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include "interface/voxel_selector.h"
#include "interface/atlas_cereal.h"
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>

namespace interface
{
	template<class Archive>
			void serialize(Archive &archive, VoxelName &v)
	{
		uint8_t version = 1;
		archive(
				version,
				v.block_name,
				v.segment_x,
				v.segment_y,
				v.segment_z,
				v.rotation_primary,
				v.rotation_secondary
		);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelQuad &v)
	{
		for(size_t i = 0; i < 4; i++){
			archive(v.p[i][0], v.p[i][1], v.p[i][2]);
			archive(v.uv[i][0], v.uv[i][1]);
		}
		archive(v.tile, v.connect_dir);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelVariant &v)
	{
		uint8_t version = 1;
		archive(version, v.shape, v.color, v.liquid_top);
		for(size_t i = 0; i < 6; i++)
			archive(v.tile_order[i], v.tile_turns[i]);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelDefinition &v)
	{
		uint8_t version = 12;
		archive(
				version,
				v.name,
				v.id,
				v.textures,
				v.handler_module,
				v.face_draw_type,
				v.edge_material_id,
				v.physically_solid,
				v.fully_empty,
				v.shape,
				v.shape_double_sided,
				v.translucent,
				v.shape_group,
				v.is_liquid,
				v.liquid_top,
				v.connect_group,
				v.connect_mask,
				v.connect_to_solid,
				v.shape_masked
		);
		for(size_t i = 0; i < 21; i++)
			archive(v.shape_masked_begin[i]);
		archive(v.variants);
		if(!v.variants.empty()){
			for(size_t i = 0; i < 256; i++)
				archive(v.variant_of_param[i]);
		}
		// Version 9 had no modifier parameters; see the note on VoxelFormat
		// below for why this branch reads as "10 or newer" and writes always
		if(version >= 10){
			archive(v.tint_ramp[0], v.tint_ramp[1], v.sag_extent);
		}
		// Version 11 added the textures a shape's quads can wear beyond the
		// six faces. A count and then that many, so a definition without
		// any pays one byte.
		if(version >= 11){
			archive(v.extra_textures);
		}
		// Version 12 added the flag that says a shape stands in the voxel
		// above its own
		if(version >= 12){
			archive(v.shape_lit_from_above);
		}
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelInstance &v)
	{
		archive(v.data);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelField &v)
	{
		archive(v.plane, v.shift, v.width);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelRuleClause &v)
	{
		archive(v.field, v.lo, v.hi);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelRule &v)
	{
		archive(v.clauses, v.result);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelSelector &v)
	{
		archive(v.kind, v.rules, v.fallback);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelPlane &v)
	{
		archive(v.name, v.bits);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelFormat &v)
	{
		uint8_t version = 3;
		archive(
				version,
				v.planes,
				v.id,
				v.light_sky,
				v.light_lamp,
				v.param,
				v.color
		);
		// Version 1 had no modifier roles and one plane of a fixed width.
		// Version 2 is not read: nothing on either side of a wire or a save
		// carried it for long enough to matter, and the plane list is not a
		// field that can be defaulted. The version is written from this
		// function and read back into it, so this branch is "2 or newer" on
		// the way in and always taken on the way out.
		if(version >= 3){
			archive(
					v.tint,
					v.wetness,
					v.grain,
					v.gloss,
					v.speckle,
					v.emission,
					v.sag_top,
					v.sag_bottom
			);
		}
	}
}
// vim: set noet ts=4 sw=4:
