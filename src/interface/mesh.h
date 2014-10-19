// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include <PolyVoxCore/RawVolume.h>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <CustomGeometry.h>
#pragma GCC diagnostic pop

namespace Urho3D
{
	class Context;
	class Model;
	class CustomGeometry;
	class Node;
}

namespace interface
{
	namespace mesh
	{
		using namespace Urho3D;
		namespace pv = PolyVox;

		// Create a model from a string; eg. (2, 2, 2, "11101111")
		Model* create_simple_voxel_model(Context *context, int w, int h, int d,
				const ss_ &source_data);

		// Create a model from 8-bit voxel data, using a voxel registry, without
		// textures or normals, based on the physically_solid flag.
		// Returns nullptr if there is no geometry
		Model* create_8bit_voxel_physics_model(Context *context,
				int w, int h, int d, const ss_ &source_data,
				VoxelRegistry *voxel_reg);

		// Set custom geometry from 8-bit voxel data, using a voxel registry
		void set_8bit_voxel_geometry(CustomGeometry *cg, Context *context,
				int w, int h, int d, const ss_ &source_data,
				VoxelRegistry *voxel_reg, TextureAtlasRegistry *atlas_reg);

		// Create a model from voxel volume, using a voxel registry, without
		// textures or normals, based on the physically_solid flag.
		// Returns nullptr if there is no geometry
		// Volume should be padded by one voxel on each edge
		// NOTE: volume is non-const due to PolyVox deficiency
		Model* create_voxel_physics_model(Context *context,
				pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg);

		// Voxel geometry generation

#if 0
		// TODO: Create a custom Drawable that can use an index buffer
		struct TemporaryGeometry
		{
			uint atlas_id = 0;
			sv_<float> vertex_data; // vertex(3) + normal(3) + texcoord(2)
			sv_<unsigned> index_data; // Urho3D eats unsigned as large indices
		};
#else
		struct TemporaryGeometry
		{
			uint atlas_id = 0;
			// CustomGeometry can't handle an index buffer
			PODVector<CustomGeometryVertex> vertex_data;
		};
#endif

		void preload_textures(pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg, TextureAtlasRegistry *atlas_reg);

		// Can be called from any thread
		void generate_voxel_geometry(sm_<uint, TemporaryGeometry> &result,
				pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg, TextureAtlasRegistry *atlas_reg);

		void set_voxel_geometry(CustomGeometry *cg, Context *context,
				const sm_<uint, TemporaryGeometry> &temp_geoms,
				TextureAtlasRegistry *atlas_reg);

		// Set custom geometry from voxel volume, using a voxel registry
		// Volume should be padded by one voxel on each edge
		// NOTE: volume is non-const due to PolyVox deficiency
		void set_voxel_geometry(CustomGeometry *cg, Context *context,
				pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg, TextureAtlasRegistry *atlas_reg);

		// Voxel LOD geometry generation (lod=1 -> 1:1, lod=3 -> 1:3)

		// Can be called from any thread
		up_<pv::RawVolume<VoxelInstance>> generate_voxel_lod_volume(
				int lod, pv::RawVolume<VoxelInstance>&volume_orig);

		// Can be called from any thread
		void generate_voxel_lod_geometry(int lod,
				sm_<uint, TemporaryGeometry> &result,
				pv::RawVolume<VoxelInstance> &lod_volume,
				VoxelRegistry *voxel_reg, TextureAtlasRegistry *atlas_reg);

		void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
				const sm_<uint, TemporaryGeometry> &temp_geoms,
				TextureAtlasRegistry *atlas_reg);

		void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
				pv::RawVolume<VoxelInstance> &volume_orig,
				VoxelRegistry *voxel_reg, TextureAtlasRegistry *atlas_reg);

		// Voxel physics generation

		struct TemporaryBox
		{
			Vector3 size;
			Vector3 position;
		};

		// Can be called from any thread
		void generate_voxel_physics_boxes(
				sv_<TemporaryBox> &result_boxes,
				pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg);

		void set_voxel_physics_boxes(Node *node, Context *context,
				const sv_<TemporaryBox> &boxes, bool do_update_mass);

		void set_voxel_physics_boxes(Node *node, Context *context,
				pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg);
	}
}
// vim: set noet ts=4 sw=4:
