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
#include <Model.h>	// Resource parameter of StaticModel
#include <Geometry.h>
#include <IndexBuffer.h>
#include <VertexBuffer.h>
#include <CustomGeometry.h>	// A Drawable similarly as StaticModel
#include <Material.h>
#include <Technique.h>
#include <Context.h>
#include <ResourceCache.h>
#include <Texture2D.h>	// Allows cast to Texture
#pragma GCC diagnostic pop
#define MODULE "mesh"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::VoxelInstance;

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace interface {

// Create a model from a string; eg. (2, 2, 2, "11101111")
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
	for(int z = 0; z < d; z++){
		for(int y = 0; y < h; y++){
			for(int x = 0; x < w; x++){
				char c = source_data[i++];
				volData.setVoxelAt(x, y, z, c == '0' ? 0 : 255);
			}
		}
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
	vertex_data.resize(num_vertices * 6);	// vertex + normal
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

template<typename VoxelType>
class IsQuadNeededByRegistryPhysics
{
	interface::VoxelRegistry *m_voxel_reg;
	// NOTE: The voxel type id is used directly as PolyVox material value
public:
	IsQuadNeededByRegistryPhysics(interface::VoxelRegistry *voxel_reg):
		m_voxel_reg(voxel_reg)
	{}
	IsQuadNeededByRegistryPhysics():// PolyVox wants this
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
		if(!back_def || !back_def->physically_solid)
			return false;
		if(!front_def || !front_def->physically_solid){
			materialToUse = 1;	// Doesn't matter
			return true;
		}
		return false;
	}
};

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
	pv::SimpleVolume<uint8_t> volData(pv::Region(
			pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(w, h, d)));
	size_t i = 0;
	for(int z = 0; z < d; z++){
		for(int y = 0; y < h; y++){
			for(int x = 0; x < w; x++){
				char c = source_data[i++];
				volData.setVoxelAt(x, y, z, c);
			}
		}
	}

	IsQuadNeededByRegistryPhysics<uint8_t> iqn(voxel_reg);
	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<
	pv::SimpleVolume<uint8_t>, IsQuadNeededByRegistryPhysics<uint8_t>>
	surfaceExtractor(&volData, volData.getEnclosingRegion(), &pv_mesh, iqn);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	const size_t num_vertices = pv_vertices.size();
	const size_t num_indices = pv_indices.size();

	sv_<float> vertex_data;
	vertex_data.resize(num_vertices * 6);	// vertex + normal
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
	IsQuadNeededByRegistry():	// PolyVox wants this
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
		if(!back_def){
			log_t(MODULE, "back=%i: Definition not found", back);
			return false;
		}
		else if(back_def->face_draw_type == interface::FaceDrawType::NEVER){
			log_t(MODULE, "back=%i: FaceDrawType::NEVER", back);
			return false;
		}
		else if(back_def->face_draw_type == interface::FaceDrawType::ALWAYS){
			log_t(MODULE, "back=%i: FaceDrawType::ALWAYS", back);
			materialToUse = back;
			return true;
		}
		// interface::FaceDrawType::ON_EDGE
		if(!front_def){
			log_t(MODULE, "back=%i: FaceDrawType::ON_EDGE; front undef", back);
			materialToUse = back;
			return true;
		}
		if(back_def->edge_material_id != front_def->edge_material_id){
			log_t(MODULE, "back=%i: FaceDrawType::ON_EDGE; edge m. diff", back);
			materialToUse = back;
			return true;
		}
		log_t(MODULE, "back=%i: FaceDrawType::ON_EDGE; edge same m.", back);
		return false;
	}
};

#if 0
// TODO: Create a custom Drawable that can use an index buffer
struct TemporaryGeometry
{
	uint atlas_id = 0;
	sv_<float> vertex_data;	// vertex(3) + normal(3) + texcoord(2)
	sv_<unsigned> index_data;	// Urho3D eats unsigned as large indices
};
#else
struct TemporaryGeometry
{
	uint atlas_id = 0;
	// CustomGeometry can't handle an index buffer
	PODVector<CustomGeometryVertex> vertex_data;
};
#endif

// Set custom geometry from 8-bit voxel data, using a voxel registry
void set_8bit_voxel_geometry(CustomGeometry *cg, Context *context,
		int w, int h, int d, const ss_ &source_data,
		VoxelRegistry *voxel_reg)
{
	if(w < 0 || h < 0 || d < 0)
		throw Exception("Negative dimension");
	if(w * h * d != (int)source_data.size())
		throw Exception("Mismatched data size");
	pv::SimpleVolume<uint8_t> volData(pv::Region(
			pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(w, h, d)));
	size_t i = 0;
	for(int z = 0; z < d; z++){
		for(int y = 0; y < h; y++){
			for(int x = 0; x < w; x++){
				char c = source_data[i++];
				volData.setVoxelAt(x, y, z, c);
			}
		}
	}

	IsQuadNeededByRegistry<uint8_t> iqn(voxel_reg);
	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<
	pv::SimpleVolume<uint8_t>, IsQuadNeededByRegistry<uint8_t>>
	surfaceExtractor(&volData, volData.getEnclosingRegion(), &pv_mesh, iqn);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	sm_<uint, TemporaryGeometry> temp_geoms;

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
			log_t(MODULE, "Voxel %i face %i atlas undefined", voxel_id0, face_id);
			continue;
		}
		const AtlasSegmentCache *aseg =
				voxel_reg->get_atlas()->get_texture(seg_ref);
		if(aseg == nullptr)
			throw Exception("No atlas segment cache for voxel "+itos(voxel_id0)+
						  " face "+itos(face_id));
#if 0
// TODO: Create a custom Drawable that can use an index buffer
		// Get or create the appropriate temporary geometry for this atlas
		TemporaryGeometry &tg = temp_geoms[seg_ref.atlas_id];
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
		TemporaryGeometry &tg = temp_geoms[seg_ref.atlas_id];
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
			if(pv_vertex_i1 == 0){
				tg_vert.texCoord_.x_ = aseg->coord0.x_;
				tg_vert.texCoord_.y_ = aseg->coord1.y_;
			} else if(pv_vertex_i1 == 1){
				tg_vert.texCoord_.x_ = aseg->coord1.x_;
				tg_vert.texCoord_.y_ = aseg->coord1.y_;
			} else if(pv_vertex_i1 == 2){
				tg_vert.texCoord_.x_ = aseg->coord0.x_;
				tg_vert.texCoord_.y_ = aseg->coord0.y_;
			} else if(pv_vertex_i1 == 3){
				tg_vert.texCoord_.x_ = aseg->coord1.x_;
				tg_vert.texCoord_.y_ = aseg->coord0.y_;
			}
		}
#endif
	}

	// Generate CustomGeometry from TemporaryGeometry

	ResourceCache *cache = context->GetSubsystem<ResourceCache>();

	cg->SetNumGeometries(temp_geoms.size());
	Vector<PODVector<CustomGeometryVertex>> &cg_all_vertices = cg->GetVertices();

	unsigned cg_i = 0;
	for(auto &pair : temp_geoms){
		const TemporaryGeometry &tg = pair.second;
		const TextureAtlasCache *atlas_cache =
				voxel_reg->get_atlas()->get_atlas_cache(tg.atlas_id);
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

// Create a model from voxel volume, using a voxel registry, without
// textures or normals, based on the physically_solid flag.
Model* create_voxel_physics_model(Context *context,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg)
{
	IsQuadNeededByRegistryPhysics<VoxelInstance> iqn(voxel_reg);
	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	pv::CubicSurfaceExtractorWithNormals<
	pv::RawVolume<VoxelInstance>, IsQuadNeededByRegistryPhysics<VoxelInstance>>
	surfaceExtractor(&volume, volume.getEnclosingRegion(), &pv_mesh, iqn);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	const size_t num_vertices = pv_vertices.size();
	const size_t num_indices = pv_indices.size();

	int w = volume.getWidth();
	int h = volume.getHeight();
	int d = volume.getDepth();
	sv_<float> vertex_data;
	vertex_data.resize(num_vertices * 6);	// vertex + normal
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

// Set custom geometry from voxel volume, using a voxel registry
void set_voxel_geometry(CustomGeometry *cg, Context *context,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg)
{
	// TODO
}

}	// namespace interface
// vim: set noet ts=4 sw=4:
