// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/mesh.h"
#include <PolyVoxCore/SimpleVolume.h>
#include <PolyVoxCore/SurfaceMesh.h>
#include <PolyVoxCore/CubicSurfaceExtractorWithNormals.h>
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

namespace magic = Urho3D;
namespace pv = PolyVox;

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace interface {

// Creates a model from a string; eg. (2, 2, 2, "11101111")
Model* create_simple_voxel_model(Context *context,
		int w, int h, int d, const ss_ &source_data)
{
	if(w < 0 || h < 0 || d < 0)
		throw Exception("Negative dimension");
	if(w * h * d != (int)source_data.size())
		throw Exception("Mismatched data size");
	pv::SimpleVolume<uint8_t> volData(pv::Region(
			pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(w, h, d)));
	size_t i = 0;
	for(int z = 0; z < d; z++)
	for(int y = 0; y < h; y++)
	for(int x = 0; x < w; x++){
		char c = source_data[i++];
		volData.setVoxelAt(x, y, z, c == '0' ? 0 : 255);
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
		vertex_data[i*6 + 0] = pv_vertices[i].position.getX() - w/2.0f - 0.5f;
		vertex_data[i*6 + 1] = pv_vertices[i].position.getY() - h/2.0f - 0.5f;
		vertex_data[i*6 + 2] = pv_vertices[i].position.getZ() - d/2.0f - 0.5f;
		vertex_data[i*6 + 3] = pv_vertices[i].normal.getX();
		vertex_data[i*6 + 4] = pv_vertices[i].normal.getY();
		vertex_data[i*6 + 5] = pv_vertices[i].normal.getZ();
	}

	sv_<short> index_data;
	index_data.resize(num_indices);
	for(size_t i = 0; i < num_indices; i++){
		if(pv_indices[i] >= 0x10000)
			throw Exception("Index too large");
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

	Model *fromScratchModel = new Model(context);
	fromScratchModel->SetNumGeometries(1);
	fromScratchModel->SetGeometry(0, 0, geom);
	fromScratchModel->SetBoundingBox(BoundingBox(
			Vector3(-0.5f*w, -0.5f*h, -0.5f*d), Vector3(0.5f*w, 0.5f*h, 0.5f*d)));

	return fromScratchModel;
}

} // namespace interface
// vim: set noet ts=4 sw=4:
