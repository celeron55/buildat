// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include <PolyVoxCore/RawVolume.h>

namespace interface
{
	ss_ serialize_volume_simple(const pv::RawVolume<VoxelInstance> &volume);
	ss_ serialize_volume_compressed(const pv::RawVolume<VoxelInstance> &volume);

	up_<pv::RawVolume<VoxelInstance>> deserialize_volume(const ss_ &data);
}
// vim: set noet ts=4 sw=4:
