// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <cereal/cereal.hpp>
#include <Vector2.h>
#include <Ptr.h>

namespace cereal
{
	template<class Archive>
	void save(Archive &archive, const Urho3D::IntVector2 &v)
	{
		archive((int32_t)v.x_);
		archive((int32_t)v.y_);
	}
	template<class Archive>
	void load(Archive &archive, Urho3D::IntVector2 &v)
	{
		int32_t x, y;
		archive(x, y);
		v.x_ = x;
		v.y_ = y;
	}
}
// vim: set noet ts=4 sw=4:
