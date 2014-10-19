// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/atlas.h"
#include "interface/urho3d_cereal.h"
#include <cereal/types/string.hpp>

namespace interface
{
	template<class Archive>
	void serialize(Archive &archive, AtlasSegmentDefinition &v)
	{
		uint8_t version = 1;
		archive(
				version,
				v.resource_name,
				v.total_segments,
				v.select_segment,
				v.lod_simulation
		);
	}
}
// vim: set noet ts=4 sw=4:
