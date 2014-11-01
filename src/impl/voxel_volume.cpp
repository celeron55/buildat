// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel_volume.h"
#include "interface/compress.h"
#include "interface/polyvox_cereal.h"
#include "interface/voxel_cereal.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#define MODULE "voxel_volume"

namespace interface {

// pv::RawVolume<T>

template<typename T>
		ss_ generic_serialize_volume_simple(const pv::RawVolume<T> &volume)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)2); // Format
		auto region = volume.getEnclosingRegion();
		ar(region.getLowerCorner());
		ar(region.getUpperCorner());
		for(size_t i = 0; i<volume.m_dataSize; i++){
			const T &v = volume.m_pData[i];
			ar(v);
		}
	}
	return os.str();
}

template<typename T>
		ss_ generic_serialize_volume_compressed(const pv::RawVolume<T> &volume)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)3); // Format
		auto region = volume.getEnclosingRegion();
		ar(region.getLowerCorner());
		ar(region.getUpperCorner());
		std::ostringstream raw_os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(raw_os);
			for(size_t i = 0; i<volume.m_dataSize; i++){
				const T &v = volume.m_pData[i];
				ar(v);
			}
		}
		std::ostringstream compressed_os(std::ios::binary);
		// NOTE: 4 uses 98% and 1 uses 58% of the CPU time of 6
		interface::compress_zlib(raw_os.str(), compressed_os, 6);
		ar(compressed_os.str());
	}
	return os.str();
}

template<typename T>
		up_<pv::RawVolume<T>> generic_deserialize_volume(const ss_ &data)
{
	std::istringstream is(data, std::ios::binary);
	cereal::PortableBinaryInputArchive ar(is);
	uint8_t format = 0;
	ar(format);
	if(format == 2){
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		pv::Region region(lc, uc);
		up_<pv::RawVolume<T>> volume(
				new pv::RawVolume<T>(region));
		for(size_t i = 0; i<volume->m_dataSize; i++){
			T v;
			ar(v);
			volume->m_pData[i] = v;
		}
		return volume;
	}
	if(format == 3){
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		pv::Region region(lc, uc);
		up_<pv::RawVolume<T>> volume(
				new pv::RawVolume<T>(region));
		ss_ compressed_data;
		ar(compressed_data);
		std::istringstream compressed_is(compressed_data, std::ios::binary);
		std::ostringstream raw_os(std::ios::binary);
		decompress_zlib(compressed_is, raw_os);
		{
			std::istringstream raw_is(raw_os.str(), std::ios::binary);
			cereal::PortableBinaryInputArchive ar(raw_is);
			for(size_t i = 0; i<volume->m_dataSize; i++){
				T v;
				ar(v);
				volume->m_pData[i] = v;
			}
		}
		return volume;
	}
	return up_<pv::RawVolume<T>>();
}

// pv::RawVolume<VoxelInstance>

ss_ serialize_volume_simple(const pv::RawVolume<VoxelInstance> &volume)
{
	return generic_serialize_volume_simple(volume);
}

ss_ serialize_volume_compressed(const pv::RawVolume<VoxelInstance> &volume)
{
	return generic_serialize_volume_compressed(volume);
}

up_<pv::RawVolume<VoxelInstance>> deserialize_volume(const ss_ &data)
{
	return generic_deserialize_volume<VoxelInstance>(data);
}

// pv::RawVolume<int32_t>

ss_ serialize_volume_simple(const pv::RawVolume<int32_t> &volume)
{
	return generic_serialize_volume_simple(volume);
}

ss_ serialize_volume_compressed(const pv::RawVolume<int32_t> &volume)
{
	return generic_serialize_volume_compressed(volume);
}

up_<pv::RawVolume<int32_t>> deserialize_volume_int32(const ss_ &data)
{
	return generic_deserialize_volume<int32_t>(data);
}

// pv::RawVolume<uint8_t>

ss_ serialize_volume_simple(const pv::RawVolume<uint8_t> &volume)
{
	return generic_serialize_volume_simple(volume);
}

ss_ serialize_volume_compressed(const pv::RawVolume<uint8_t> &volume)
{
	return generic_serialize_volume_compressed(volume);
}

up_<pv::RawVolume<uint8_t>> deserialize_volume_8bit(const ss_ &data)
{
	return generic_deserialize_volume<uint8_t>(data);
}

}
// vim: set noet ts=4 sw=4:
