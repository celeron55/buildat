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
using interface::VoxelRegistry;

// The voxel format's fields, read out of the registry once per chunk instead
// of once per voxel; see VoxelFormat in interface/voxel.h. A format is set
// before the first voxel is added and never after, so nothing here needs the
// registry's lock and a copy of it stays true for as long as a mesh job.
struct VoxelFmt
{
	interface::VoxelField id, light_sky, light_lamp, param, color;
	float sky_div = 1.0f;
	float lamp_div = 1.0f;

	VoxelFmt(){}
	VoxelFmt(VoxelRegistry *voxel_reg)
	{
		const interface::VoxelFormat &f = voxel_reg->get_format();
		id = f.id;
		light_sky = f.light_sky;
		light_lamp = f.light_lamp;
		param = f.param;
		color = f.color;
		sky_div = light_sky.bound() ? (float)light_sky.mask() : 1.0f;
		lamp_div = light_lamp.bound() ? (float)light_lamp.mask() : 1.0f;
	}

	interface::VoxelTypeId id_of(const VoxelInstance &v) const
	{
		return id.bound() ? (interface::VoxelTypeId)id.get(v.data) : 1;
	}
	// Nothing has generated this voxel yet. A format with no id bound has one
	// voxel type and no way to say that, so nothing is undefined there.
	bool undefined(const VoxelInstance &v) const
	{
		return id_of(v) == interface::VOXELTYPEID_UNDEFINED;
	}
	float sky_f(const VoxelInstance &v) const
	{
		return light_sky.bound() ?
				(float)light_sky.get(v.data) / sky_div : 0.0f;
	}
	float lamp_f(const VoxelInstance &v) const
	{
		return light_lamp.bound() ?
				(float)light_lamp.get(v.data) / lamp_div : 0.0f;
	}
};

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
	const VoxelFmt fmt(voxel_reg);
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
					uint8_t c = (uint8_t)source_data[i++];
					VoxelInstance v(0);
					fmt.id.set(v.data, c);
					volume.setVoxelAt(x, y, z, v);
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
	const VoxelFmt fmt(voxel_reg);
	size_t i = 0;
	for(int z = -1; z <= d; z++){
		for(int y = -1; y <= h; y++){
			for(int x = -1; x <= w; x++){
				VoxelInstance v(0);
				if(!(z == -1 || y == -1 || x == -1 ||
						z == d || y == h || x == w))
					fmt.id.set(v.data, (uint8_t)source_data[i++]);
				// 8 bit data has no room for a light value, and this is a
				// model standing on its own rather than a piece of a world
				// that could light it, so it is lit as if it were out in the
				// open. Handing a voxel shader no light at all is not the
				// safe choice it looks like: with the ambient term zeroed,
				// what is left is the reflection, and every texel of the
				// derived normal map then reflects the sky in its own
				// direction, which comes out as speckle.
				fmt.light_sky.set(v.data, fmt.light_sky.mask());
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
	VoxelFmt m_fmt;
	// NOTE: The voxel type id is used directly as PolyVox material value
public:
	IsQuadNeededByRegistryPhysics(interface::VoxelRegistry *voxel_reg):
		m_voxel_reg(voxel_reg), m_fmt(voxel_reg)
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
			throw Exception(ss_()+"Undefined voxel: back="+
					itos(m_fmt.id_of(back)));
		if(!front_def)
			throw Exception(ss_()+"Undefined voxel: front="+
					itos(m_fmt.id_of(front)));
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
	VoxelFmt m_fmt;
	// NOTE: The voxel type id is used directly as PolyVox material value
public:
	IsQuadNeededByRegistry(interface::VoxelRegistry *voxel_reg):
		m_voxel_reg(voxel_reg), m_fmt(voxel_reg)
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
			throw Exception(ss_()+"Undefined voxel: back="+
					itos(m_fmt.id_of(back)));
		if(!front_def)
			throw Exception(ss_()+"Undefined voxel: front="+
					itos(m_fmt.id_of(front)));
		/*if(!back_def){
			return false;
		}*/
		else if(back_def->face_draw_type == interface::FaceDrawType::NEVER){
			return false;
		}
		else if(back_def->face_draw_type == interface::FaceDrawType::ALWAYS){
			materialToUse = m_fmt.id_of(back);
			return true;
		}
		// interface::FaceDrawType::ON_EDGE
		if(!front_def){
			materialToUse = m_fmt.id_of(back);
			return true;
		}
		// A translucent voxel does not draw its face against an opaque one:
		// that surface is the opaque voxel's own, drawn by it and seen
		// through the water rather than under another blended layer of it.
		// This is Luanti's rule that the more solid of two nodes owns the
		// face between them.
		if(back_def->translucent && !front_def->translucent &&
				front_def->edge_material_id !=
						interface::EDGEMATERIALID_EMPTY){
			return false;
		}
		if(back_def->edge_material_id != front_def->edge_material_id){
			materialToUse = m_fmt.id_of(back);
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
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		const pv::Vector3DInt32 &p)
{
	VoxelInstance v = volume.getVoxelAt(p);
	if(fmt.undefined(v))
		return false; // Unfilled chunk padding; assume open
	const interface::CachedVoxelDefinition *def = voxel_reg->get_cached(v);
	if(def == nullptr)
		return false;
	return def->edge_material_id != interface::EDGEMATERIALID_EMPTY;
}

// The voxel a face belongs to: half a voxel behind the face's centre, against
// the normal. The same arithmetic as face_owned_by_padding(), and what wants
// it is the face's own param, which PolyVox does not carry through.
static VoxelInstance face_back_voxel(pv::RawVolume<VoxelInstance> &volume,
		const pv::Vector3DFloat *quad, const pv::Vector3DFloat &n)
{
	pv::Vector3DFloat centre(0, 0, 0);
	for(size_t i = 0; i < 4; i++)
		centre += quad[i];
	centre /= 4.0f;
	const pv::Vector3DInt32 vlc = volume.getEnclosingRegion().getLowerCorner();
	return volume.getVoxelAt(
			vlc.getX() + (int)std::floor(centre.getX() - n.getX()*0.5f + 0.5f),
			vlc.getY() + (int)std::floor(centre.getY() - n.getY()*0.5f + 0.5f),
			vlc.getZ() + (int)std::floor(centre.getZ() - n.getZ()*0.5f + 0.5f));
}

// A voxel's own colour multiplied into the light the mesher worked out. The
// packing is Urho3D's Color::ToUInt(), which is red in the low byte; the
// alpha is how much of the sky the surface sees and is left alone.
// A colour on its own, as the vertex format wants it: red in the low byte,
// and no sky at all in the alpha. What that says to a voxel shader is "this
// surface looks like this whatever the sky is doing", which is what a colour
// with no light behind it means -- see the vertex colour's split in
// interface/mesh.h.
static unsigned plain_color(uint32_t rgb)
{
	return ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
}

static unsigned modulate_color(unsigned lit, uint32_t rgb)
{
	if(rgb == 0xffffff)
		return lit;
	unsigned r = (lit & 0xff) * ((rgb >> 16) & 0xff) / 255;
	unsigned g = ((lit >> 8) & 0xff) * ((rgb >> 8) & 0xff) / 255;
	unsigned b = ((lit >> 16) & 0xff) * (rgb & 0xff) / 255;
	return (lit & 0xff000000UL) | (b << 16) | (g << 8) | r;
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
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		const pv::Vector3DFloat *quad,
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
	VoxelInstance lit = fmt.undefined(front) ?
			volume.getVoxelAt(voxel_at(-0.5f)) : front;
	float sky_f = fmt.sky_f(lit);
	float lamp_f = fmt.lamp_f(lit);

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
		bool s1 = occludes(volume, voxel_reg, fmt, front_p + du);
		bool s2 = occludes(volume, voxel_reg, fmt, front_p + dv);
		// Two solid sides bury the corner whatever is diagonally behind it
		int occluders = (s1 && s2) ? 3 : (s1 ? 1 : 0) + (s2 ? 1 : 0) +
				(occludes(volume, voxel_reg, fmt, front_p + du + dv) ? 1 : 0);
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
	const VoxelFmt fmt(voxel_reg);
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
					throw Exception(ss_()+"Undefined voxel: "+
							itos(fmt.id_of(v)));
			}
		}
	}
}

static void generate_voxel_shapes(sm_<uint, TemporaryGeometry> &result,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result);

void generate_voxel_geometry(sm_<uint, TemporaryGeometry> &result,
		pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result)
{
	const VoxelFmt fmt(voxel_reg);
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
		pv::Vector3DFloat quad[4] = {
			pv_vertices[pv_vertex_i0 + 0].position,
			pv_vertices[pv_vertex_i0 + 1].position,
			pv_vertices[pv_vertex_i0 + 2].position,
			pv_vertices[pv_vertex_i0 + 3].position,
		};
		if(face_owned_by_padding(volume, quad, n))
			continue;
		// What this voxel's param says about drawing it, if its definition
		// has anything to say. The param is the one thing PolyVox does not
		// carry through the extractor, so the voxel is looked up again.
		const interface::VoxelVariant *variant = nullptr;
		uint32_t voxel_color = 0xffffff;
		if((fmt.param.bound() && !voxel_def0->variants.empty()) ||
				fmt.color.bound()){
			VoxelInstance back = face_back_voxel(volume, quad, n);
			if(fmt.param.bound() && !voxel_def0->variants.empty())
				variant = voxel_def0->variant(fmt.param.get(back.data));
			if(fmt.color.bound())
				voxel_color = fmt.color.get(back.data) & 0xffffffUL;
		}
		// Get texture coordinates (contained in AtlasSegmentCache)
		const uint tile = variant ? (variant->tile_order[face_id] < 6 ?
				variant->tile_order[face_id] : face_id) : face_id;
		AtlasSegmentReference seg_ref = voxel_def0->textures[tile];
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
		unsigned corner_colors[4] = {
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff
		};
		if(use_skylight){
			face_vertex_colors(volume, voxel_reg, fmt, quad, n, face_id,
					corner_colors);
		}
		// The voxel's own colour, and then what its param says about it
		if(voxel_color != 0xffffff || (variant &&
				variant->color != 0xffffff)){
			uint32_t tint = variant ?
					modulate_color(voxel_color | 0xff000000UL,
							variant->color) & 0xffffffUL : voxel_color;
			for(size_t i = 0; i < 4; i++){
				corner_colors[i] = use_skylight ?
						modulate_color(corner_colors[i], tint) :
						plain_color(tint);
			}
			// Whatever the light is doing, these vertices now carry
			// something that has to reach the shader
			tg.has_colors = true;
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
			turn_txcoord(aseg, variant ? variant->tile_turns[face_id] :
					voxel_def0->tile_turns[face_id], tg_vert);
			tg_vert.color_ = corner_colors[pv_vertex_i1];
		}
#endif
	}

	generate_voxel_shapes(result, volume, voxel_reg, fmt, atlas_reg,
			use_skylight, translucent_result);
}

// How high a liquid's surface stands at one corner of a voxel: the average
// of the surfaces of the up to four liquid columns that meet there. This is
// Luanti's getCornerLevel, and what it is for is a surface that runs
// continuously from one level to the next instead of stepping down.
//
// Two rules on top of the average, both Luanti's: a column with the same
// liquid directly above it is full to the top of the voxel, because that is
// a body of liquid rather than a surface; and a corner that two of the four
// columns leave empty is at the bottom, which is what makes the edge of a
// spill thin out rather than stand as a wall.
static float liquid_corner_top(pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt, int x, int y, int z,
		const interface::CachedVoxelDefinition *def, float def_top,
		int dx, int dz)
{
	const int off[4][2] = {{0, 0}, {dx, 0}, {0, dz}, {dx, dz}};
	float sum = 0.0f;
	int count = 0;
	int empty = 0;
	for(size_t i = 0; i < 4; i++){
		int cx = x + off[i][0];
		int cz = z + off[i][1];
		VoxelInstance av = volume.getVoxelAt(cx, y + 1, cz);
		const interface::CachedVoxelDefinition *adef =
				fmt.undefined(av) ? nullptr : voxel_reg->get_cached(av);
		if(adef != nullptr && adef->is_liquid &&
				adef->shape_group == def->shape_group)
			return 0.5f;
		VoxelInstance cv = volume.getVoxelAt(cx, y, cz);
		const interface::CachedVoxelDefinition *cdef =
				fmt.undefined(cv) ? nullptr : voxel_reg->get_cached(cv);
		if(cdef == nullptr)
			continue;
		if(cdef->is_liquid && cdef->shape_group == def->shape_group){
			// How high this column stands is its own param's business, the
			// same as the voxel being meshed: Luanti puts a flowing liquid's
			// level in param2
			const interface::VoxelVariant *cvar = fmt.param.bound() ?
					cdef->variant(fmt.param.get(cv.data)) : nullptr;
			sum += cvar ? cvar->liquid_top : cdef->liquid_top;
			count++;
		} else if(cdef->fully_empty){
			empty++;
			if(empty >= 2)
				return -0.5f;
		}
	}
	if(count == 0)
		return def_top;
	return sum / count;
}

// Which of the six directions a connecting voxel's neighbours connect in, as
// a bit per face in the usual order. A shape's quad that names a direction is
// drawn only when that bit is set, which is how a fence gets a rail towards
// the fence next to it and no rail towards the air.
//
// Two voxels connect when the neighbour is in one of the families this one
// reaches out to -- one bit of connect_mask per family -- or, for a voxel
// that says so, when the neighbour is simply solid, which is how a fence
// reaches into a wall of stone. What the families are is the game's business;
// see interface/voxel.h.
static bool connects_to(pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt, int x, int y, int z,
		const interface::CachedVoxelDefinition *def)
{
	VoxelInstance nv = volume.getVoxelAt(x, y, z);
	if(fmt.undefined(nv))
		return false;
	const interface::CachedVoxelDefinition *ndef = voxel_reg->get_cached(nv);
	if(ndef == nullptr)
		return false;
	if(ndef->connect_group != 0 && ndef->connect_group <= 32 &&
			(def->connect_mask & (1u << (ndef->connect_group - 1))) != 0)
		return true;
	if(def->connect_to_solid)
		return ndef->physically_solid && ndef->shape.empty();
	return false;
}

static uint connected_faces(pv::RawVolume<VoxelInstance> &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt, int x, int y, int z,
		const interface::CachedVoxelDefinition *def, uint *stepped_up)
{
	static const int FACE_DIR[6][3] = {
		{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
		{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
	};
	uint faces = 0;
	for(size_t i = 0; i < 6; i++){
		if(connects_to(volume, voxel_reg, fmt, x + FACE_DIR[i][0],
				y + FACE_DIR[i][1], z + FACE_DIR[i][2], def))
			faces |= 1u << i;
	}
	if(stepped_up == nullptr)
		return faces;
	// A step up or down, for a voxel whose shape follows one: a rail runs
	// into the rail on the slope above it and the one below it as much as
	// into the one beside it, which is Luanti's own rule for them. The four
	// horizontal directions only, in Luanti's own order: +Z, -Z, -X, +X.
	static const int STEP_DIR[4][3] = {
		{0, 0, 1}, {0, 0, -1}, {-1, 0, 0}, {1, 0, 0},
	};
	*stepped_up = 0;
	for(size_t i = 0; i < 4; i++){
		if(connects_to(volume, voxel_reg, fmt, x + STEP_DIR[i][0], y + 1,
				z + STEP_DIR[i][2], def)){
			*stepped_up |= 1u << i;
			faces |= 1u << (i == 0 ? 4 : i == 1 ? 5 : i == 2 ? 3 : 2);
		} else if(connects_to(volume, voxel_reg, fmt, x + STEP_DIR[i][0], y - 1,
				z + STEP_DIR[i][2], def)){
			faces |= 1u << (i == 0 ? 4 : i == 1 ? 5 : i == 2 ? 3 : 2);
		}
	}
	return faces;
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
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		AtlasRegistry *atlas_reg,
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
				if(def == nullptr)
					continue;
				// What this voxel's param says about drawing it: a shape of
				// its own, a colour, how high its liquid stands
				const interface::VoxelVariant *variant = fmt.param.bound() ?
						def->variant(fmt.param.get(v.data)) : nullptr;
				const sv_<interface::VoxelQuad> &own_shape =
						(variant && !variant->shape.empty()) ?
						variant->shape : def->shape;
				if(own_shape.empty() && def->shape_masked.empty())
					continue;
				const float liquid_top = variant ?
						variant->liquid_top : def->liquid_top;
				// Where this voxel's centre is in the chunk's own model
				// coordinates; the same arithmetic the cube faces get
				const float cx = (x - lc.getX()) - w / 2.0f - 0.5f;
				const float cy = (y - lc.getY()) - h / 2.0f - 0.5f;
				const float cz = (z - lc.getZ()) - d / 2.0f - 0.5f;
				// A shaped voxel is lit by its own light rather than by the
				// voxel in front of each face: there is no "in front" for an
				// arbitrary quad, and a plant or a rail is lit by the air it
				// stands in, which is the voxel it is in.
				float sky_f = fmt.sky_f(v);
				float lamp_f = fmt.lamp_f(v);
				// Which directions this voxel connects in, once per voxel
				// rather than once per quad that asks. Only a voxel that
				// reaches out at all pays for it.
				// A voxel whose whole shape depends on what is around it --
				// a rail -- keeps one shape per mask of the four horizontal
				// connections, and four more for the slopes; the rest of
				// the loop walks that instead of `shape`.
				uint stepped_up = 0;
				const bool masked = !def->shape_masked.empty();
				const uint faces = (def->connect_mask != 0 ||
						def->connect_to_solid || masked) ?
						connected_faces(volume, voxel_reg, fmt, x, y, z, def,
								masked ? &stepped_up : nullptr) : 0;
				const interface::VoxelQuad *quads = own_shape.data();
				size_t quad_from = 0;
				size_t quad_to = own_shape.size();
				if(masked){
					// The four horizontal connections in Luanti's own bit
					// order for them: +Z is 1, -Z is 2, -X is 4, +X is 8
					uint m = ((faces >> 4) & 1) |
							(((faces >> 5) & 1) << 1) |
							(((faces >> 3) & 1) << 2) |
							(((faces >> 2) & 1) << 3);
					// A slope wins over the flat shapes, and the last
					// direction that has one wins between slopes, which is
					// what Luanti does with them
					for(uint i = 0; i < 4; i++){
						if(stepped_up & (1u << i))
							m = 16 + i;
					}
					quads = def->shape_masked.data();
					quad_from = def->shape_masked_begin[m];
					quad_to = def->shape_masked_begin[m + 1];
				}
				// A liquid's four top corners, once per voxel rather than
				// once per vertex that sits on one
				const bool liquid_corners = def->is_liquid;
				float corner[2][2] = {};
				if(liquid_corners){
					for(int ix = 0; ix < 2; ix++){
						for(int iz = 0; iz < 2; iz++){
							corner[ix][iz] = liquid_corner_top(volume,
									voxel_reg, fmt, x, y, z, def, liquid_top,
									ix == 0 ? -1 : 1, iz == 0 ? -1 : 1);
						}
					}
				}
				for(size_t quad_i = quad_from; quad_i < quad_to; quad_i++){
					const interface::VoxelQuad &quad = quads[quad_i];
					// A quad that belongs to one direction is drawn only
					// when that direction connects, and one that belongs to
					// standing alone only when none of them does
					if(quad.connect_dir == 7){
						if(faces != 0)
							continue;
					} else if(quad.connect_dir != 0 &&
							!(faces & (1u << (quad.connect_dir - 1)))){
						continue;
					}
					uint tile = quad.tile < 6 ? quad.tile : 0;
					AtlasSegmentReference seg_ref = def->textures[tile];
					if(seg_ref.atlas_id == interface::ATLAS_UNDEFINED)
						continue;
					const AtlasSegmentCache *aseg =
							atlas_reg->get_texture(seg_ref);
					if(aseg == nullptr)
						continue;
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
					// A quad of a grouped shape against a neighbour of the
					// same group is a face inside a body of it -- the water
					// inside a lake -- and is not drawn. Only an
					// axis-aligned quad is tested, and it is assumed to lie
					// on the voxel's boundary in that direction; a shape
					// whose quads do not is not what a group is for.
					// simplified: a face against a *lower* level of the same
					// liquid is dropped with the rest, which leaves a gap
					// where the surface steps down. Corner heights, which
					// make the surface continuous instead of stepped, are
					// what remove both.
					static const int FACE_AXIS[6] = {1, 1, 0, 0, 2, 2};
					static const int FACE_DIR[6][3] = {
						{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
						{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
					};
					if(def->shape_group != 0 &&
							std::fabs(n.Data()[FACE_AXIS[face_id]]) > 0.99f){
						VoxelInstance nv = volume.getVoxelAt(
								x + FACE_DIR[face_id][0],
								y + FACE_DIR[face_id][1],
								z + FACE_DIR[face_id][2]);
						const interface::CachedVoxelDefinition *ndef =
								fmt.undefined(nv) ? nullptr :
								voxel_reg->get_cached(nv);
						// The same group: a face inside a body of it. Or
						// something opaque: the face is that voxel's own, as
						// in IsQuadNeededByRegistry.
						if(ndef != nullptr &&
								(ndef->shape_group == def->shape_group ||
								(def->translucent && !ndef->translucent &&
								ndef->edge_material_id !=
								interface::EDGEMATERIALID_EMPTY)))
							continue;
					}
					sm_<uint, TemporaryGeometry> &into =
							(translucent_result && def->translucent) ?
							*translucent_result : result;
					TemporaryGeometry &tg = into[seg_ref.atlas_id];
					if(tg.vertex_data.Empty()){
						tg.atlas_id = seg_ref.atlas_id;
						tg.has_colors = use_skylight;
					}
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
					uint32_t tint = 0xffffff;
					if(fmt.color.bound())
						tint = fmt.color.get(v.data) & 0xffffffUL;
					if(variant){
						tint = modulate_color(tint | 0xff000000UL,
								variant->color) & 0xffffffUL;
					}
					if(tint != 0xffffff){
						color = use_skylight ?
								modulate_color(color, tint) :
								plain_color(tint);
						tg.has_colors = true;
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
							float py = quad.p[c][1];
							// A vertex on the liquid's own surface follows
							// the corner it stands at
							if(liquid_corners && std::fabs(
									py - liquid_top) < 1e-4f){
								py = corner[quad.p[c][0] >= 0.0f ? 1 : 0]
										[quad.p[c][2] >= 0.0f ? 1 : 0];
							}
							tv.position_ = Vector3(cx + quad.p[c][0],
									cy + py, cz + quad.p[c][2]);
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
		int lod, pv::RawVolume<VoxelInstance>&volume_orig,
		VoxelRegistry *voxel_reg)
{
	const VoxelFmt fmt(voxel_reg);
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
							if(fmt.undefined(v1))
								continue;
							// TODO: Prioritize voxel types better
							// Higher is probably more interesting
							if(fmt.id_of(v1) > fmt.id_of(v_orig))
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
	const VoxelFmt fmt(voxel_reg);
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
			face_vertex_colors(lod_volume, voxel_reg, fmt, quad, n, face_id,
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
			lod, volume_orig, voxel_reg);

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
	const VoxelFmt fmt(voxel_reg);
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
					throw Exception(ss_()+"Undefined voxel: "+
							itos(fmt.id_of(v_orig)));
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
