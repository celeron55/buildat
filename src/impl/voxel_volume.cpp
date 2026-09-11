// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel_volume.h"
#include "interface/compress.h"
#include "interface/polyvox_cereal.h"
#include "interface/voxel_cereal.h"
#include "core/log.h"
#include <cstring>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#define MODULE "voxel_volume"

namespace interface {

// VoxelVolume

VoxelVolume::VoxelVolume(const pv::Region &region):
	VoxelVolume(region, sv_<VoxelPlane>{VoxelPlane()})
{}

VoxelVolume::VoxelVolume(const pv::Region &region,
		const sv_<VoxelPlane> &planes):
	m_region(region),
	m_planes(planes),
	m_w(region.getWidthInVoxels()),
	m_h(region.getHeightInVoxels()),
	m_d(region.getDepthInVoxels())
{
	m_data.resize(m_planes.size());
}

static const sv_<uint8_t> g_no_bytes;

const sv_<uint8_t>& VoxelVolume::plane_bytes(uint8_t plane) const
{
	if(plane >= m_data.size())
		return g_no_bytes;
	return m_data[plane];
}

sv_<uint8_t>& VoxelVolume::plane_bytes_for_write(uint8_t plane)
{
	if(plane >= m_data.size())
		throw Exception(ss_()+"VoxelVolume: there is no plane "+
				itos((int)plane));
	sv_<uint8_t> &bytes = m_data[plane];
	if(bytes.empty()){
		// Materialised on first write, zeroed; see the note on the class
		bytes.resize(voxel_count() * (m_planes[plane].bits / 8), 0);
	}
	return bytes;
}

uint32_t VoxelVolume::plane_at(uint8_t plane, int32_t x, int32_t y,
		int32_t z) const
{
	if(plane >= m_data.size() || !contains(x, y, z))
		return 0;
	const sv_<uint8_t> &bytes = m_data[plane];
	if(bytes.empty())
		return 0;
	const size_t i = index_of(x, y, z);
	switch(m_planes[plane].bits){
	case 8:
		return bytes[i];
	case 16: {
		const uint8_t *p = &bytes[i * 2];
		return (uint32_t)p[0] | ((uint32_t)p[1] << 8);
	}
	default: {
		const uint8_t *p = &bytes[i * 4];
		return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
				((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
	}
	}
}

void VoxelVolume::set_plane_at(uint8_t plane, int32_t x, int32_t y, int32_t z,
		uint32_t value)
{
	if(!contains(x, y, z))
		return;
	// A write of zero to a plane nothing has written yet leaves it alone:
	// zero is what it already reads as, and materialising it would be a
	// megabyte for nothing. This is what makes a worldgen that fills a
	// chunk with air free in every plane it does not touch.
	if(value == 0 && !plane_is_materialised(plane)){
		if(plane >= m_data.size())
			throw Exception(ss_()+"VoxelVolume: there is no plane "+
					itos((int)plane));
		return;
	}
	sv_<uint8_t> &bytes = plane_bytes_for_write(plane);
	const size_t i = index_of(x, y, z);
	switch(m_planes[plane].bits){
	case 8:
		bytes[i] = (uint8_t)value;
		break;
	case 16: {
		uint8_t *p = &bytes[i * 2];
		p[0] = (uint8_t)value;
		p[1] = (uint8_t)(value >> 8);
		break;
	}
	default: {
		uint8_t *p = &bytes[i * 4];
		p[0] = (uint8_t)value;
		p[1] = (uint8_t)(value >> 8);
		p[2] = (uint8_t)(value >> 16);
		p[3] = (uint8_t)(value >> 24);
		break;
	}
	}
}

void VoxelVolume::fill(VoxelInstance v)
{
	if(v.data == 0){
		// Nothing to do, and nothing to allocate: an unwritten plane
		// already reads as zero everywhere
		return;
	}
	sv_<uint8_t> &bytes = plane_bytes_for_write(0);
	const size_t n = voxel_count();
	for(size_t i = 0; i < n; i++){
		bytes[i * 4 + 0] = (uint8_t)v.data;
		bytes[i * 4 + 1] = (uint8_t)(v.data >> 8);
		bytes[i * 4 + 2] = (uint8_t)(v.data >> 16);
		bytes[i * 4 + 3] = (uint8_t)(v.data >> 24);
	}
}

void VoxelVolume::Sampler::setPosition(int32_t x, int32_t y, int32_t z)
{
	m_x = x;
	m_y = y;
	m_z = z;
	m_at = nullptr;
	if(m_volume == nullptr || !m_volume->contains(x, y, z))
		return;
	// Plane 0 is 32 bits wide in every format that has been written so far;
	// a narrower one walks through the accessors instead
	if(m_volume->m_planes[0].bits != 32)
		return;
	sv_<uint8_t> &bytes = m_volume->m_data[0];
	if(bytes.empty())
		return;
	m_at = &bytes[m_volume->index_of(x, y, z) * 4];
}

void VoxelVolume::Sampler::movePositiveX()
{
	m_x++;
	if(m_at == nullptr){
		// Either outside the volume or on a plane nothing has written; in
		// both cases the next voxel has to be looked at properly
		setPosition(m_x, m_y, m_z);
		return;
	}
	if(!m_volume->contains(m_x, m_y, m_z)){
		m_at = nullptr;
		return;
	}
	m_at += 4;
}

void VoxelVolume::Sampler::setVoxel(VoxelInstance v)
{
	if(m_volume == nullptr)
		return;
	if(m_at == nullptr){
		// The plane may be unwritten rather than the position outside it,
		// in which case this is what materialises it
		m_volume->setVoxelAt(m_x, m_y, m_z, v);
		setPosition(m_x, m_y, m_z);
		return;
	}
	m_at[0] = (uint8_t)v.data;
	m_at[1] = (uint8_t)(v.data >> 8);
	m_at[2] = (uint8_t)(v.data >> 16);
	m_at[3] = (uint8_t)(v.data >> 24);
}

VoxelSample VoxelVolume::sample_at(int32_t x, int32_t y, int32_t z) const
{
	VoxelSample out;
	if(!contains(x, y, z))
		return out;
	const size_t n = m_data.size() < VOXEL_MAX_PLANES ?
			m_data.size() : VOXEL_MAX_PLANES;
	for(size_t i = 0; i < n; i++)
		out.planes[i] = plane_at((uint8_t)i, x, y, z);
	return out;
}

void VoxelVolume::set_sample_at(int32_t x, int32_t y, int32_t z,
		const VoxelSample &v)
{
	const size_t n = m_data.size() < VOXEL_MAX_PLANES ?
			m_data.size() : VOXEL_MAX_PLANES;
	for(size_t i = 0; i < n; i++)
		set_plane_at((uint8_t)i, x, y, z, v.planes[i]);
}

bool voxel_volume_self_test()
{
	const pv::Region region(pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(3, 4, 5));
	sv_<VoxelPlane> planes;
	planes.push_back(VoxelPlane());               // the game's own, 32 bits
	planes.push_back(VoxelPlane("mod:heat", 8));
	planes.push_back(VoxelPlane("mod:wear", 16));
	VoxelVolume vol(region, planes);

	assert(vol.getWidth() == 5 && vol.getHeight() == 6 && vol.getDepth() == 7);
	assert(vol.voxel_count() == 5 * 6 * 7);

	// A plane nothing has written reads as zero and costs nothing
	for(uint8_t p = 0; p < 3; p++){
		assert(!vol.plane_is_materialised(p));
		assert(vol.plane_at(p, 0, 0, 0) == 0);
	}
	// And writing zero to it keeps it that way
	vol.set_plane_at(1, 0, 0, 0, 0);
	assert(!vol.plane_is_materialised(1));

	// Each width round-trips, and cuts a value too large for it
	vol.setVoxelAt(0, 1, 2, VoxelInstance(0xdeadbeef));
	vol.set_plane_at(1, 0, 1, 2, 0x5a);
	vol.set_plane_at(2, 0, 1, 2, 0x1234);
	assert(vol.getVoxelAt(0, 1, 2).data == 0xdeadbeef);
	assert(vol.plane_at(1, 0, 1, 2) == 0x5a);
	assert(vol.plane_at(2, 0, 1, 2) == 0x1234);
	vol.set_plane_at(1, 0, 1, 2, 0x1ff);
	assert(vol.plane_at(1, 0, 1, 2) == 0xff);

	// Writing one voxel leaves the others alone
	assert(vol.getVoxelAt(0, 1, 3).data == 0);
	assert(vol.plane_at(1, 1, 1, 2) == 0);

	// The planes are separate arrays: a voxel's are read together
	VoxelSample s = vol.sample_at(0, 1, 2);
	assert(s.planes[0] == 0xdeadbeef);
	assert(s.planes[1] == 0xff);
	assert(s.planes[2] == 0x1234);
	s.planes[1] = 7;
	vol.set_sample_at(-1, -1, -1, s);
	assert(vol.plane_at(1, -1, -1, -1) == 7);

	// Outside the region reads as zero rather than as whatever is next to
	// it in memory, which is what a read past the edge of a chunk means
	assert(vol.getVoxelAt(-2, 1, 2).data == 0);
	assert(vol.getVoxelAt(4, 1, 2).data == 0);
	assert(vol.getVoxelAt(0, 1, 6).data == 0);
	assert(vol.sample_at(9, 9, 9).planes[0] == 0);
	// And a write outside it is dropped rather than landing on a neighbour
	vol.setVoxelAt(-2, 1, 2, VoxelInstance(0xffffffff));
	assert(vol.getVoxelAt(3, 1, 2).data == 0);

	// A sampler walks plane 0 without working the index out each time, and
	// agrees with the accessors about what is where
	{
		VoxelVolume::Sampler sam(&vol);
		sam.setPosition(-1, 1, 2);
		for(int x = -1; x <= 0; x++){
			assert(sam.getVoxel().data == vol.getVoxelAt(x, 1, 2).data);
			sam.movePositiveX();
		}
		// Past the end reads as zero rather than as the next row
		sam.setPosition(3, 1, 2);
		sam.movePositiveX();
		assert(sam.getVoxel().data == 0);
		// And writing through it is writing to the volume
		sam.setPosition(1, 1, 2);
		sam.setVoxel(VoxelInstance(0xabcdef01));
		assert(vol.getVoxelAt(1, 1, 2).data == 0xabcdef01);
		// Including into a plane nothing had written
		VoxelVolume fresh(region);
		VoxelVolume::Sampler s2(&fresh);
		s2.setPosition(0, 0, 0);
		assert(s2.getVoxel().data == 0);
		s2.setVoxel(VoxelInstance(42));
		assert(fresh.getVoxelAt(0, 0, 0).data == 42);
		s2.movePositiveX();
		s2.setVoxel(VoxelInstance(43));
		assert(fresh.getVoxelAt(1, 0, 0).data == 43);
	}

	// The layout is x fastest, then y, then z -- what every blob written
	// before planes is in
	const sv_<uint8_t> &bytes = vol.plane_bytes(1);
	assert(!bytes.empty());
	const size_t i = (size_t)(0 - -1) + (size_t)(1 - -1) * 5 +
			(size_t)(2 - -1) * 5 * 6;
	assert(bytes[i] == 0xff);

	return true;
}

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

// VoxelVolume: format 4
//
// Region, then the plane list, then the bytes of the planes that have been
// written, so a blob says what is in it without its registry. A plane
// nothing wrote is a flag and no bytes.
//
// Formats 2 and 3 are what a volume was before planes: one 32-bit plane in
// the same layout. They load, so saved worlds and older clients keep
// working, and what is loaded is written back out as 4.

static ss_ serialize_volume_planes(const VoxelVolume &volume, bool compress)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)4); // Format
		auto region = volume.getEnclosingRegion();
		ar(region.getLowerCorner());
		ar(region.getUpperCorner());
		ar((uint8_t)compress);
		const sv_<VoxelPlane> &planes = volume.planes();
		ar((uint8_t)planes.size());
		std::ostringstream raw_os(std::ios::binary);
		for(size_t i = 0; i < planes.size(); i++){
			ar(planes[i].name, planes[i].bits);
			const sv_<uint8_t> &bytes = volume.plane_bytes((uint8_t)i);
			ar((uint8_t)!bytes.empty());
			if(!bytes.empty())
				raw_os.write((const char*)&bytes[0], bytes.size());
		}
		ss_ raw = raw_os.str();
		if(compress){
			std::ostringstream compressed_os(std::ios::binary);
			interface::compress_zstd(raw, compressed_os);
			ar(compressed_os.str());
		} else {
			ar(raw);
		}
	}
	return os.str();
}

ss_ serialize_volume_simple(const VoxelVolume &volume)
{
	return serialize_volume_planes(volume, false);
}

ss_ serialize_volume_compressed(const VoxelVolume &volume)
{
	return serialize_volume_planes(volume, true);
}

up_<VoxelVolume> deserialize_volume(const ss_ &data)
{
	std::istringstream is(data, std::ios::binary);
	cereal::PortableBinaryInputArchive ar(is);
	uint8_t format = 0;
	ar(format);
	if(format == 2 || format == 3){
		// One 32-bit plane, written a voxel at a time
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		up_<VoxelVolume> volume(new VoxelVolume(pv::Region(lc, uc)));
		const size_t n = volume->voxel_count();
		if(format == 2){
			sv_<uint8_t> &bytes = volume->plane_bytes_for_write(0);
			for(size_t i = 0; i < n; i++){
				VoxelInstance v;
				ar(v);
				bytes[i * 4 + 0] = (uint8_t)v.data;
				bytes[i * 4 + 1] = (uint8_t)(v.data >> 8);
				bytes[i * 4 + 2] = (uint8_t)(v.data >> 16);
				bytes[i * 4 + 3] = (uint8_t)(v.data >> 24);
			}
			return volume;
		}
		ss_ compressed_data;
		ar(compressed_data);
		std::istringstream compressed_is(compressed_data, std::ios::binary);
		std::ostringstream raw_os(std::ios::binary);
		decompress_zlib(compressed_is, raw_os);
		{
			std::istringstream raw_is(raw_os.str(), std::ios::binary);
			cereal::PortableBinaryInputArchive ar(raw_is);
			sv_<uint8_t> &bytes = volume->plane_bytes_for_write(0);
			for(size_t i = 0; i < n; i++){
				VoxelInstance v;
				ar(v);
				bytes[i * 4 + 0] = (uint8_t)v.data;
				bytes[i * 4 + 1] = (uint8_t)(v.data >> 8);
				bytes[i * 4 + 2] = (uint8_t)(v.data >> 16);
				bytes[i * 4 + 3] = (uint8_t)(v.data >> 24);
			}
		}
		return volume;
	}
	if(format == 4){
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		uint8_t compressed = 0;
		ar(compressed);
		uint8_t num_planes = 0;
		ar(num_planes);
		sv_<VoxelPlane> planes;
		sv_<bool> present;
		for(uint8_t i = 0; i < num_planes; i++){
			VoxelPlane p;
			uint8_t has = 0;
			ar(p.name, p.bits, has);
			planes.push_back(p);
			present.push_back(has != 0);
		}
		up_<VoxelVolume> volume(new VoxelVolume(pv::Region(lc, uc), planes));
		ss_ raw;
		ar(raw);
		if(compressed){
			std::ostringstream raw_os(std::ios::binary);
			decompress_zstd(raw, raw_os);
			raw = raw_os.str();
		}
		size_t at = 0;
		for(uint8_t i = 0; i < num_planes; i++){
			if(!present[i])
				continue;
			sv_<uint8_t> &bytes = volume->plane_bytes_for_write(i);
			if(at + bytes.size() > raw.size())
				throw Exception("deserialize_volume(): plane data is short");
			memcpy(&bytes[0], &raw[at], bytes.size());
			at += bytes.size();
		}
		return volume;
	}
	return up_<VoxelVolume>();
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
