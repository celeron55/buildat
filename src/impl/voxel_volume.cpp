// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel_volume.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#define MODULE "voxel_volume"

namespace interface {

ss_ serialize_volume_simple(const pv::RawVolume<VoxelInstance> &volume)
{
	std::ostringstream os(std::ios::binary);
	os<<(uint8_t)2; // Format
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((int32_t)volume.getWidth());
		ar((int32_t)volume.getHeight());
		ar((int32_t)volume.getDepth());
		auto region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					ar((uint32_t)volume.getVoxelAt(x, y, z).data);
				}
			}
		}
	}
	return os.str();
};

ss_ serialize_volume_compressed(const pv::RawVolume<VoxelInstance> &volume)
{
	std::ostringstream os(std::ios::binary);
	os<<(uint8_t)3; // Format
	// TODO
	log_w(MODULE, "serialize_volume_compressed: Not implemented");
	return os.str();
};

up_<pv::RawVolume<VoxelInstance>> deserialize_volume(const ss_ &data)
{
	// TODO
	log_w(MODULE, "deserialize_volume: Not implemented");
	int w = 0;
	int h = 0;
	int d = 0;
	pv::Region region(0, 0, 0, w-1, h-1, d-1);
	up_<pv::RawVolume<VoxelInstance>> result(
			new pv::RawVolume<VoxelInstance>(region));
	return result;
}

}
// vim: set noet ts=4 sw=4:
