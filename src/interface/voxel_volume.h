// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include <PolyVoxCore/RawVolume.h>

namespace interface
{
	// A box of voxels, stored a plane at a time.
	//
	// Where VoxelVolume is one array of words, this is one
	// array per plane holding the same bits of every voxel -- so a
	// simulation that wants one field gets a byte per voxel instead of four,
	// a plane compresses the way a column of one material does, and a module
	// can be given a plane of its own without the game finding room for it
	// in a word it has already spent. See VoxelPlane in interface/voxel.h.
	//
	// A plane nothing has written is not allocated at all, and reads of it
	// answer zero. That is not an optimisation for a mixture world: nearly
	// every chunk of one is entirely one material, and a plane per material
	// per chunk allocated eagerly is hundreds of megabytes of zeroes.
	//
	// It satisfies what PolyVox's cube extractor wants of a volume -- a
	// VoxelType, a nested Sampler it constructs and never uses, and
	// getVoxelAt -- so the mesher needs no view type and PolyVox needs no
	// patch. getVoxelAt is plane 0, which is what every caller that predates
	// planes means by a voxel.
	class VoxelVolume
	{
	public:
		typedef VoxelInstance VoxelType;

		// A cursor into plane 0, for walking a run of voxels without
		// working the index out from the coordinates each time. What wants
		// it is merging one volume into another, which is a whole section
		// of voxels at a time; PolyVox's extractor also declares one as a
		// member, and never calls anything on it.
		//
		// Only plane 0, because that is what everything walking a volume
		// this way is about. A sweep over another plane wants
		// plane_bytes(), which hands over the whole array.
		class Sampler
		{
		public:
			Sampler(){}
			Sampler(VoxelVolume *volume): m_volume(volume){}

			void setPosition(int32_t x, int32_t y, int32_t z);
			void movePositiveX();

			VoxelInstance getVoxel() const
			{
				if(m_at == nullptr)
					return VoxelInstance(0);
				return VoxelInstance(
						(uint32_t)m_at[0] | ((uint32_t)m_at[1] << 8) |
						((uint32_t)m_at[2] << 16) | ((uint32_t)m_at[3] << 24));
			}

			void setVoxel(VoxelInstance v);

		private:
			VoxelVolume *m_volume = nullptr;
			// Into plane 0's bytes, or null when the position is outside the
			// volume or nothing has written the plane
			uint8_t *m_at = nullptr;
			int32_t m_x = 0, m_y = 0, m_z = 0;
		};

		VoxelVolume(){}
		// A volume of one 32-bit plane, which is what a format says unless
		// it says otherwise
		VoxelVolume(const pv::Region &region);
		VoxelVolume(const pv::Region &region, const sv_<VoxelPlane> &planes);

		const pv::Region& getEnclosingRegion() const { return m_region; }
		int32_t getWidth() const { return m_w; }
		int32_t getHeight() const { return m_h; }
		int32_t getDepth() const { return m_d; }
		size_t voxel_count() const { return (size_t)m_w * m_h * m_d; }
		const sv_<VoxelPlane>& planes() const { return m_planes; }

		// Plane 0 as a word. Outside the region reads as zero, which is
		// VOXELTYPEID_UNDEFINED under every format that binds an id at the
		// bottom of it -- "nothing has got here yet", which is what a read
		// past the edge of a chunk means.
		VoxelInstance getVoxelAt(int32_t x, int32_t y, int32_t z) const
		{
			return VoxelInstance(plane_at(0, x, y, z));
		}
		VoxelInstance getVoxelAt(const pv::Vector3DInt32 &p) const
		{
			return getVoxelAt(p.getX(), p.getY(), p.getZ());
		}
		// Returns whether the voxel was inside the volume, which is what
		// pv::RawVolume's own setVoxelAt returns
		bool setVoxelAt(int32_t x, int32_t y, int32_t z, VoxelInstance v)
		{
			set_plane_at(0, x, y, z, v.data);
			return contains(x, y, z);
		}
		bool setVoxelAt(const pv::Vector3DInt32 &p, VoxelInstance v)
		{
			return setVoxelAt(p.getX(), p.getY(), p.getZ(), v);
		}

		// Every voxel of plane 0 set to one word. What a caller that is
		// about to write the whole volume starts with.
		void fill(VoxelInstance v);

		// One plane's value at one voxel
		uint32_t plane_at(uint8_t plane, int32_t x, int32_t y, int32_t z) const;
		void set_plane_at(uint8_t plane, int32_t x, int32_t y, int32_t z,
				uint32_t value);

		// Every plane at one voxel, read together; see VoxelSample
		VoxelSample sample_at(int32_t x, int32_t y, int32_t z) const;
		VoxelSample sample_at(const pv::Vector3DInt32 &p) const
		{
			return sample_at(p.getX(), p.getY(), p.getZ());
		}
		void set_sample_at(int32_t x, int32_t y, int32_t z,
				const VoxelSample &v);

		// A whole plane's bytes, for a caller that sweeps one rather than
		// asking per voxel. Empty when nothing has written the plane, which
		// means every value in it is zero.
		//
		// The layout is x fastest, then y, then z, which is the layout
		// pv::RawVolume had and what every blob written before planes is in.
		const sv_<uint8_t>& plane_bytes(uint8_t plane) const;
		sv_<uint8_t>& plane_bytes_for_write(uint8_t plane);
		bool plane_is_materialised(uint8_t plane) const
		{
			return plane < m_data.size() && !m_data[plane].empty();
		}

		bool contains(int32_t x, int32_t y, int32_t z) const
		{
			const pv::Vector3DInt32 &lc = m_region.getLowerCorner();
			return x >= lc.getX() && y >= lc.getY() && z >= lc.getZ() &&
					x - lc.getX() < m_w && y - lc.getY() < m_h &&
					z - lc.getZ() < m_d;
		}

	private:
		friend class VoxelVolume::Sampler;
		size_t index_of(int32_t x, int32_t y, int32_t z) const
		{
			const pv::Vector3DInt32 &lc = m_region.getLowerCorner();
			return (size_t)(x - lc.getX()) +
					(size_t)(y - lc.getY()) * m_w +
					(size_t)(z - lc.getZ()) * m_w * m_h;
		}

		pv::Region m_region{pv::Vector3DInt32(0, 0, 0),
				pv::Vector3DInt32(-1, -1, -1)};
		sv_<VoxelPlane> m_planes;
		// One entry per plane; empty means nothing has written it
		sv_<sv_<uint8_t>> m_data;
		int32_t m_w = 0, m_h = 0, m_d = 0;
	};

	// Asserts what a VoxelVolume does: the region and the layout, a plane
	// that nothing wrote reading as zero and costing nothing, planes of
	// each width, and reads outside the region. Runs with
	// voxel_format_self_test().
	bool voxel_volume_self_test();

	ss_ serialize_volume_simple(const VoxelVolume &volume);
	ss_ serialize_volume_compressed(const VoxelVolume &volume);
	up_<VoxelVolume> deserialize_volume(const ss_ &data);

	// pv::RawVolume<int32_t>
	ss_ serialize_volume_simple(const pv::RawVolume<int32_t> &volume);
	ss_ serialize_volume_compressed(const pv::RawVolume<int32_t> &volume);
	up_<pv::RawVolume<int32_t>> deserialize_volume_int32(const ss_ &data);

	// pv::RawVolume<uint8_t>
	ss_ serialize_volume_simple(const pv::RawVolume<uint8_t> &volume);
	ss_ serialize_volume_compressed(const pv::RawVolume<uint8_t> &volume);
	up_<pv::RawVolume<uint8_t>> deserialize_volume_8bit(const ss_ &data);
}
// vim: set noet ts=4 sw=4:
