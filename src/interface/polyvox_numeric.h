// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <PolyVoxCore/Vector.h>

namespace interface
{
	namespace pv = PolyVox;

	static inline int container_coord(int x, int d)
	{
		return (x>=0 ? x : x-d+1) / d;
	}
	static inline pv::Vector3DInt32 container_coord(
			const pv::Vector3DInt32 &p, const pv::Vector3DInt32 &d)
	{
		return pv::Vector3DInt32(
				container_coord(p.getX(), d.getX()),
				container_coord(p.getY(), d.getY()),
				container_coord(p.getZ(), d.getZ()));
	}
	static inline pv::Vector3DInt32 container_coord(
			const pv::Vector3DInt32 &p, const pv::Vector3DInt16 &d)
	{
		return pv::Vector3DInt32(
				container_coord(p.getX(), d.getX()),
				container_coord(p.getY(), d.getY()),
				container_coord(p.getZ(), d.getZ()));
	}
	static inline pv::Vector3DInt16 container_coord16(
			const pv::Vector3DInt32 &p, const pv::Vector3DInt16 &d)
	{
		return pv::Vector3DInt16(
				container_coord(p.getX(), d.getX()),
				container_coord(p.getY(), d.getY()),
				container_coord(p.getZ(), d.getZ()));
	}
	static inline pv::Vector<2, int16_t> container_coord16(
			const pv::Vector<2, int32_t> &p, const pv::Vector<2, int16_t> &d)
	{
		return pv::Vector<2, int16_t>(
				container_coord(p.getX(), d.getX()),
				container_coord(p.getY(), d.getY()));
	}
}
// vim: set noet ts=4 sw=4:
