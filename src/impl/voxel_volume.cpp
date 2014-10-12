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
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)2); // Format
		ar((int32_t)volume.getWidth());
		ar((int32_t)volume.getHeight());
		ar((int32_t)volume.getDepth());
		auto region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		size_t size = volume.getWidth() * volume.getHeight() * volume.getDepth();
		for(size_t i=0; i<size; i++){
			const VoxelInstance &v = volume.m_pData[i];
			ar((uint32_t)v.data);
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
	std::istringstream is(data, std::ios::binary);
	cereal::PortableBinaryInputArchive ar(is);
	int8_t format = 0;
	ar(format);
	if(format == 2){
		int32_t w = 0;
		int32_t h = 0;
		int32_t d = 0;
		ar(w, h, d);
		pv::Region region(0, 0, 0, w-1, h-1, d-1);
		up_<pv::RawVolume<VoxelInstance>> volume(
				new pv::RawVolume<VoxelInstance>(region));
		size_t size = volume->getWidth() * volume->getHeight() * volume->getDepth();
		for(size_t i=0; i<size; i++){
			uint32_t v;
			ar(v);
			volume->m_pData[i].data = v;
		}
		return volume;
	}
	log_w(MODULE, "deserialize_volume(): Unknown format %i", format);
	return up_<pv::RawVolume<VoxelInstance>>();;
}

}
// vim: set noet ts=4 sw=4:
