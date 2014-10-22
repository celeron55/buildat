// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <PolyVoxCore/Vector.h>

namespace std {

	template<> struct hash<PolyVox::Vector<2u, int16_t>>{
		std::size_t operator()(const PolyVox::Vector<2u, int16_t> &v) const {
			return ((std::hash<int16_t>() (v.getX()) << 0) ^
					   (std::hash<int16_t>() (v.getY()) << 1));
		}
	};

	template<> struct hash<PolyVox::Vector<3u, int16_t>>{
		std::size_t operator()(const PolyVox::Vector<3u, int16_t> &v) const {
			return ((std::hash<int16_t>() (v.getX()) << 0) ^
					   (std::hash<int16_t>() (v.getY()) << 1) ^
					   (std::hash<int16_t>() (v.getZ()) << 2));
		}
	};

}

// PolyVox logging helpers
// TODO: Move to a header (core/types_polyvox.h or something)
template<>
ss_ dump(const PolyVox::Vector3DInt16 &v){
	std::ostringstream os(std::ios::binary);
	os<<"("<<v.getX()<<", "<<v.getY()<<", "<<v.getZ()<<")";
	return os.str();
}
template<>
ss_ dump(const PolyVox::Vector3DInt32 &v){
	std::ostringstream os(std::ios::binary);
	os<<"("<<v.getX()<<", "<<v.getY()<<", "<<v.getZ()<<")";
	return os.str();
}
#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

// vim: set noet ts=4 sw=4:
