// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel.h"
#include "core/log.h"
#include "interface/voxel_cereal.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <mutex>
#include <cassert>
#define MODULE "voxel"

namespace std {
template<> struct hash<interface::VoxelName>{
	std::size_t operator()(const interface::VoxelName &v) const {
		return ((std::hash<ss_>() (v.block_name) << 0) ^
				(std::hash<uint>() (v.segment_x) << 1) ^
				(std::hash<uint>() (v.segment_y) << 2) ^
				(std::hash<uint>() (v.segment_z) << 3) ^
				(std::hash<uint>() (v.rotation_primary) << 4) ^
				(std::hash<uint>() (v.rotation_secondary) << 5));
	}
};
}

namespace interface {

ss_ VoxelName::dump() const
{
	std::ostringstream os(std::ios::binary);
	os<<"VoxelName(";
	os<<"block_name="<<block_name;
	os<<", segment=("<<(int)segment_x<<","<<(int)segment_y<<","
			<<(int)segment_z<<")";
	os<<", rotation_primary="<<(int)rotation_primary;
	os<<", rotation_secondary="<<(int)rotation_secondary;
	os<<")";
	return os.str();
}

bool VoxelName::operator==(const VoxelName &other) const
{
	return (
			block_name == other.block_name &&
			segment_x == other.segment_x &&
			segment_y == other.segment_y &&
			segment_z == other.segment_z &&
			rotation_primary == other.rotation_primary &&
			rotation_secondary == other.rotation_secondary
	);
}

// Voxel types are added on the main thread while worker threads mesh chunks
// out of them, so every access goes through m_mutex, and the definitions live
// in deques: a pointer handed out by get_cached() stays valid across an
// add_voxel(), which is not true of a vector.
struct CVoxelRegistry: public VoxelRegistry
{
	sd_<VoxelDefinition> m_defs;
	sd_<CachedVoxelDefinition> m_cached_defs;
	sm_<VoxelName, VoxelTypeId> m_name_to_id;
	VoxelFormat m_format = VoxelFormat::legacy();
	bool m_is_dirty = false;
	std::mutex m_mutex;

	CVoxelRegistry()
	{
		m_defs.resize(1); // Id 0 is VOXELTYPEID_UNDEFINEDD
	}

	void clear()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_defs.clear();
		m_cached_defs.clear();
		m_name_to_id.clear();

		m_defs.resize(1); // Id 0 is VOXELTYPEID_UNDEFINEDD
	}

	const VoxelFormat& get_format()
	{
		// Set before the first voxel and never after, so a reader on a
		// worker thread does not have to take the lock for this
		return m_format;
	}

	void set_format(const VoxelFormat &format)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		ss_ why;
		if(!format.validate(&why))
			throw Exception(ss_()+"set_format(): "+why);
		if(m_defs.size() > 1)
			throw Exception(ss_()+"set_format(): "+
					itos(m_defs.size() - 1)+" voxels have already been "
					"added under "+m_format.dump());
		m_format = format;
		m_is_dirty = true;
		log_v(MODULE, "CVoxelRegistry::set_format(): %s",
				cs(m_format.dump()));
	}

	sv_<VoxelDefinition> get_all()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		sv_<VoxelDefinition> result;
		result.insert(result.end(), m_defs.begin()+1, m_defs.end());
		return result;
	}

	VoxelTypeId add_voxel(const VoxelDefinition &def)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		VoxelTypeId id = m_defs.size();
		if(def.id != VOXELTYPEID_UNDEFINED && id != def.id)
			throw Exception(ss_()+"add_voxel(): def.id="+itos(def.id)+
					"; should be "+itos(id));
		if(m_name_to_id.count(def.name) != 0)
			throw Exception(ss_()+"add_voxel(): Already exists: "+
					cs(def.name.dump()));
		m_defs.resize(id + 1);
		m_defs[id] = def;
		m_defs[id].id = id;
		m_name_to_id[def.name] = id;
		log_v(MODULE, "CVoxelRegistyr::add_voxel(): Added id=%i name=%s",
				id, cs(def.name.dump()));
		m_is_dirty = true;
		return id;
	}

	const VoxelDefinition* get(const VoxelTypeId &id)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return get_unlocked(id);
	}

	const VoxelDefinition* get_unlocked(const VoxelTypeId &id)
	{
		if(id >= m_defs.size()){
			log_w(MODULE, "CVoxelRegistry::get(): id=%i not found", id);
			return NULL;
		}
		return &m_defs[id];
	}

	const VoxelDefinition* get(const VoxelName &name)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		auto it = m_name_to_id.find(name);
		if(it == m_name_to_id.end()){
			log_w(MODULE, "CVoxelRegistry::get(): name=%s not found",
					cs(name.dump()));
			return NULL;
		}
		VoxelTypeId id = it->second;
		return get_unlocked(id);
	}

	const CachedVoxelDefinition* get_cached(const VoxelTypeId &id,
			AtlasRegistry *atlas_reg, bool with_lod)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		if(id >= m_defs.size()){
			log_w(MODULE, "CVoxelRegistry::get_cached(): id=%i not found", id);
			return NULL;
		}
		if(m_cached_defs.size() < m_defs.size()){
			m_cached_defs.resize(m_defs.size());
		}
		const VoxelDefinition &def = m_defs[id];
		CachedVoxelDefinition &cache = m_cached_defs[id];
		if(!cache.valid){
			update_cache_basic(cache, def);
			cache.valid = true;
		}
		if(!cache.textures_valid && atlas_reg){
			update_cache_textures(cache, def, atlas_reg);
			cache.textures_valid = true;
		}
		if(with_lod && !cache.lod_textures_valid && atlas_reg){
			update_cache_lod_textures(cache, def, atlas_reg);
			cache.lod_textures_valid = true;
		}
		return &cache;
	}

	const CachedVoxelDefinition* get_cached(const VoxelInstance &v,
			AtlasRegistry *atlas_reg, bool with_lod)
	{
		return get_cached(m_format.id_of(v.data), atlas_reg, with_lod);
	}

	bool is_dirty()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return m_is_dirty;
	}

	void clear_dirty()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_is_dirty = false;
	}

	void update_cache_basic(CachedVoxelDefinition &cache,
			const VoxelDefinition &def)
	{
		log_d(MODULE, "CVoxelRegistry::update_cache_basic(): id=%i", def.id);
		cache.handler_module = def.handler_module;
		cache.face_draw_type = def.face_draw_type;
		cache.edge_material_id = def.edge_material_id;
		cache.physically_solid = def.physically_solid;
		cache.fully_empty = def.fully_empty;
		cache.shape = def.shape;
		cache.variants = def.variants;
		for(size_t i = 0; i < 256; i++)
			cache.variant_of_param[i] = def.variant_of_param[i];
		cache.tint_ramp[0] = def.tint_ramp[0];
		cache.tint_ramp[1] = def.tint_ramp[1];
		cache.sag_extent = def.sag_extent;
		cache.shape_double_sided = def.shape_double_sided;
		cache.translucent = def.translucent;
		cache.shape_group = def.shape_group;
		cache.is_liquid = def.is_liquid;
		cache.liquid_top = def.liquid_top;
		cache.connect_group = def.connect_group;
		cache.connect_mask = def.connect_mask;
		cache.connect_to_solid = def.connect_to_solid;
		cache.shape_masked = def.shape_masked;
		for(size_t i = 0; i < 21; i++)
			cache.shape_masked_begin[i] = def.shape_masked_begin[i];
		for(size_t i = 0; i < 6; i++)
			cache.tile_turns[i] = def.tile_turns[i] & 3;
		// Caller sets cache.valid = true
	}

	void update_cache_textures(CachedVoxelDefinition &cache,
			const VoxelDefinition &def, AtlasRegistry *atlas_reg)
	{
		log_d(MODULE, "CVoxelRegistry::update_cache_textures(): id=%i", def.id);
		for(size_t i = 0; i<6; i++){
			const AtlasSegmentDefinition &seg_def = def.textures[i];
			if(seg_def.resource_name == ""){
				cache.textures[i] = AtlasSegmentReference(); // Default values
			} else {
				cache.textures[i] = atlas_reg->find_or_add_segment(seg_def);
			}
		}
		// Caller sets cache.textures_valid = true
	}

	// The same for the segments a LOD mesh samples, which are a texture
	// scaled and drawn into an atlas each: three times the work of the
	// segments above, and nothing but a LOD volume ever looks at them.
	void update_cache_lod_textures(CachedVoxelDefinition &cache,
			const VoxelDefinition &def, AtlasRegistry *atlas_reg)
	{
		for(size_t i = 0; i<6; i++){
			const AtlasSegmentDefinition &seg_def = def.textures[i];
			for(size_t j = 0; j < VOXELDEF_NUM_LOD; j++){
				if(seg_def.resource_name == ""){
					cache.lod_textures[j][i] = AtlasSegmentReference();
					continue;
				}
				AtlasSegmentDefinition lod_seg_def = seg_def;
				lod_seg_def.lod_simulation = 2 + j;
				cache.lod_textures[j][i] =
						atlas_reg->find_or_add_segment(lod_seg_def);
			}
		}
		// Caller sets cache.lod_textures_valid = true
	}
};

bool VoxelFormat::light_pair(VoxelField *out) const
{
	if(!light_sky.bound() || !light_lamp.bound())
		return false;
	if(light_sky.plane != light_lamp.plane)
		return false;
	if(light_sky.shift + light_sky.width != light_lamp.shift)
		return false;
	if(out){
		*out = VoxelField{light_sky.plane, light_sky.shift,
				(uint8_t)(light_sky.width + light_lamp.width)};
	}
	return true;
}

size_t VoxelFormat::surface_modifiers(
		VoxelField out[VOXEL_SURFACE_MODIFIERS]) const
{
	const VoxelField *all[] = {&tint, &wetness, &grain, &gloss, &speckle,
			&emission};
	size_t n = 0;
	for(size_t i = 0; i < sizeof all / sizeof all[0]; i++){
		if(!all[i]->bound())
			continue;
		if(n < VOXEL_SURFACE_MODIFIERS)
			out[n] = *all[i];
		n++;
	}
	for(size_t i = n; i < VOXEL_SURFACE_MODIFIERS; i++)
		out[i] = VoxelField();
	return n < VOXEL_SURFACE_MODIFIERS ? n : VOXEL_SURFACE_MODIFIERS;
}

bool VoxelFormat::validate(ss_ *why) const
{
	auto fail = [&](const ss_ &s){
		if(why)
			*why = s;
		return false;
	};

	if(plane_bits != 8 && plane_bits != 16 && plane_bits != 32)
		return fail("plane_bits must be 8, 16 or 32, not "+
				itos((int)plane_bits));

	struct Named { cc_ *name; const VoxelField &f; };
	const Named fields[] = {
		{"id", id}, {"light_sky", light_sky}, {"light_lamp", light_lamp},
		{"param", param}, {"color", color},
		{"tint", tint}, {"wetness", wetness}, {"grain", grain},
		{"gloss", gloss}, {"speckle", speckle}, {"emission", emission},
		{"sag_top", sag_top}, {"sag_bottom", sag_bottom},
	};

	for(const Named &n : fields){
		if(!n.f.bound())
			continue;
		if(n.f.plane != 0)
			return fail(ss_(n.name)+": there is only plane 0 for now");
		if(n.f.width > 32)
			return fail(ss_(n.name)+": width "+itos((int)n.f.width)+" > 32");
		if((int)n.f.shift + (int)n.f.width > (int)plane_bits)
			return fail(ss_(n.name)+": bits "+itos((int)n.f.shift)+"..."+
					itos((int)n.f.shift + (int)n.f.width - 1)+" reach past the "+
					itos((int)plane_bits)+"-bit plane");
	}

	// VOXELTYPEID_MAX is not a mask -- it is a lower cap inside 21 bits --
	// so the rule here is the field's width, and the registry is what
	// refuses an id above the cap
	// The colour role is 0xRRGGBB in the low 24 bits of its field, so it is
	// that wide or 32 bits with the top byte unread. A palette index is not
	// this: indexing a palette is a lookup the engine does not have, and a
	// definition's variants are where a palette belongs.
	if(color.bound() && color.width != 24 && color.width != 32)
		return fail("color: width "+itos((int)color.width)+" is not 24 or 32");

	if(id.bound() && id.width > 21)
		return fail("id: width "+itos((int)id.width)+" > 21, the bits a "
				"voxel type id has");

	for(size_t i = 0; i < sizeof fields / sizeof fields[0]; i++){
		for(size_t j = i + 1; j < sizeof fields / sizeof fields[0]; j++){
			const Named &a = fields[i], &b = fields[j];
			if(!a.f.bound() || !b.f.bound())
				continue;
			if(a.f.plane != b.f.plane)
				continue;
			if((a.f.mask() << a.f.shift) & (b.f.mask() << b.f.shift))
				return fail(ss_(a.name)+" and "+b.name+" overlap");
		}
	}

	// Four is what the vertex has room for; a fifth would have nowhere to
	// go and the game would find out by not seeing it
	{
		size_t n = 0;
		const VoxelField *surface[] = {&tint, &wetness, &grain, &gloss,
				&speckle, &emission};
		for(size_t i = 0; i < sizeof surface / sizeof surface[0]; i++)
			if(surface[i]->bound())
				n++;
		if(n > VOXEL_SURFACE_MODIFIERS)
			return fail("at most "+itos((int)VOXEL_SURFACE_MODIFIERS)+
					" surface modifiers can be bound at once, not "+itos((int)n));
	}

	// Nothing to look up and nothing to wear: there would be no way to draw
	// a voxel of this format at all.
	if(!id.bound() && !color.bound())
		return fail("neither id nor color is bound");

	return true;
}

ss_ VoxelFormat::dump() const
{
	std::ostringstream os(std::ios::binary);
	os<<"VoxelFormat("<<(int)plane_bits<<"-bit";
	auto one = [&](cc_ *name, const VoxelField &f){
		if(!f.bound())
			return;
		os<<", "<<name<<"="<<(int)f.shift<<"..."
				<<(int)(f.shift + f.width - 1);
	};
	one("id", id);
	one("light_sky", light_sky);
	one("light_lamp", light_lamp);
	one("param", param);
	one("color", color);
	one("tint", tint);
	one("wetness", wetness);
	one("grain", grain);
	one("gloss", gloss);
	one("speckle", speckle);
	one("emission", emission);
	one("sag_top", sag_top);
	one("sag_bottom", sag_bottom);
	os<<")";
	return os.str();
}

bool voxel_format_self_test()
{
	// A field reads back what was written to it, and leaves the rest alone
	for(uint8_t width : {1, 4, 8, 16, 21, 32}){
		for(uint8_t shift = 0; shift + width <= 32; shift++){
			VoxelField f{0, shift, width};
			uint32_t word = 0xdeadbeef;
			uint32_t untouched = word & ~(f.mask() << shift);
			uint32_t value = f.mask() & 0x5a5a5a5a;
			f.set(word, value);
			assert(f.get(word) == value);
			assert((word & ~(f.mask() << shift)) == untouched);
			// A value too large for the field is cut, not spilled
			f.set(word, 0xffffffff);
			assert(f.get(word) == f.mask());
			assert((word & ~(f.mask() << shift)) == untouched);
		}
	}

	ss_ why;
	assert(VoxelFormat::legacy().validate(&why));
	assert(VoxelFormat::luanti().validate(&why));

	// The ways a format can be wrong
	{
		VoxelFormat f = VoxelFormat::legacy();
		f.param = f.id; // overlaps
		assert(!f.validate(&why));
	}
	{
		VoxelFormat f = VoxelFormat::legacy();
		f.param = VoxelField{0, 28, 8}; // past the end of the plane
		assert(!f.validate(&why));
	}
	{
		VoxelFormat f;
		f.id = VoxelField{0, 0, 32}; // wider than a voxel type id
		assert(!f.validate(&why));
	}
	{
		VoxelFormat f;
		f.id = VoxelField{0, 0, 21}; // the widest one there is
		assert(f.validate(&why));
	}
	{
		VoxelFormat f; // nothing bound
		assert(!f.validate(&why));
	}
	{
		// A painter: one implicit type, and a colour
		VoxelFormat f;
		f.color = VoxelField{0, 0, 32};
		assert(f.validate(&why));
		assert(f.id_of(0) == 1);
		assert(f.id_of(0xffffffff) == 1);
		// A colour is 24 bits of RGB, in a field of 24 or 32
		f.color = VoxelField{0, 0, 24};
		assert(f.validate(&why));
		f.color = VoxelField{0, 0, 16};
		assert(!f.validate(&why));
	}

	// The modifiers: at most four surface ones, in role order, and the
	// geometry ones do not count against that
	{
		VoxelFormat f;
		f.id = VoxelField{0, 0, 8};
		f.gloss = VoxelField{0, 8, 4};
		f.tint = VoxelField{0, 12, 4};
		assert(f.validate(&why));
		VoxelField slots[VOXEL_SURFACE_MODIFIERS];
		assert(f.surface_modifiers(slots) == 2);
		// Role order, not the order they were written here
		assert(slots[0] == f.tint);
		assert(slots[1] == f.gloss);
		assert(!slots[2].bound());

		f.sag_top = VoxelField{0, 16, 4};
		f.sag_bottom = VoxelField{0, 20, 4};
		assert(f.validate(&why));
		assert(f.surface_modifiers(slots) == 2);

		f.wetness = VoxelField{0, 24, 2};
		f.grain = VoxelField{0, 26, 2};
		assert(f.validate(&why));
		assert(f.surface_modifiers(slots) == 4);
		f.speckle = VoxelField{0, 28, 2}; // a fifth has nowhere to go
		assert(!f.validate(&why));
	}

	// legacy() through the format is VoxelInstance's own hardcoded cut
	{
		VoxelFormat f = VoxelFormat::legacy();
		for(uint32_t word : {0u, 0xffffffffu, 0x12345678u, 0xdeadbeefu,
				0x000fffffu, 0xf0f0f0f0u, 0x00000001u, 0x0badf00du}){
			VoxelInstance v(word);
			assert(f.id_of(word) == v.get_id());
			assert(f.light_sky.get(word) == v.get_skylight());
			assert(f.light_lamp.get(word) == v.get_lamplight());
		}
		VoxelField both;
		assert(f.light_pair(&both));
		assert(both.shift == 24 && both.width == 8);
	}

	// Luanti's cut fills the word with no room left over
	{
		VoxelFormat f = VoxelFormat::luanti();
		uint32_t word = 0;
		f.id.set(word, 0xabcd);
		f.light_sky.set(word, 7);
		f.light_lamp.set(word, 9);
		f.param.set(word, 0x5e);
		assert(f.id_of(word) == 0xabcd);
		assert(f.light_sky.get(word) == 7);
		assert(f.light_lamp.get(word) == 9);
		assert(f.param.get(word) == 0x5e);
	}

	return true;
}

VoxelRegistry* createVoxelRegistry()
{
	// Cheap, once per process, and it is the only place every build passes
	// through before a voxel exists
	static const bool tested = voxel_format_self_test();
	(void)tested;
	return new CVoxelRegistry();
}

void VoxelRegistry::serialize(std::ostream &os)
{
	sv_<VoxelDefinition> defs = get_all();
	VoxelFormat format = get_format();
	cereal::PortableBinaryOutputArchive archive(os);
	archive((uint8_t)1, format, defs);
}

void VoxelRegistry::deserialize(std::istream &is)
{
	uint8_t version = 0;
	VoxelFormat format;
	sv_<VoxelDefinition> defs;
	cereal::PortableBinaryInputArchive archive(is);
	archive(version);
	if(version != 1)
		throw Exception(ss_()+"VoxelRegistry::deserialize(): version "+
				itos(version)+" is not 1; the other end is a different "
				"build of buildat");
	archive(format, defs);
	clear();
	set_format(format);
	for(auto &def : defs)
		add_voxel(def);
}

ss_ VoxelRegistry::serialize()
{
	std::ostringstream os(std::ios::binary);
	serialize(os);
	return os.str();
}

void VoxelRegistry::deserialize(const ss_ &s)
{
	std::istringstream is(s, std::ios::binary);
	deserialize(is);
}

} // interface
// vim: set noet ts=4 sw=4:
