// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include <PolyVoxCore/SimpleVolume.h>
#include <PolyVoxCore/SurfaceMesh.h>
#include <PolyVoxCore/CubicSurfaceExtractorWithNormals.h>
#include <tolua++.h>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Scene.h>
#include <Node.h>
#include <StaticModel.h>
#include <Model.h>
#include <Geometry.h>
#include <IndexBuffer.h>
#include <VertexBuffer.h>
#pragma GCC diagnostic pop
#define MODULE "lua_bindings"

namespace magic = Urho3D;
namespace pv = PolyVox;

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace lua_bindings {

// Creates a model from a string; eg. (2, 2, 2, "11101111")
static SharedPtr<Model> create_simple_voxel_model(Context *context,
		int w, int h, int d, const ss_ &source_data)
{
	if(w < 0 || h < 0 || d < 0)
		throw Exception("Negative dimension");
	if(w * h * d != (int)source_data.size())
		throw Exception("Mismatched data size");
	int x_off = -w/2;
	int y_off = -h/2;
	int z_off = -d/2;
	pv::SimpleVolume<uint8_t> volData(pv::Region(
			pv::Vector3DInt32(x_off, y_off, z_off),
			pv::Vector3DInt32(w + x_off, h + y_off, d + z_off)));
	size_t i = 0;
	for(int z = 0; z < d; z++)
	for(int y = 0; y < h; y++)
	for(int x = 0; x < w; x++){
		char c = source_data[i++];
		volData.setVoxelAt(x+x_off, y+y_off, z+z_off, c == '0' ? 0 : 255);
	}

	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<pv::SimpleVolume<uint8_t>>
			surfaceExtractor(&volData, volData.getEnclosingRegion(), &pv_mesh);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	const size_t num_vertices = pv_vertices.size();
	const size_t num_indices = pv_indices.size();

	sv_<float> vertex_data;
	vertex_data.resize(num_vertices * 6); // vertex + normal
	for(size_t i = 0; i < num_vertices; i++){
		vertex_data[i*6 + 0] = pv_vertices[i].position.getX();
		vertex_data[i*6 + 1] = pv_vertices[i].position.getY();
		vertex_data[i*6 + 2] = pv_vertices[i].position.getZ();
		vertex_data[i*6 + 3] = pv_vertices[i].normal.getX();
		vertex_data[i*6 + 4] = pv_vertices[i].normal.getY();
		vertex_data[i*6 + 5] = pv_vertices[i].normal.getZ();
	}

	sv_<short> index_data;
	index_data.resize(num_indices);
	for(size_t i = 0; i < num_indices; i++){
		index_data[i] = pv_indices[i];
	}

	SharedPtr<VertexBuffer> vb(new VertexBuffer(context));
	// Shadowed buffer needed for raycasts to work, and so that data can be
	// automatically restored on device loss
	vb->SetShadowed(true);
	vb->SetSize(num_vertices, magic::MASK_POSITION | magic::MASK_NORMAL);
	vb->SetData(&vertex_data[0]);

	SharedPtr<IndexBuffer> ib(new IndexBuffer(context));
	ib->SetShadowed(true);
	ib->SetSize(num_indices, false);
	ib->SetData(&index_data[0]);

	SharedPtr<Geometry> geom(new Geometry(context));
	geom->SetVertexBuffer(0, vb);
	geom->SetIndexBuffer(ib);
	geom->SetDrawRange(TRIANGLE_LIST, 0, num_indices);

	SharedPtr<Model> fromScratchModel(new Model(context));
	fromScratchModel->SetNumGeometries(1);
	fromScratchModel->SetGeometry(0, 0, geom);
	fromScratchModel->SetBoundingBox(BoundingBox(
			Vector3(-0.5f*w, -0.5f*h, -0.5f*d), Vector3(0.5f*w, 0.5f*h, 0.5f*d)));

	return fromScratchModel;
}

// NOTE: This API is designed this way because otherwise ownership management of
//       objects sucks
// set_simple_voxel_model(node, w, h, d, data: string)
static int l_set_simple_voxel_model(lua_State *L)
{
	int w = lua_tointeger(L, 2);
	int h = lua_tointeger(L, 3);
	int d = lua_tointeger(L, 4);
	ss_ data = lua_tocppstring(L, 5);

	if((int)data.size() != w * h * d){
		log_e(MODULE, "set_simple_voxel_model(): Data size does not match "
				"with dimensions (%zu vs. %i)", data.size(), w*h*d);
		return 0;
	}

	tolua_Error tolua_err;
	//if(!tolua_isusertype(L, 1, "const Node", 0, &tolua_err)){
	if(!tolua_isusertype(L, 1, "Node", 0, &tolua_err)){
		tolua_error(L, "Error in set_simple_voxel_model", &tolua_err);
		return 0;
	}
	log_d(MODULE, "set_simple_voxel_model(): Valid Node given");
	//const Node *node = (const Node*)tolua_tousertype(L, 1, 0);
	Node *node = (Node*)tolua_tousertype(L, 1, 0);
	log_d(MODULE, "set_simple_voxel_model(): node=%p", node);

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	SharedPtr<Model> fromScratchModel =
			create_simple_voxel_model(context, w, h, d, data);

	StaticModel* object = node->CreateComponent<StaticModel>();
	object->SetModel(fromScratchModel);

	return 0;
}

void init_voxel(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){\
	lua_pushcfunction(L, l_##name);\
	lua_setglobal(L, "__buildat_" #name);\
}
	DEF_BUILDAT_FUNC(set_simple_voxel_model);
}

} // namespace lua_bindingss
// vim: set noet ts=4 sw=4:

