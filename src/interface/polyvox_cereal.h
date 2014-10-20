// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <PolyVoxCore/Vector.h>
#include <cereal/cereal.hpp>

namespace cereal {
	template<class Archive>
	void save(Archive &archive, const PolyVox::Vector3DInt16 &v){
		archive((int16_t)v.getX(), (int16_t)v.getY(), (int16_t)v.getZ());
	}
	template<class Archive>
	void load(Archive &archive, PolyVox::Vector3DInt16 &v){
		int16_t x, y, z;
		archive(x, y, z);
		v.setX(x); v.setY(y); v.setZ(z);
	}

	template<class Archive>
	void save(Archive &archive, const PolyVox::Vector3DInt32 &v){
		archive((int32_t)v.getX(), (int32_t)v.getY(), (int32_t)v.getZ());
	}
	template<class Archive>
	void load(Archive &archive, PolyVox::Vector3DInt32 &v){
		int32_t x, y, z;
		archive(x, y, z);
		v.setX(x); v.setY(y); v.setZ(z);
	}

	template<class Archive>
	void save(Archive &archive, const PolyVox::Vector<2, int32_t> &v){
		archive((int32_t)v.getX(), (int32_t)v.getY());
	}
	template<class Archive>
	void load(Archive &archive, PolyVox::Vector<2, int32_t> &v){
		int32_t x, y;
		archive(x, y);
		v.setX(x); v.setY(y);
	}

	template<class Archive>
	void save(Archive &archive, const PolyVox::Vector<2, int16_t> &v){
		archive((int16_t)v.getX(), (int16_t)v.getY());
	}
	template<class Archive>
	void load(Archive &archive, PolyVox::Vector<2, int16_t> &v){
		int16_t x, y;
		archive(x, y);
		v.setX(x); v.setY(y);
	}
}

// vim: set noet ts=4 sw=4:
