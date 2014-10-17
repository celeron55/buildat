// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel_volume.h"
#include "interface/compress.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
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
		for(size_t i = 0; i<volume.m_dataSize; i++){
			const VoxelInstance &v = volume.m_pData[i];
			ar((uint32_t)v.data);
		}
	}
	return os.str();
}

ss_ serialize_volume_compressed(const pv::RawVolume<VoxelInstance> &volume)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)3); // Format
		ar((int32_t)volume.getWidth());
		ar((int32_t)volume.getHeight());
		ar((int32_t)volume.getDepth());
		std::ostringstream raw_os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(raw_os);
			auto region = volume.getEnclosingRegion();
			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();
			for(size_t i = 0; i<volume.m_dataSize; i++){
				const VoxelInstance &v = volume.m_pData[i];
				ar((uint32_t)v.data);
			}
		}
		std::ostringstream compressed_os(std::ios::binary);
		// NOTE: 4 uses 98% and 1 uses 58% of the CPU time of 6
		interface::compress_zlib(raw_os.str(), compressed_os, 6);
		ar(compressed_os.str());
	}
	return os.str();
}

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
		for(size_t i = 0; i<volume->m_dataSize; i++){
			uint32_t v;
			ar(v);
			volume->m_pData[i].data = v;
		}
		return volume;
	}
	if(format == 3){
		int32_t w = 0;
		int32_t h = 0;
		int32_t d = 0;
		ar(w, h, d);
		pv::Region region(0, 0, 0, w-1, h-1, d-1);
		up_<pv::RawVolume<VoxelInstance>> volume(
				new pv::RawVolume<VoxelInstance>(region));
		ss_ compressed_data;
		ar(compressed_data);
		std::istringstream compressed_is(compressed_data, std::ios::binary);
		std::ostringstream raw_os(std::ios::binary);
		decompress_zlib(compressed_is, raw_os);
		{
			std::istringstream raw_is(raw_os.str(), std::ios::binary);
			cereal::PortableBinaryInputArchive ar(raw_is);
			for(size_t i = 0; i<volume->m_dataSize; i++){
				uint32_t v;
				ar(v);
				volume->m_pData[i].data = v;
			}
		}
		return volume;
	}
	return up_<pv::RawVolume<VoxelInstance>>();
}

}
// vim: set noet ts=4 sw=4:
