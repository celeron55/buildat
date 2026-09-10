// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "core/log.h"
#include <PolyVoxCore/SimpleVolume.h>
#include <PolyVoxCore/SurfaceMesh.h>
#include <PolyVoxCore/CubicSurfaceExtractorWithNormals.h>
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
#include <climits>
#include <cmath>
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
				VoxelInstance v(0);
				if(!(z == -1 || y == -1 || x == -1 ||
						z == d || y == h || x == w))
					v = VoxelInstance(source_data[i++]);
				// 8 bit data has no room for a light value, and this is a
				// model standing on its own rather than a piece of a world
				// that could light it, so it is lit as if it were out in the
				// open. Handing a voxel shader no light at all is not the
				// safe choice it looks like: with the ambient term zeroed,
				// what is left is the reflection, and every texel of the
				// derived normal map then reflects the sky in its own
				// direction, which comes out as speckle.
				v.set_skylight(VoxelInstance::SKYLIGHT_MAX);
				volume.setVoxelAt(x, y, z, v);
			}
		}
	}

	return set_voxel_geometry(cg, context, volume, voxel_reg, atlas_reg, true);
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
			throw Exception(ss_()+"Undefined voxel: back="+itos(back.get_id()));
		if(!front_def)
			throw Exception(ss_()+"Undefined voxel: front="+itos(front.get_id()));
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
			throw Exception(ss_()+"Undefined voxel: back="+itos(back.get_id()));
		if(!front_def)
			throw Exception(ss_()+"Undefined voxel: front="+itos(front.get_id()));
		/*if(!back_def){
			return false;
		}*/
		else if(back_def->face_draw_type == interface::FaceDrawType::NEVER){
			return false;
		}
		else if(back_def->face_draw_type == interface::FaceDrawType::ALWAYS){
			materialToUse = back.get_id();
			return true;
		}
		// interface::FaceDrawType::ON_EDGE
		if(!front_def){
			materialToUse = back.get_id();
			return true;
		}
		if(back_def->edge_material_id != front_def->edge_material_id){
			materialToUse = back.get_id();
			return true;
		}
		return false;
	}
};

// PolyVox extracts the faces of the padding voxels too, and a padding voxel's
// face pointing into the chunk is the same surface that the neighbouring chunk
// draws for its own voxel. Drawing both leaves a doubled, z-fighting layer
// along every chunk boundary, so faces owned by the padding are dropped. The
// face belongs to the voxel half a voxel behind it, against the normal.
static bool face_owned_by_padding(pv::RawVolume<VoxelInstance> &volume,
		const pv::Vector3DFloat *quad, const pv::Vector3DFloat &n)
{
	pv::Vector3DFloat centre(0, 0, 0);
	for(size_t i = 0; i < 4; i++)
		centre += quad[i];
	centre /= 4.0f;
	const pv::Region &region = volume.getEnclosingRegion();
	const pv::Vector3DInt32 lc = region.getLowerCorner();
	const pv::Vector3DInt32 uc = region.getUpperCorner();
	pv::Vector3DInt32 back(
			lc.getX() + (int)std::floor(centre.getX() - n.getX()*0.5f + 0.5f),
			lc.getY() + (int)std::floor(centre.getY() - n.getY()*0.5f + 0.5f),
			lc.getZ() + (int)std::floor(centre.getZ() - n.getZ()*0.5f + 0.5f));
	return back.getX() <= lc.getX() || back.getX() >= uc.getX() ||
			back.getY() <= lc.getY() || back.getY() >= uc.getY() ||
			back.getZ() <= lc.getZ() || back.getZ() >= uc.getZ();
}

// Vertex colors for skylit voxel geometry, decoded by a voxel shader as
//   ambient = cAmbientColor.rgb * color.a + color.rgb
// The zone's ambient color is the sky, so a world picks that itself; what is
// carried here is how much of the sky the surface sees, and the light bounced
// off nearby surfaces that reaches it regardless.
//
// The bounce color is a property of the rock and dirt a voxel world is made
// of, so it lives here rather than in a world's settings. It is close to
// neutral, which is what makes a cave read as grey while a face that is merely
// shaded from the sun keeps the sky's blue.
static const Color BOUNCE_COLOR(0.055f, 0.050f, 0.045f);

// What a voxel's lamplight looks like at full strength. White, because a lamp
// is as bright as a world says it is and its color belongs in the texture of
// whatever is emitting it; a world that wants warmer torches gives them a
// warmer texture. This is added to the vertex color's rgb, next to the bounce
// term, so a shader following the contract in interface/mesh.h needs to know
// nothing about it.
static const Color LAMP_COLOR(1.0f, 1.0f, 1.0f);

// Per-face brightness, for legibility rather than for physics: two faces of a
// voxel that happen to receive the same light have no visible edge between
// them, which in shadow is most of them. Top is brightest and bottom darkest,
// and the four sides are spread either side of 1.0 so that no two faces
// meeting at an edge carry the same value. Indexed by face_id: +Y -Y +X -X +Z -Z.
static const float FACE_SHADE[6] = {
	1.15f, 0.80f, 1.00f, 0.90f, 0.95f, 0.85f
};

// Ambient occlusion, indexed by the number of the three voxels around a quad
// corner that are solid. Applied to ambient only, which is where it is
// visible: a face in direct sun is shaped by the sun, not by this.
static const float AO_LEVELS[4] = {1.0f, 0.72f, 0.52f, 0.38f};

// How much of that occlusion the bounce term takes. Occlusion is a statement
// about how much of the sky a corner can see, which is the wrong question to
// ask about light that came off the surrounding surfaces in the first place:
// inside a cave there is no sky to occlude, and taking it at full strength
// there darkens every pocket until the corners that stick out into the cave
// are the brightest thing in it.
static const float BOUNCE_AO = 0.70f;

static bool occludes(pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, const pv::Vector3DInt32 &p)
{
	VoxelInstance v = volume.getVoxelAt(p);
	if(v.get_id() == interface::VOXELTYPEID_UNDEFINED)
		return false; // Unfilled chunk padding; assume open
	const interface::CachedVoxelDefinition *def = voxel_reg->get_cached(v);
	if(def == nullptr)
		return false;
	return def->edge_material_id != interface::EDGEMATERIALID_EMPTY;
}

// One color per corner of a quad. PolyVox vertex positions are region-relative
// and sit on voxel corners, so the average of a quad's four corners is the face
// center; half a voxel along the normal lands in the voxel the face looks into,
// and half a voxel against it in the solid voxel behind it.
//
// Chunk volumes are padded by one voxel, which the world fills from the chunks
// next to it. It cannot always: a neighbour that is not in memory leaves its
// side undefined. Those faces fall back to the skylight of the solid voxel,
// which the world stores as a per-voxel approximation for exactly this case.
static void face_vertex_colors(pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, const pv::Vector3DFloat *quad,
		const pv::Vector3DFloat &n, uint face_id, unsigned out[4])
{
	pv::Vector3DFloat centre(0, 0, 0);
	for(size_t i = 0; i < 4; i++)
		centre += quad[i];
	centre /= 4.0f;

	const pv::Vector3DInt32 vlc = volume.getEnclosingRegion().getLowerCorner();
	auto voxel_at = [&](float s){
		return pv::Vector3DInt32(
				vlc.getX() + (int)std::floor(centre.getX() + n.getX()*s + 0.5f),
				vlc.getY() + (int)std::floor(centre.getY() + n.getY()*s + 0.5f),
				vlc.getZ() + (int)std::floor(centre.getZ() + n.getZ()*s + 0.5f));
	};
	const pv::Vector3DInt32 front_p = voxel_at(0.5f);
	VoxelInstance front = volume.getVoxelAt(front_p);
	VoxelInstance lit = front.get_id() == interface::VOXELTYPEID_UNDEFINED ?
			volume.getVoxelAt(voxel_at(-0.5f)) : front;
	float sky_f = (float)lit.get_skylight() / VoxelInstance::SKYLIGHT_MAX;
	float lamp_f = (float)lit.get_lamplight() / VoxelInstance::LAMPLIGHT_MAX;

	// The two axes of the face's own plane, to step around it in
	pv::Vector3DInt32 u(0, 1, 0), v(0, 0, 1);
	if(n.getY() != 0){
		u = pv::Vector3DInt32(1, 0, 0);
		v = pv::Vector3DInt32(0, 0, 1);
	} else if(n.getZ() != 0){
		u = pv::Vector3DInt32(1, 0, 0);
		v = pv::Vector3DInt32(0, 1, 0);
	}
	auto along = [&](const pv::Vector3DFloat &d, const pv::Vector3DInt32 &axis){
		float c = d.getX()*axis.getX() + d.getY()*axis.getY() +
				d.getZ()*axis.getZ();
		return c < 0 ? -1 : 1;
	};

	for(size_t i = 0; i < 4; i++){
		pv::Vector3DFloat d = quad[i] - centre;
		pv::Vector3DInt32 du = u * along(d, u);
		pv::Vector3DInt32 dv = v * along(d, v);
		bool s1 = occludes(volume, voxel_reg, front_p + du);
		bool s2 = occludes(volume, voxel_reg, front_p + dv);
		// Two solid sides bury the corner whatever is diagonally behind it
		int occluders = (s1 && s2) ? 3 : (s1 ? 1 : 0) + (s2 ? 1 : 0) +
				(occludes(volume, voxel_reg, front_p + du + dv) ? 1 : 0);
		float ao = AO_LEVELS[occluders];
		float sky_shade = ao * FACE_SHADE[face_id];
		float bounce_shade = (1.0f - BOUNCE_AO + BOUNCE_AO * ao) *
				FACE_SHADE[face_id] * (1.0f - sky_f);
		float lamp_shade = lamp_f * sky_shade;
		out[i] = Color(
				BOUNCE_COLOR.r_ * bounce_shade + LAMP_COLOR.r_ * lamp_shade,
				BOUNCE_COLOR.g_ * bounce_shade + LAMP_COLOR.g_ * lamp_shade,
				BOUNCE_COLOR.b_ * bounce_shade + LAMP_COLOR.b_ * lamp_shade,
				sky_f * sky_shade).ToUInt();
	}
}

// The texture turned inside its own face, which is what
// VoxelDefinition::tile_turns asks for. In the segment's own 0...1 space a
// quarter turn is (s, t) -> (1 - t, s), which is what Luanti does to a tile
// with a rotation -- it lets the coordinates go negative and leans on the
// texture wrapping, where an atlas segment has to stay inside its own box.
static void turn_txcoord(const AtlasSegmentCache *aseg, uint8_t turns,
		CustomGeometryVertex &tg_vert)
{
	turns &= 3;
	if(turns == 0)
		return;
	const float w = aseg->coord1.x_ - aseg->coord0.x_;
	const float h = aseg->coord1.y_ - aseg->coord0.y_;
	if(w == 0.0f || h == 0.0f)
		return;
	float s = (tg_vert.texCoord_.x_ - aseg->coord0.x_) / w;
	float t = (tg_vert.texCoord_.y_ - aseg->coord0.y_) / h;
	for(uint8_t i = 0; i < turns; i++){
		const float s0 = s;
		s = 1.0f - t;
		t = s0;
	}
	tg_vert.texCoord_.x_ = aseg->coord0.x_ + s * w;
	tg_vert.texCoord_.y_ = aseg->coord0.y_ + t * h;
}

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
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg, bool with_lod)
{
	auto region = volume.getEnclosingRegion();
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();

	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				VoxelInstance v = volume.getVoxelAt(x, y, z);
				const interface::CachedVoxelDefinition *def =
						voxel_reg->get_cached(v, atlas_reg, with_lod);
				if(!def)
					throw Exception(ss_()+"Undefined voxel: "+itos(v.get_id()));
			}
		}
	}
}

static void generate_voxel_shapes(sm_<uint, TemporaryGeometry> &result,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result);

void generate_voxel_geometry(sm_<uint, TemporaryGeometry> &result,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result)
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
		sm_<uint, TemporaryGeometry> &into =
				(translucent_result && voxel_def0->translucent) ?
				*translucent_result : result;
		TemporaryGeometry &tg = into[seg_ref.atlas_id];
		if(tg.vertex_data.Empty()){
			tg.atlas_id = seg_ref.atlas_id;
			tg.has_colors = use_skylight;
			// It can't get larger than this and will only exist temporarily in
			// memory, so let's do only one big memory allocation
			tg.vertex_data.Reserve(pv_vertices.size() / 4 * 6);
		}
		pv::Vector3DFloat quad[4] = {
			pv_vertices[pv_vertex_i0 + 0].position,
			pv_vertices[pv_vertex_i0 + 1].position,
			pv_vertices[pv_vertex_i0 + 2].position,
			pv_vertices[pv_vertex_i0 + 3].position,
		};
		if(face_owned_by_padding(volume, quad, n))
			continue;
		unsigned corner_colors[4] = {
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff
		};
		if(use_skylight){
			face_vertex_colors(volume, voxel_reg, quad, n, face_id,
					corner_colors);
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
			turn_txcoord(aseg, voxel_def0->tile_turns[face_id], tg_vert);
			tg_vert.color_ = corner_colors[pv_vertex_i1];
		}
#endif
	}

	generate_voxel_shapes(result, volume, voxel_reg, atlas_reg, use_skylight,
			translucent_result);
}

// The quads of the voxels that have a shape of their own, appended to the
// same temporary geometry the cubes went into.
//
// A voxel's quads are copied as they are, with the voxel's position added and
// the texture coordinates mapped into wherever the atlas put the tile. That
// is the whole point of shapes living in the voxel registry: a chunk full of
// stairs and fences costs what a chunk of cubes costs, where a scene node per
// stair would not.
//
// Only the voxels inside the chunk are drawn. The padding belongs to the
// neighbouring chunks, which draw it themselves; the padding is here so that
// the cube faces can be culled against it.
static void generate_voxel_shapes(sm_<uint, TemporaryGeometry> &result,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result)
{
	const pv::Region &region = volume.getEnclosingRegion();
	const pv::Vector3DInt32 lc = region.getLowerCorner();
	const pv::Vector3DInt32 uc = region.getUpperCorner();
	const float w = volume.getWidth() - 2;
	const float h = volume.getHeight() - 2;
	const float d = volume.getDepth() - 2;

	for(int z = lc.getZ() + 1; z <= uc.getZ() - 1; z++){
		for(int y = lc.getY() + 1; y <= uc.getY() - 1; y++){
			for(int x = lc.getX() + 1; x <= uc.getX() - 1; x++){
				VoxelInstance v = volume.getVoxelAt(x, y, z);
				const interface::CachedVoxelDefinition *def =
						voxel_reg->get_cached(v);
				if(def == nullptr || def->shape.empty())
					continue;
				// Where this voxel's centre is in the chunk's own model
				// coordinates; the same arithmetic the cube faces get
				const float cx = (x - lc.getX()) - w / 2.0f - 0.5f;
				const float cy = (y - lc.getY()) - h / 2.0f - 0.5f;
				const float cz = (z - lc.getZ()) - d / 2.0f - 0.5f;
				// A shaped voxel is lit by its own light rather than by the
				// voxel in front of each face: there is no "in front" for an
				// arbitrary quad, and a plant or a rail is lit by the air it
				// stands in, which is the voxel it is in.
				float sky_f = (float)v.get_skylight() /
						VoxelInstance::SKYLIGHT_MAX;
				float lamp_f = (float)v.get_lamplight() /
						VoxelInstance::LAMPLIGHT_MAX;
				for(const interface::VoxelQuad &quad : def->shape){
					uint tile = quad.tile < 6 ? quad.tile : 0;
					AtlasSegmentReference seg_ref = def->textures[tile];
					if(seg_ref.atlas_id == interface::ATLAS_UNDEFINED)
						continue;
					const AtlasSegmentCache *aseg =
							atlas_reg->get_texture(seg_ref);
					if(aseg == nullptr)
						continue;
					sm_<uint, TemporaryGeometry> &into =
							(translucent_result && def->translucent) ?
							*translucent_result : result;
					TemporaryGeometry &tg = into[seg_ref.atlas_id];
					if(tg.vertex_data.Empty()){
						tg.atlas_id = seg_ref.atlas_id;
						tg.has_colors = use_skylight;
					}
					// The quad's own normal, for the per-face brightness the
					// cubes get
					Vector3 e1(quad.p[1][0] - quad.p[0][0],
							quad.p[1][1] - quad.p[0][1],
							quad.p[1][2] - quad.p[0][2]);
					Vector3 e2(quad.p[2][0] - quad.p[0][0],
							quad.p[2][1] - quad.p[0][1],
							quad.p[2][2] - quad.p[0][2]);
					Vector3 n = e1.CrossProduct(e2).Normalized();
					uint face_id = 0;
					if(std::fabs(n.y_) >= std::fabs(n.x_) &&
							std::fabs(n.y_) >= std::fabs(n.z_))
						face_id = n.y_ >= 0 ? 0 : 1;
					else if(std::fabs(n.x_) >= std::fabs(n.z_))
						face_id = n.x_ >= 0 ? 2 : 3;
					else
						face_id = n.z_ >= 0 ? 4 : 5;
					unsigned color = 0xffffffff;
					if(use_skylight){
						float shade = FACE_SHADE[face_id];
						color = Color(
								BOUNCE_COLOR.r_ * shade * (1.0f - sky_f) +
										LAMP_COLOR.r_ * lamp_f * shade,
								BOUNCE_COLOR.g_ * shade * (1.0f - sky_f) +
										LAMP_COLOR.g_ * lamp_f * shade,
								BOUNCE_COLOR.b_ * shade * (1.0f - sky_f) +
										LAMP_COLOR.b_ * lamp_f * shade,
								sky_f * shade).ToUInt();
					}
					// Two triangles, and the same two the other way round
					// when the shape is drawn from both sides
					static const int WINDINGS[2][6] = {
						{0, 1, 2, 0, 2, 3},
						{0, 2, 1, 0, 3, 2},
					};
					int windings = def->shape_double_sided ? 2 : 1;
					for(int wi = 0; wi < windings; wi++){
						for(int i = 0; i < 6; i++){
							int c = WINDINGS[wi][i];
							tg.vertex_data.Resize(tg.vertex_data.Size() + 1);
							CustomGeometryVertex &tv = tg.vertex_data.Back();
							tv.position_ = Vector3(cx + quad.p[c][0],
									cy + quad.p[c][1], cz + quad.p[c][2]);
							tv.normal_ = wi == 0 ? n : -n;
							tv.texCoord_ = Vector2(
									aseg->coord0.x_ + quad.uv[c][0] *
											(aseg->coord1.x_ - aseg->coord0.x_),
									aseg->coord0.y_ + quad.uv[c][1] *
											(aseg->coord1.y_ - aseg->coord0.y_));
							tv.color_ = color;
						}
					}
				}
			}
		}
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
				true, tg.has_colors, true, false);
		PODVector<CustomGeometryVertex> &cg_vertices = cg_all_vertices[cg_i];
		cg_vertices = tg.vertex_data;
		Material *material = new Material(context);
		if(tg.has_colors){
			// No technique: the game picks one in its material callback, as
			// only it knows which shader reads the maps set up here. Skylit
			// geometry stays invisible until it does. See interface/atlas.h
			// for what the maps contain and interface/mesh.h for the rest of
			// what a shader is handed.
			//
			// The atlas derives a normal map and a surface map
			// from each segment's image, so the maps are the whole material
			// and these two constants are only added on top of them
			material->SetShaderParameter("Roughness", 0.0f);
			material->SetShaderParameter("Metallic", 0.0f);
			material->SetTexture(TU_NORMAL, atlas_cache->normal_texture);
			material->SetTexture(TU_SPECULAR, atlas_cache->spec_texture);
		} else {
			material->SetTechnique(0,
					cache->GetResource<Technique>("Techniques/Diff.xml"));
		}
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
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight)
{
	preload_textures(volume, voxel_reg, atlas_reg);

	sm_<uint, TemporaryGeometry> temp_geoms;
	generate_voxel_geometry(temp_geoms, volume, voxel_reg, atlas_reg,
			use_skylight);

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
							if(v1.get_id() == interface::VOXELTYPEID_UNDEFINED)
								continue;
							// TODO: Prioritize voxel types better
							// Higher is probably more interesting
							if(v1.get_id() > v_orig.get_id())
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
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight)
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
			tg.has_colors = use_skylight;
			// It can't get larger than this and will only exist temporarily in
			// memory, so let's do only one big memory allocation
			tg.vertex_data.Reserve(pv_vertices.size() / 4 * 6);
		}
		pv::Vector3DFloat quad[4] = {
			pv_vertices[pv_vertex_i0 + 0].position,
			pv_vertices[pv_vertex_i0 + 1].position,
			pv_vertices[pv_vertex_i0 + 2].position,
			pv_vertices[pv_vertex_i0 + 3].position,
		};
		if(face_owned_by_padding(lod_volume, quad, n))
			continue;
		unsigned corner_colors[4] = {
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff
		};
		if(use_skylight){
			face_vertex_colors(lod_volume, voxel_reg, quad, n, face_id,
					corner_colors);
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
					- w/2.0f - 0.5f - lod/2.0f;
			tg_vert.position_.y_ = pv_vert.position.getY() * lod
					- h/2.0f - 0.5f - lod/2.0f;
			tg_vert.position_.z_ = pv_vert.position.getZ() * lod
					- d/2.0f - 0.5f - lod/2.0f;
			tg_vert.normal_.x_ = pv_vert.normal.getX();
			tg_vert.normal_.y_ = pv_vert.normal.getY();
			tg_vert.normal_.z_ = pv_vert.normal.getZ();
			// Figure out texture coordinates
			size_t pv_vertex_i1 = pv_vertex_i - pv_vertex_i0;
			assign_txcoords(pv_vertex_i1, aseg, tg_vert);
			tg_vert.color_ = corner_colors[pv_vertex_i1];
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
				true, tg.has_colors, true, false);
		PODVector<CustomGeometryVertex> &cg_vertices = cg_all_vertices[cg_i];
		cg_vertices = tg.vertex_data;
		Material *material = new Material(context);
		// Every LOD is lit the same way as the geometry next to it. An unlit
		// technique cannot match a scene lit in HDR and tonemapped, whatever
		// is baked into its texture, and a visible brightness step at the LOD
		// boundary is worse than the coarseness of the LOD itself.
		if(tg.has_colors){
			// The game sets the technique; see set_voxel_geometry()
			material->SetShaderParameter("Roughness", 0.0f);
			material->SetShaderParameter("Metallic", 0.0f);
			material->SetTexture(TU_NORMAL, atlas_cache->normal_texture);
			material->SetTexture(TU_SPECULAR, atlas_cache->spec_texture);
		} else {
			material->SetTechnique(0,
					cache->GetResource<Technique>("Techniques/Diff.xml"));
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
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight)
{
	up_<pv::RawVolume<VoxelInstance>> lod_volume = generate_voxel_lod_volume(
			lod, volume_orig);

	preload_textures(*lod_volume, voxel_reg, atlas_reg, true);

	sm_<uint, TemporaryGeometry> temp_geoms;
	generate_voxel_lod_geometry(
			lod, temp_geoms, *lod_volume, voxel_reg, atlas_reg, use_skylight);

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
				if(!def){
					throw Exception(ss_()+"Undefined voxel: "+itos(v_orig.get_id()));
				}
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
				// getVoxelAt() past the region reads outside the volume's
				// data, so the plane loops below would happily accept
				// whatever is in that memory and stretch the box out of the
				// world. Stop at the region instead.
				if(x1 > uc.getX())
					goto x_plane_does_not_fit;
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
				if(y1 > uc.getY())
					goto y_plane_does_not_fit;
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
				if(z1 > uc.getZ())
					goto z_plane_does_not_fit;
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
					(x0 + x1)/2.0f - w/2 + 0.5f,
					(y0 + y1)/2.0f - h/2 + 0.5f,
					(z0 + z1)/2.0f - d/2 + 0.5f
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
