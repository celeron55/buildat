// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include "interface/atlas_cereal.h"
#include <cereal/types/string.hpp>

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
	void serialize(Archive &archive, VoxelDefinition &v)
	{
		uint8_t version = 1;
		archive(
				version,
				v.name,
				v.id,
				v.textures,
				v.handler_module,
				v.face_draw_type,
				v.edge_material_id,
				v.physically_solid
		);
	}
}
// vim: set noet ts=4 sw=4:
