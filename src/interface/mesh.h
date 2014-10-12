// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include <PolyVoxCore/RawVolume.h>

namespace Urho3D
{
	class Context;
	class Model;
	class CustomGeometry;
}

namespace interface
{
	using namespace Urho3D;
	namespace pv = PolyVox;

	// Create a model from a string; eg. (2, 2, 2, "11101111")
	Model* create_simple_voxel_model(Context *context, int w, int h, int d,
			const ss_ &source_data);
	// Create a model from 8-bit voxel data, using a voxel registry, without
	// textures or normals, based on the physically_solid flag.
	Model* create_8bit_voxel_physics_model(Context *context,
			int w, int h, int d, const ss_ &source_data,
			VoxelRegistry *voxel_reg);
	// Set custom geometry from 8-bit voxel data, using a voxel registry
	void set_8bit_voxel_geometry(CustomGeometry *cg, Context *context,
			int w, int h, int d, const ss_ &source_data,
			VoxelRegistry *voxel_reg);

	// Create a model from voxel volume, using a voxel registry, without
	// textures or normals, based on the physically_solid flag.
	// NOTE: volume is non-const due to PolyVox deficiency
	Model* create_voxel_physics_model(Context *context,
			pv::RawVolume<VoxelInstance> &volume,
			VoxelRegistry *voxel_reg);
	// Set custom geometry from voxel volume, using a voxel registry
	// NOTE: volume is non-const due to PolyVox deficiency
	void set_voxel_geometry(CustomGeometry *cg, Context *context,
			pv::RawVolume<VoxelInstance> &volume,
			VoxelRegistry *voxel_reg);
}
// vim: set noet ts=4 sw=4:
