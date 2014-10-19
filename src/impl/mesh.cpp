// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "core/log.h"
#include <PolyVoxCore/SimpleVolume.h>
#include <PolyVoxCore/SurfaceMesh.h>
#include <PolyVoxCore/CubicSurfaceExtractorWithNormals.h>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Scene.h>
#include <Node.h>
#include <StaticModel.h>
#include <Model.h> // Resource parameter of StaticModel
#include <Geometry.h>
#include <IndexBuffer.h>
#include <VertexBuffer.h>
#include <CustomGeometry.h> // A Drawable similarly as StaticModel
#include <Material.h>
#include <Technique.h>
#include <Context.h>
#include <ResourceCache.h>
#include <Texture2D.h> // Allows cast to Texture
#include <CollisionShape.h>
#include <RigidBody.h>
#pragma GCC diagnostic pop
#include <climits>
#define MODULE "mesh"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::VoxelInstance;

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace interface {
namespace mesh {

// Create a model from a string; eg. (2, 2, 2, "11101111")
Model* create_simple_voxel_model(Context *context,
		int w, int h, int d, const ss_ &source_data)
{
	if(w < 0 || h < 0 || d < 0)
		throw Exception("Negative dimension");
	if(w * h * d != (int)source_data.size())
		throw Exception("Mismatched data size");
	pv::SimpleVolume<uint8_t> volume(pv::Region(
			pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(w, h, d)));
	size_t i = 0;
	for(int z = 0; z < d; z++){
		for(int y = 0; y < h; y++){
			for(int x = 0; x < w; x++){
				char c = source_data[i++];
				volume.setVoxelAt(x, y, z, c == '0' ? 0 : 255);
			}
		}
	}

	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<pv::SimpleVolume<uint8_t>>
	surfaceExtractor(&volume, volume.getEnclosingRegion(), &pv_mesh);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	const size_t num_vertices = pv_vertices.size();
	const size_t num_indices = pv_indices.size();

	sv_<float> vertex_data;
	vertex_data.resize(num_vertices * 6); // vertex + normal
	for(size_t i = 0; i < num_vertices; i++){
		vertex_data[i*6 + 0] = pv_vertices[i].position.getX() - w/2.0f - 0.0f;
		vertex_data[i*6 + 1] = pv_vertices[i].position.getY() - h/2.0f - 0.0f;
		vertex_data[i*6 + 2] = pv_vertices[i].position.getZ() - d/2.0f - 0.0f;
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

// Create a model from 8-bit voxel data, using a voxel registry, without
// textures or normals, based on the physically_solid flag.
Model* create_8bit_voxel_physics_model(Context *context,
		int w, int h, int d, const ss_ &source_data,
		VoxelRegistry *voxel_reg)
{
	if(w < 0 || h < 0 || d < 0)
		throw Exception("Negative dimension");
	if(w * h * d != (int)source_data.size())
		throw Exception("Mismatched data size");
	pv::RawVolume<VoxelInstance> volume(pv::Region(
			pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(w, h, d)));
	size_t i = 0;
	for(int z = -1; z <= d; z++){
		for(int y = -1; y <= h; y++){
			for(int x = -1; x <= w; x++){
				if(z == -1 || y == -1 || x == -1 ||
						z == d || y == h || x == w){
					volume.setVoxelAt(x, y, z, VoxelInstance(0));
				} else {
					char c = source_data[i++];
					volume.setVoxelAt(x, y, z, VoxelInstance(c));
				}
			}
		}
	}
	return create_voxel_physics_model(context, volume, voxel_reg);
}

// Set custom geometry from 8-bit voxel data, using a voxel registry
void set_8bit_voxel_geometry(CustomGeometry *cg, Context *context,
		int w, int h, int d, const ss_ &source_data,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg)
{
	if(w < 0 || h < 0 || d < 0)
		throw Exception("Negative dimension");
	if(w * h * d != (int)source_data.size())
		throw Exception("Mismatched data size");
	pv::RawVolume<VoxelInstance> volume(pv::Region(
			pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(w, h, d)));
	size_t i = 0;
	for(int z = -1; z <= d; z++){
		for(int y = -1; y <= h; y++){
			for(int x = -1; x <= w; x++){
				if(z == -1 || y == -1 || x == -1 ||
						z == d || y == h || x == w){
					volume.setVoxelAt(x, y, z, VoxelInstance(0));
				} else {
					char c = source_data[i++];
					volume.setVoxelAt(x, y, z, VoxelInstance(c));
				}
			}
		}
	}

	return set_voxel_geometry(cg, context, volume, voxel_reg, atlas_reg);
}

template<typename VoxelType>
class IsQuadNeededByRegistryPhysics
{
	interface::VoxelRegistry *m_voxel_reg;
	// NOTE: The voxel type id is used directly as PolyVox material value
public:
	IsQuadNeededByRegistryPhysics(interface::VoxelRegistry *voxel_reg):
		m_voxel_reg(voxel_reg)
	{}
	IsQuadNeededByRegistryPhysics(): // PolyVox wants this
		m_voxel_reg(nullptr)
	{}
	bool operator()(VoxelType back, VoxelType front, uint32_t &materialToUse)
	{
		if(m_voxel_reg == nullptr)
			throw Exception("IsQuadNeededByRegistryPhysics not initialized");
		const interface::CachedVoxelDefinition *back_def =
				m_voxel_reg->get_cached(back);
		const interface::CachedVoxelDefinition *front_def =
				m_voxel_reg->get_cached(front);
		if(!back_def)
			throw Exception(ss_()+"Undefined voxel: back="+itos(back.getId()));
		if(!front_def)
			throw Exception(ss_()+"Undefined voxel: front="+itos(front.getId()));
		if(!back_def || !back_def->physically_solid)
			return false;
		if(!front_def || !front_def->physically_solid){
			materialToUse = 1; // Doesn't matter
			return true;
		}
		return false;
	}
};

// Create a model from voxel volume, using a voxel registry, without
// textures or normals, based on the physically_solid flag.
// Volume should be padded by one voxel on each edge
// Returns nullptr if there is no geometry
Model* create_voxel_physics_model(Context *context,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg)
{
	IsQuadNeededByRegistryPhysics<VoxelInstance> iqn(voxel_reg);
	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<pv::RawVolume<VoxelInstance>,
			IsQuadNeededByRegistryPhysics<VoxelInstance>>
	surfaceExtractor(&volume, volume.getEnclosingRegion(), &pv_mesh, iqn);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	const size_t num_vertices = pv_vertices.size();
	const size_t num_indices = pv_indices.size();

	if(num_indices == 0)
		return nullptr;

	int w = volume.getWidth() - 2;
	int h = volume.getHeight() - 2;
	int d = volume.getDepth() - 2;
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

	//sv_<short> index_data;
	sv_<unsigned> index_data;
	index_data.resize(num_indices);
	for(size_t i = 0; i < num_indices; i++){
		/*if(pv_indices[i] >= 0x10000)
		    throw Exception("Index too large");*/
		index_data[i] = pv_indices[i];
	}

	SharedPtr<VertexBuffer> vb(new VertexBuffer(context));
	// Shadowed buffer needed for raycasts to work, and so that data can be
	// automatically restored on device loss
	vb->SetShadowed(true);
	// TODO: Normals are probably unnecessary for a physics model
	vb->SetSize(num_vertices, magic::MASK_POSITION | magic::MASK_NORMAL);
	vb->SetData(&vertex_data[0]);

	SharedPtr<IndexBuffer> ib(new IndexBuffer(context));
	ib->SetShadowed(true);
	//ib->SetSize(num_indices, false);
	ib->SetSize(num_indices, true);
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

template<typename VoxelType>
class IsQuadNeededByRegistry
{
	interface::VoxelRegistry *m_voxel_reg;
	// NOTE: The voxel type id is used directly as PolyVox material value
public:
	IsQuadNeededByRegistry(interface::VoxelRegistry *voxel_reg):
		m_voxel_reg(voxel_reg)
	{}
	IsQuadNeededByRegistry(): // PolyVox wants this
		m_voxel_reg(nullptr)
	{}
	bool operator()(VoxelType back, VoxelType front, uint32_t &materialToUse)
	{
		if(m_voxel_reg == nullptr)
			throw Exception("IsQuadNeededByRegistry not initialized");
		const interface::CachedVoxelDefinition *back_def =
				m_voxel_reg->get_cached(back);
		const interface::CachedVoxelDefinition *front_def =
				m_voxel_reg->get_cached(front);
		if(!back_def)
			throw Exception(ss_()+"Undefined voxel: back="+itos(back.getId()));
		if(!front_def)
			throw Exception(ss_()+"Undefined voxel: front="+itos(front.getId()));
		/*if(!back_def){
		    return false;
		}*/
		else if(back_def->face_draw_type == interface::FaceDrawType::NEVER){
			return false;
		}
		else if(back_def->face_draw_type == interface::FaceDrawType::ALWAYS){
			materialToUse = back.getId();
			return true;
		}
		// interface::FaceDrawType::ON_EDGE
		if(!front_def){
			materialToUse = back.getId();
			return true;
		}
		if(back_def->edge_material_id != front_def->edge_material_id){
			materialToUse = back.getId();
			return true;
		}
		return false;
	}
};

void assign_txcoords(size_t pv_vertex_i1, const AtlasSegmentCache *aseg,
		CustomGeometryVertex &tg_vert)
{
	if(tg_vert.normal_.z_ > 0){
		if(pv_vertex_i1 == 3){
			// Top left (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 1){
			// Top right (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom right (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 2){
			// Bottom left (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		}
	} else if(tg_vert.normal_.x_ > 0){
		if(pv_vertex_i1 == 3){
			// Top right (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 1){
			// Bottom right (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom left (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 2){
			// Top left (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		}
	} else if(tg_vert.normal_.x_ < 0){
		if(pv_vertex_i1 == 1){
			// Bottom left (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 3){
			// Top left (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 2){
			// Top right (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom right (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		}
	} else {
		if(pv_vertex_i1 == 1){
			// Top left (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 3){
			// Top right (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 2){
			// Bottom right (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom left (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		}
	}
}

void preload_textures(pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg)
{
	auto region = volume.getEnclosingRegion();
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();

	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				VoxelInstance v = volume.getVoxelAt(x, y, z);
				const interface::CachedVoxelDefinition *def =
						voxel_reg->get_cached(v, atlas_reg);
				if(!def)
					throw Exception(ss_()+"Undefined voxel: "+itos(v.getId()));
			}
		}
	}
}

void generate_voxel_geometry(sm_<uint, TemporaryGeometry> &result,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg)
{
	IsQuadNeededByRegistry<VoxelInstance> iqn(voxel_reg);
	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<pv::RawVolume<VoxelInstance>,
			IsQuadNeededByRegistry<VoxelInstance>>
	surfaceExtractor(&volume, volume.getEnclosingRegion(), &pv_mesh, iqn);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	int w = volume.getWidth() - 2;
	int h = volume.getHeight() - 2;
	int d = volume.getDepth() - 2;

	// Handle vertices face-by-face in order to copy indices at the same time
	for(size_t pv_face_i = 0; pv_face_i < pv_vertices.size() / 4; pv_face_i++){
		size_t pv_vertex_i0 = pv_face_i * 4;
		VoxelTypeId voxel_id0 = (VoxelTypeId)pv_vertices[pv_vertex_i0].material;
		// We need to get this definition only once per face
		const interface::CachedVoxelDefinition *voxel_def0 =
				voxel_reg->get_cached(voxel_id0);
		if(voxel_def0 == nullptr)
			throw Exception("Unknown voxel in generated geometry: "+
						  itos(voxel_id0));
		// Figure out which face this is
		uint face_id = 0;
		const pv::Vector3DFloat &n = pv_vertices[pv_vertex_i0].normal;
		if(n.getY() > 0)
			face_id = 0;
		else if(n.getY() < 0)
			face_id = 1;
		else if(n.getX() > 0)
			face_id = 2;
		else if(n.getX() < 0)
			face_id = 3;
		else if(n.getZ() > 0)
			face_id = 4;
		else if(n.getZ() < 0)
			face_id = 5;
		// Get texture coordinates (contained in AtlasSegmentCache)
		AtlasSegmentReference seg_ref = voxel_def0->textures[face_id];
		if(seg_ref.atlas_id == interface::ATLAS_UNDEFINED){
			// This is usually intentional for invisible voxels
			//log_t(MODULE, "Voxel %i face %i atlas undefined", voxel_id0, face_id);
			continue;
		}
		const AtlasSegmentCache *aseg = atlas_reg->get_texture(seg_ref);
		if(aseg == nullptr)
			throw Exception("No atlas segment cache for voxel "+itos(voxel_id0)+
						  " face "+itos(face_id));
#if 0
		// TODO: Create a custom Drawable that can use an index buffer
		// Get or create the appropriate temporary geometry for this atlas
		TemporaryGeometry &tg = result[seg_ref.atlas_id];
		if(tg.vertex_data.empty()){
			tg.atlas_id = seg_ref.atlas_id;
			// It can't get larger than these and will only exist temporarily in
			// memory, so let's do only one big memory allocation
			tg.vertex_data.reserve(pv_vertices.size());
			tg.index_data.reserve(pv_indices.size());
		}
		// Mangle vertices into temporary geometry
		size_t dst_vertex_i = tg.vertex_data.size() / 8;
		for(size_t vertex_i1 = 0; vertex_i1 < 4; vertex_i1++){
			size_t vertex_i = pv_vertex_i0 + vertex_i1;
			// Each vertex of the face must be of the same voxel; otherwise the
			// face makes no sense at all
			VoxelTypeId voxel_id = (VoxelTypeId)pv_vertices[pv_vertex_i0].material;
			if(voxel_id != voxel_id0)
				throw Exception("voxel_id != voxel_id0");
			// Add new values to temporary geometry
			const auto &pv_vert = pv_vertices[vertex_i];
			tg.vertex_data.push_back(pv_vert.position.getX() - w/2.0f - 0.5f);
			tg.vertex_data.push_back(pv_vert.position.getY() - h/2.0f - 0.5f);
			tg.vertex_data.push_back(pv_vert.position.getZ() - d/2.0f - 0.5f);
			tg.vertex_data.push_back(pv_vert.normal.getX());
			tg.vertex_data.push_back(pv_vert.normal.getY());
			tg.vertex_data.push_back(pv_vert.normal.getZ());
			tg.vertex_data.push_back(0);
			tg.vertex_data.push_back(0);
		}
		// Mangle indices into temporary geometry
		size_t index_i0 = pv_face_i * 6;
		// First index value from polyvox
		unsigned src_index0_value = pv_indices[index_i0];
		// First index value to be created (NOTE: This relies on the fact that
		// pv::CubicSurfaceExtractorWithNormals always references the first
		// vertex with the first index)
		unsigned dst_index0_value = dst_vertex_i / 4;
		pv_indices[index_i0];
		for(size_t index_i1 = 0; index_i1 < 6; index_i1++){
			size_t index_i = index_i0 + index_i1;
			tg.index_data[dst_vertex_i * 6 + index_i1] =
					pv_indices[index_i] - src_index0_value + dst_index0_value;
		}
#else
		// Get or create the appropriate temporary geometry for this atlas
		TemporaryGeometry &tg = result[seg_ref.atlas_id];
		if(tg.vertex_data.Empty()){
			tg.atlas_id = seg_ref.atlas_id;
			// It can't get larger than this and will only exist temporarily in
			// memory, so let's do only one big memory allocation
			tg.vertex_data.Reserve(pv_vertices.size() / 4 * 6);
		}
		// Go through indices of the face and mangle vertices according to them
		// into the temporary vertex buffer
		size_t pv_index_i0 = pv_face_i * 6;
		for(size_t pv_index_i1 = 0; pv_index_i1 < 6; pv_index_i1++){
			size_t pv_index_i = pv_index_i0 + pv_index_i1;
			size_t pv_vertex_i = pv_indices[pv_index_i];
			if(pv_index_i1 == 0 && pv_vertex_i0 != pv_vertex_i)
				throw Exception("First index of face does not point to first "
							  "vertex of face");
			const auto &pv_vert = pv_vertices[pv_vertex_i];
			tg.vertex_data.Resize(tg.vertex_data.Size() + 1);
			CustomGeometryVertex &tg_vert = tg.vertex_data.Back();
			tg_vert.position_.x_ = pv_vert.position.getX() - w/2.0f - 0.5f;
			tg_vert.position_.y_ = pv_vert.position.getY() - h/2.0f - 0.5f;
			tg_vert.position_.z_ = pv_vert.position.getZ() - d/2.0f - 0.5f;
			tg_vert.normal_.x_ = pv_vert.normal.getX();
			tg_vert.normal_.y_ = pv_vert.normal.getY();
			tg_vert.normal_.z_ = pv_vert.normal.getZ();
			// Figure out texture coordinates
			size_t pv_vertex_i1 = pv_vertex_i - pv_vertex_i0;
			assign_txcoords(pv_vertex_i1, aseg, tg_vert);
		}
#endif
	}
}

void set_voxel_geometry(CustomGeometry *cg, Context *context,
		const sm_<uint, TemporaryGeometry> &temp_geoms,
		AtlasRegistry *atlas_reg)
{
	ResourceCache *cache = context->GetSubsystem<ResourceCache>();

	cg->Clear();

	cg->SetNumGeometries(temp_geoms.size());
	Vector<PODVector<CustomGeometryVertex>> &cg_all_vertices = cg->GetVertices();

	unsigned cg_i = 0;
	for(auto &pair : temp_geoms){
		const TemporaryGeometry &tg = pair.second;
		const AtlasCache *atlas_cache =
				atlas_reg->get_atlas_cache(tg.atlas_id);
		if(atlas_cache == nullptr)
			throw Exception("atlas_cache == nullptr");
		if(atlas_cache->texture == nullptr)
			throw Exception("atlas_cache->texture == nullptr");
		cg->DefineGeometry(cg_i, TRIANGLE_LIST, tg.vertex_data.Size(),
				true, false, true, false);
		PODVector<CustomGeometryVertex> &cg_vertices = cg_all_vertices[cg_i];
		cg_vertices = tg.vertex_data;
		Material *material = new Material(context);
		material->SetTechnique(0,
				cache->GetResource<Technique>("Techniques/Diff.xml"));
		material->SetTexture(TU_DIFFUSE, atlas_cache->texture);
		cg->SetMaterial(cg_i, material);
		cg_i++;
	}

	cg->Commit();
}

// Set custom geometry from voxel volume, using a voxel registry
// Volume should be padded by one voxel on each edge
void set_voxel_geometry(CustomGeometry *cg, Context *context,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg)
{
	preload_textures(volume, voxel_reg, atlas_reg);

	sm_<uint, TemporaryGeometry> temp_geoms;
	generate_voxel_geometry(temp_geoms, volume, voxel_reg, atlas_reg);

	set_voxel_geometry(cg, context, temp_geoms, atlas_reg);
}

up_<pv::RawVolume<VoxelInstance>> generate_voxel_lod_volume(
		int lod, pv::RawVolume<VoxelInstance>&volume_orig)
{
	pv::Region region_orig = volume_orig.getEnclosingRegion();
	auto &lc_orig = region_orig.getLowerCorner();
	auto &uc_orig = region_orig.getUpperCorner();

	pv::Region region(lc_orig / lod - pv::Vector3DInt32(1, 1, 1),
		uc_orig / lod + pv::Vector3DInt32(1, 1, 1));
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();

	up_<pv::RawVolume<VoxelInstance>> volume(
			new pv::RawVolume<VoxelInstance>(region));
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				VoxelInstance v_orig(interface::VOXELTYPEID_UNDEFINED);
				for(int x1 = 0; x1 < lod; x1++){
					for(int y1 = 0; y1 < lod; y1++){
						for(int z1 = 0; z1 < lod; z1++){
							pv::Vector3DInt32 p_orig(
									x * lod + x1,
									y * lod + y1,
									z * lod + z1
							);
							if(!region_orig.containsPoint(p_orig))
								continue;
							VoxelInstance v1 = volume_orig.getVoxelAt(p_orig);
							if(v1.getId() == interface::VOXELTYPEID_UNDEFINED)
								continue;
							// TODO: Prioritize voxel types better
							// Higher is probably more interesting
							if(v1.getId() > v_orig.getId())
								v_orig = v1;
						}
					}
				}
				volume->setVoxelAt(x, y, z, v_orig);
			}
		}
	}
	return volume;
}

// Can be called from any thread
void generate_voxel_lod_geometry(int lod,
		sm_<uint, TemporaryGeometry> &result,
		pv::RawVolume<VoxelInstance> &lod_volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg)
{
	IsQuadNeededByRegistry<VoxelInstance> iqn(voxel_reg);
	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<pv::RawVolume<VoxelInstance>,
			IsQuadNeededByRegistry<VoxelInstance>>
	surfaceExtractor(&lod_volume, lod_volume.getEnclosingRegion(), &pv_mesh, iqn);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	int w = (lod_volume.getWidth() - 2) * lod - 2;
	int h = (lod_volume.getHeight() - 2) * lod - 2;
	int d = (lod_volume.getDepth() - 2) * lod - 2;

	// Handle vertices face-by-face in order to copy indices at the same time
	for(size_t pv_face_i = 0; pv_face_i < pv_vertices.size() / 4; pv_face_i++){
		size_t pv_vertex_i0 = pv_face_i * 4;
		VoxelTypeId voxel_id0 = (VoxelTypeId)pv_vertices[pv_vertex_i0].material;
		// We need to get this definition only once per face
		const interface::CachedVoxelDefinition *voxel_def0 =
				voxel_reg->get_cached(voxel_id0);
		if(voxel_def0 == nullptr)
			throw Exception("Unknown voxel in generated geometry: "+
						  itos(voxel_id0));
		// Figure out which face this is
		uint face_id = 0;
		const pv::Vector3DFloat &n = pv_vertices[pv_vertex_i0].normal;
		if(n.getY() > 0)
			face_id = 0;
		else if(n.getY() < 0)
			face_id = 1;
		else if(n.getX() > 0)
			face_id = 2;
		else if(n.getX() < 0)
			face_id = 3;
		else if(n.getZ() > 0)
			face_id = 4;
		else if(n.getZ() < 0)
			face_id = 5;
		// Get texture coordinates (contained in AtlasSegmentCache)
		size_t lod_i = lod - 2;
		if(lod_i >= interface::VOXELDEF_NUM_LOD)
			lod_i = interface::VOXELDEF_NUM_LOD - 1;
		AtlasSegmentReference seg_ref = voxel_def0->lod_textures[lod_i][face_id];
		if(seg_ref.atlas_id == interface::ATLAS_UNDEFINED){
			// This is usually intentional for invisible voxels
			//log_t(MODULE, "Voxel %i face %i atlas undefined", voxel_id0, face_id);
			continue;
		}
		const AtlasSegmentCache *aseg = atlas_reg->get_texture(seg_ref);
		if(aseg == nullptr)
			throw Exception("No atlas segment cache for voxel "+itos(voxel_id0)+
						  " face "+itos(face_id));
		// Get or create the appropriate temporary geometry for this atlas
		TemporaryGeometry &tg = result[seg_ref.atlas_id];
		if(tg.vertex_data.Empty()){
			tg.atlas_id = seg_ref.atlas_id;
			// It can't get larger than this and will only exist temporarily in
			// memory, so let's do only one big memory allocation
			tg.vertex_data.Reserve(pv_vertices.size() / 4 * 6);
		}
		// Go through indices of the face and mangle vertices according to them
		// into the temporary vertex buffer
		size_t pv_index_i0 = pv_face_i * 6;
		for(size_t pv_index_i1 = 0; pv_index_i1 < 6; pv_index_i1++){
			size_t pv_index_i = pv_index_i0 + pv_index_i1;
			size_t pv_vertex_i = pv_indices[pv_index_i];
			if(pv_index_i1 == 0 && pv_vertex_i0 != pv_vertex_i)
				throw Exception("First index of face does not point to first "
							  "vertex of face");
			const auto &pv_vert = pv_vertices[pv_vertex_i];
			tg.vertex_data.Resize(tg.vertex_data.Size() + 1);
			CustomGeometryVertex &tg_vert = tg.vertex_data.Back();
			tg_vert.position_.x_ = pv_vert.position.getX() * lod
					- w/2.0f - 1.0f - lod/2.0f;
			tg_vert.position_.y_ = pv_vert.position.getY() * lod
					- h/2.0f - 1.0f - lod/2.0f;
			tg_vert.position_.z_ = pv_vert.position.getZ() * lod
					- d/2.0f - 1.0f - lod/2.0f;
			// Set real normal temporarily for assign_txcoords().
			tg_vert.normal_.x_ = pv_vert.normal.getX();
			tg_vert.normal_.y_ = pv_vert.normal.getY();
			tg_vert.normal_.z_ = pv_vert.normal.getZ();
			// Figure out texture coordinates
			size_t pv_vertex_i1 = pv_vertex_i - pv_vertex_i0;
			assign_txcoords(pv_vertex_i1, aseg, tg_vert);
			// Don't use the real normal.
			// Constant bright shading is needed so that the look of multiple
			// shaded faces can be emulated by using textures. This normal
			// should give it to us.
			// Note that this normal isn't actually exactly correct: It should
			// be the normal that points to the main light source of the scene;
			// however, it is close enough.
			// We can't turn off lighting for this geometry, because then we
			// don't get shadows, which we do want.
			tg_vert.normal_.x_ = 0;
			tg_vert.normal_.y_ = 1;
			tg_vert.normal_.z_ = 0;
		}
	}
}

void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
		const sm_<uint, TemporaryGeometry> &temp_geoms,
		AtlasRegistry *atlas_reg)
{
	ResourceCache *cache = context->GetSubsystem<ResourceCache>();

	cg->Clear();

	cg->SetNumGeometries(temp_geoms.size());
	Vector<PODVector<CustomGeometryVertex>> &cg_all_vertices = cg->GetVertices();

	unsigned cg_i = 0;
	for(auto &pair : temp_geoms){
		const TemporaryGeometry &tg = pair.second;
		const AtlasCache *atlas_cache =
				atlas_reg->get_atlas_cache(tg.atlas_id);
		if(atlas_cache == nullptr)
			throw Exception("atlas_cache == nullptr");
		if(atlas_cache->texture == nullptr)
			throw Exception("atlas_cache->texture == nullptr");
		cg->DefineGeometry(cg_i, TRIANGLE_LIST, tg.vertex_data.Size(),
				true, false, true, false);
		PODVector<CustomGeometryVertex> &cg_vertices = cg_all_vertices[cg_i];
		cg_vertices = tg.vertex_data;
		Material *material = new Material(context);
		if(lod <= interface::MAX_LOD_WITH_SHADOWS){
			material->SetTechnique(0,
					cache->GetResource<Technique>("Techniques/Diff.xml"));
		} else {
			material->SetTechnique(0,
					cache->GetResource<Technique>("Techniques/DiffUnlit.xml"));
		}
		material->SetTexture(TU_DIFFUSE, atlas_cache->texture);
		cg->SetMaterial(cg_i, material);
		cg_i++;
	}

	cg->Commit();
}

// Set custom geometry from voxel volume, using a voxel registry
// Volume should be padded by one voxel on each edge
void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
		pv::RawVolume<VoxelInstance> &volume_orig,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg)
{
	up_<pv::RawVolume<VoxelInstance>> lod_volume = generate_voxel_lod_volume(
			lod, volume_orig);

	preload_textures(*lod_volume, voxel_reg, atlas_reg);

	sm_<uint, TemporaryGeometry> temp_geoms;
	generate_voxel_lod_geometry(
			lod, temp_geoms, *lod_volume, voxel_reg, atlas_reg);

	set_voxel_lod_geometry(lod, cg, context, temp_geoms, atlas_reg);
}

void generate_voxel_physics_boxes(
		sv_<TemporaryBox> &result_boxes,
		pv::RawVolume<VoxelInstance> &volume_orig,
		VoxelRegistry *voxel_reg)
{
	int w = volume_orig.getWidth() - 2;
	int h = volume_orig.getHeight() - 2;
	int d = volume_orig.getDepth() - 2;

	auto region = volume_orig.getEnclosingRegion();
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();

	// Create a new volume which only holds the solidity of the voxels
	pv::RawVolume<uint8_t> volume(region);
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				VoxelInstance v_orig = volume_orig.getVoxelAt(x, y, z);
				const interface::CachedVoxelDefinition *def =
						voxel_reg->get_cached(v_orig);
				if(!def)
					throw Exception(ss_()+"Undefined voxel: "+itos(v_orig.getId()));
				uint8_t v = (def && def->physically_solid);
				volume.setVoxelAt(x, y, z, v);
			}
		}
	}

	// Create minimal number of boxes to fill the solid voxels. Boxes can
	// overlap. When a box is added, its voxels are set to value 2 in the
	// temporary volume.

	for(int z0 = lc.getZ(); z0 <= uc.getZ(); z0++){
		// Loop until this z0 plane is done, then handle the next one
		for(;;){
			// Find a solid non-covered voxel (v=1) on the z0 plane
			int x0 = INT_MAX;
			int y0 = INT_MAX;
			for(int x = lc.getX(); x <= uc.getX(); x++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					uint8_t v = volume.getVoxelAt(x, y, z0);
					if(v == 1){
						x0 = x;
						y0 = y;
						goto found_non_covered_voxel;
					}
				}
			}
			break; // Done
found_non_covered_voxel:
			// Stretch this box first in x, then y and then z to be as large as
			// possible without covering any non-solid voxels
			int x1 = x0;
			int y1 = y0;
			int z1 = z0;
			for(;;){
				x1++;
				for(int y = y0; y <= y1; y++){
					for(int z = z0; z <= z1; z++){
						uint8_t v = volume.getVoxelAt(x1, y, z);
						if(v == 0)
							goto x_plane_does_not_fit;
					}
				}
				continue; // Fits
x_plane_does_not_fit:
				x1--;
				break;
			}
			for(;;){
				y1++;
				for(int x = x0; x <= x1; x++){
					for(int z = z0; z <= z1; z++){
						uint8_t v = volume.getVoxelAt(x, y1, z);
						if(v == 0)
							goto y_plane_does_not_fit;
					}
				}
				continue; // Fits
y_plane_does_not_fit:
				y1--;
				break;
			}
			for(;;){
				z1++;
				for(int x = x0; x <= x1; x++){
					for(int y = y0; y <= y1; y++){
						uint8_t v = volume.getVoxelAt(x, y, z1);
						if(v == 0)
							goto z_plane_does_not_fit;
					}
				}
				continue; // Fits
z_plane_does_not_fit:
				z1--;
				break;
			}
			// Now we have a box; set the voxels to 2
			for(int x = x0; x <= x1; x++){
				for(int y = y0; y <= y1; y++){
					for(int z = z0; z <= z1; z++){
						volume.setVoxelAt(x, y, z, 2);
					}
				}
			}
			// Store the box in results
			TemporaryBox box;
			box.size = Vector3(
					x1 - x0 + 1,
					y1 - y0 + 1,
					z1 - z0 + 1
			);
			box.position = Vector3(
					(x0 + x1)/2.0f - w/2 - 0.5f,
					(y0 + y1)/2.0f - h/2 - 0.5f,
					(z0 + z1)/2.0f - d/2 - 0.5f
			);
			result_boxes.push_back(box);
		}
	}
}

void set_voxel_physics_boxes(Node *node, Context *context,
		const sv_<TemporaryBox> &boxes, bool do_update_mass)
{
	// Get previous shapes
	PODVector<CollisionShape*> previous_shapes;
	node->GetComponents<CollisionShape>(previous_shapes);
	// Number of previous shapes reused
	// (they are reused because deleting them is very expensive)
	size_t num_shapes_reused = 0;

	// Do this. Otherwise modifying CollisionShapes causes a massive CPU waste
	// when they call RigidBody::UpdateMass().
	RigidBody *body = node->GetComponent<RigidBody>();
	if(body)
		body->ReleaseBody();

	// Create the boxes (reuse previous shapes if possible)
	for(auto &box : boxes){
		CollisionShape *shape = nullptr;
		if(num_shapes_reused < previous_shapes.Size())
			shape = previous_shapes[num_shapes_reused++];
		else
			shape = node->CreateComponent<CollisionShape>(LOCAL);
		shape->SetBox(box.size);
		shape->SetPosition(box.position);
	}

	// Remove excess shapes
	for(size_t i = num_shapes_reused; i < previous_shapes.Size(); i++){
		node->RemoveComponent(previous_shapes[i]);
	}

	if(body && do_update_mass){
		// Call this to cause the private AddBodyToWorld() to be called, which
		// re-creates the internal btRigidBody and also calls UpdateMass()
		body->OnSetEnabled();
	}
}

void set_voxel_physics_boxes(Node *node, Context *context,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg)
{
	sv_<TemporaryBox> result_boxes;
	generate_voxel_physics_boxes(result_boxes, volume, voxel_reg);

	set_voxel_physics_boxes(node, context, result_boxes, true);
}

} // namespace mesh
} // namespace interface
// vim: set noet ts=4 sw=4:
