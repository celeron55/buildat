// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include <PolyVoxCore/RawVolume.h>
#include <CustomGeometry.h>

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
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg);

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
			// Set when the generator wrote skylight into vertex colors
			bool has_colors = false;
			// CustomGeometry can't handle an index buffer
			PODVector<CustomGeometryVertex> vertex_data;
		};
#endif

		void preload_textures(pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg);

		// What a voxel shader is handed, which is the whole interface between
		// this and a game's own rendering:
		//   TU_DIFFUSE   the atlas of the voxel textures
		//   TU_NORMAL    tangent space normal in rgb, static_spots in a
		//   TU_SPECULAR  a surface map, not Urho's specular: roughness in r
		//                and spec_strength, translucency and spots in gba
		//   vertex color ambient = cAmbientColor.rgb * a + rgb, when
		//                use_skylight. The alpha is how much of the sky the
		//                surface sees and the rgb is the light that reaches
		//                it regardless of the sky: bounced light, and the
		//                voxel's lamplight. See BOUNCE_COLOR and LAMP_COLOR
		//                in impl/mesh.cpp. cAmbientColor being the color of
		//                the sky, a world moves the sun by setting it and
		//                nothing has to be meshed again.
		//   Roughness, Metallic  both 0; the maps carry these
		// interface/atlas.h says what fills the two maps. No technique is set:
		// a game picks one for its chunks in voxelworld.sub_material_update(),
		// and skylit geometry stays invisible until it does. The reference
		// implementation is PBRVoxel in games/voxel_lighting.

		// A voxel whose definition has a shape contributes that shape's quads
		// instead of cube faces; see VoxelDefinition::shape in
		// interface/voxel.h. The LOD generators below do not do this, so a
		// world that uses LOD loses its shaped voxels in the distance.
		//
		// Can be called from any thread
		// use_skylight: light the geometry by VoxelInstance::get_skylight()
		// and get_lamplight() of the voxel in front of each face, along with
		// per-vertex ambient occlusion and a per-face brightness, written
		// into vertex colors. Only worlds that actually fill those bits
		// should ask for it.
		void generate_voxel_geometry(sm_<uint, TemporaryGeometry> &result,
				pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false);

		void set_voxel_geometry(CustomGeometry *cg, Context *context,
				const sm_<uint, TemporaryGeometry> &temp_geoms,
				AtlasRegistry *atlas_reg);

		// Set custom geometry from voxel volume, using a voxel registry
		// Volume should be padded by one voxel on each edge
		// NOTE: volume is non-const due to PolyVox deficiency
		void set_voxel_geometry(CustomGeometry *cg, Context *context,
				pv::RawVolume<VoxelInstance> &volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false);

		// Voxel LOD geometry generation (lod=1 -> 1:1, lod=3 -> 1:3)

		// Can be called from any thread
		up_<pv::RawVolume<VoxelInstance>> generate_voxel_lod_volume(
				int lod, pv::RawVolume<VoxelInstance>&volume_orig);

		// Can be called from any thread
		void generate_voxel_lod_geometry(int lod,
				sm_<uint, TemporaryGeometry> &result,
				pv::RawVolume<VoxelInstance> &lod_volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false);

		void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
				const sm_<uint, TemporaryGeometry> &temp_geoms,
				AtlasRegistry *atlas_reg);

		void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
				pv::RawVolume<VoxelInstance> &volume_orig,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false);

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
