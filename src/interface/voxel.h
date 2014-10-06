// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace Urho3D
{
	class Context;
	class Model;
}

namespace interface
{
	using namespace Urho3D;

	Model* create_simple_voxel_model(Context *context, int w, int h, int d,
	        const ss_ &source_data);
}
// vim: set noet ts=4 sw=4:
