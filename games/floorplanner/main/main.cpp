// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// games/floorplanner: the document, its validation, its save and the
// accounts. doc/plan/floorplanner_plan.md is the spec; this is [FP_DOC].
//
// The server holds the document and is its only writer. A client sends a
// batch of operations, the server applies it whole or not at all and
// broadcasts what changed. Everything a client sends is checked here
// against the schema, whatever the sender's privileges.
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/sha256.h"
#include "interface/fs.h"
#include "interface/server_config.h"
#include "interface/os.h"
#include "client_file/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/map.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/utility.hpp>
#include <map>
#include <random>
#include <sstream>
#include <functional>
#include <cmath>
#include <algorithm>
#define MODULE "main"

using interface::Event;

namespace floorplanner {

// Kept in the save; bumped when a stored entity's meaning changes
static const int32_t SCHEMA_VERSION = 3;
static const size_t MAX_ENTITIES = 100000;
static const size_t MAX_OPS_PER_BATCH = 2000;
static const size_t MAX_STRING = 200;
static const size_t MAX_LIST = 1000;
// Plus or minus 100 km: far outside any building, far inside int32
static const int32_t MAX_COORD = 100000000;
static const int PBKDF2_ITERATIONS = 10000;
static const int MAX_LOGIN_FAILURES = 5;
// A voxel volume's cells run -128..127 on each axis, and it holds at most
// this many voxels
static const int32_t VOXEL_RANGE = 128;
static const size_t MAX_VOXELS = 200000;
// How many copies of the plan are kept, one made each time it is loaded
static const int BACKUPS = 5;
// A background image a client is sent at most
static const uint64_t MAX_IMAGE_BYTES = 20 * 1024 * 1024;

struct Entity
{
	int32_t id = 0;
	ss_ type;
	std::map<ss_, int32_t> ints;
	std::map<ss_, ss_> strs;
	std::map<ss_, sv_<int32_t>> lists;

	template<class Archive>
	void serialize(Archive &archive){
		archive(id, type, ints, strs, lists);
	}
};

// What an entity holding a reference does when the referenced one goes
enum class OnDelete {
	None,     // not a reference
	Cascade,  // the holder goes too
	Restrict, // the delete is refused
	Remove,   // a list drops the id; below min_len the holder goes
};

struct IntField {
	const char *name;
	int32_t min, max, def;
	const char *ref;    // entity type, or nullptr
	OnDelete on_delete;
	bool optional;      // a reference may be 0
	IntField(const char *name, int32_t min, int32_t max, int32_t def,
			const char *ref = nullptr, OnDelete on_delete = OnDelete::None,
			bool optional = false):
		name(name), min(min), max(max), def(def), ref(ref),
		on_delete(on_delete), optional(optional){}
};
struct StrField {
	const char *name;
	const char *def;
};
struct ListField {
	const char *name;
	const char *ref;
	OnDelete on_delete;
	size_t min_len;
};
struct TypeSchema {
	const char *type;
	sv_<IntField> ints;
	sv_<StrField> strs;
	sv_<ListField> lists;
	bool singleton; // exists from the start; not created or deleted
	TypeSchema(const char *type, sv_<IntField> ints, sv_<StrField> strs,
			sv_<ListField> lists, bool singleton = false):
		type(type), ints(ints), strs(strs), lists(lists),
		singleton(singleton){}
};

// What a definition is. A voxel volume comes with [FP_VOXELS].
enum DefKind { DK_BOX, DK_VOXEL, DK_OPENING, DK_DOOR, DK_WINDOW, DK_SWITCH,
	DK_COUNT };

// Material types, as the palette's `kind` field holds them. The shader and
// the client's palette editor use the same numbers.
enum MaterialKind { MK_DRYWALL, MK_WOOD, MK_STONE, MK_WALLPAPER, MK_LAMP,
	MK_GLASS, MK_METAL, MK_TILE, MK_FABRIC, MK_PLASTER, MK_PANEL, MK_COUNT };

static const sv_<TypeSchema> SCHEMA = {
	{"settings", {
		{"ceiling", 1000, 10000, 2600},
		{"cut", 100, 10000, 1200},
		{"default_edit", 0, 1, 1},
		// The sun, off by default: it has to cast shadows, or it shines
		// through the walls
		{"sun", 0, 1, 0},
		{"sun_yaw", 0, 359, 135},
		{"sun_pitch", 5, 90, 40},
		{"grid", 1, 100, 100}, // mm, what the plan snaps to
		// Floor to floor, where "Add a floor above" puts one ([FP_LAYOUTS])
		{"floor_step", 1000, 20000, 3000},
	}, {}, {}, true},
	// A floor or a building placed in the world ([FP_LAYOUTS]): its own
	// coordinates turned by yaw (millidegrees) and moved to x, y, z. The
	// layouts of one group are one building.
	{"layout", {
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"y", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
		{"yaw", 0, 359999, 0},
	}, {
		{"name", "Ground floor"},
		{"group", "Building"},
	}, {}},
	// Walls and rooms are their nodes' layout's
	// simplified: nothing checks that a wall's or a room's nodes are in one
	// layout; the client only joins nodes of the one it edits
	{"node", {
		{"layout", 1, INT32_MAX, 0, "layout", OnDelete::Restrict},
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
	}, {}, {}},
	{"wall", {
		{"a", 1, INT32_MAX, 0, "node", OnDelete::Cascade},
		{"b", 1, INT32_MAX, 0, "node", OnDelete::Cascade},
		{"thickness", 1, 2000, 100},
		{"justify", 0, 2, 0},     // 0 centered, 1 left, 2 right of a->b
		{"height", 0, 20000, 0},  // 0: full height
		{"hang", 0, 1, 0},        // 1: from the ceiling down
		{"mat_left", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_right", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_core", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
	}, {}, {}},
	{"room", {
		{"mat_floor", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_ceiling", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"ceiling", 0, 10000, 0}, // 0: the plan's
	}, {
		{"name", "room"},
	}, {
		{"nodes", "node", OnDelete::Remove, 3},
	}},
	// The shape a set of instances share; see DefKind. A box is w by h by
	// d; an opening, a door and a window are w wide and h high, with trim
	// round them on both faces
	{"definition", {
		{"kind", 0, DK_COUNT - 1, DK_BOX},
		{"w", 1, 100000, 600},
		{"h", 1, 20000, 750},
		{"d", 1, 100000, 600},
		{"trim", 0, 500, 70},
		{"trim_depth", 0, 200, 15},
		{"leaf", 0, 1, 0},       // door: single, double; window: fixed, casement
		{"voxel_size", 1, 1000, 50}, // a voxel volume's, mm
		{"mat", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_leaf", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_glass", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
	}, {}, {}},
	// A definition placed: yaw in millidegrees, pitch and roll in quarter
	// turns, and its height from the floor up or the ceiling down
	{"instance", {
		{"def", 1, INT32_MAX, 0, "definition", OnDelete::Cascade},
		{"layout", 1, INT32_MAX, 0, "layout", OnDelete::Restrict},
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
		{"yaw", 0, 359999, 0},
		{"pitch", 0, 3, 0},
		{"roll", 0, 3, 0},
		{"align", 0, 1, 0},       // 1: from the ceiling down
		{"offset", 0, 20000, 0},
		// Hosted in a wall: its centre this far along from the wall's a
		// end, its bottom sill above the floor. The position and yaw above
		// are then the wall's.
		{"host", 0, INT32_MAX, 0, "wall", OnDelete::Cascade, true},
		{"along", -MAX_COORD, MAX_COORD, 0},
		{"sill", 0, 20000, 0},
		{"flip", 0, 3, 0},        // bit 0: hinge on the other jamb; 1: swing
		{"open", 0, 1000, 0},     // thousandths of fully open
		{"on", 0, 1, 1},          // a lamp's
	}, {}, {
		// A switch's lamps
		{"lamps", "instance", OnDelete::Remove, 0},
	}},
	// One material: its type, its own colour, the paint over it, and the
	// knobs of its type. See Palette.glsl for what each does.
	// A picture under the plan, an existing floor plan to trace: one of the
	// save's images/, its middle at x, z, scale mm per 1000 pixels
	{"image", {
		{"layout", 1, INT32_MAX, 0, "layout", OnDelete::Restrict},
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
		{"yaw", 0, 359999, 0},
		{"scale", 1, 10000000, 10000},
		{"opacity", 0, 1000, 600},
		{"locked", 0, 1, 0},
		{"show3d", 0, 1, 0},
	}, {
		{"file", ""},
	}, {}},
	{"palette", {
		{"kind", 0, MK_COUNT - 1, MK_DRYWALL},
		{"base", 0, 0xffffff, 0xe8e4dc},
		{"color", 0, 0xffffff, 0xffffff},
		{"finish", 0, 2, 0},       // 0 over its colour, 1 undercoat, 2 stain
		{"opacity", 0, 1000, 500}, // a stain's, and glass's
		{"color2", 0, 0xffffff, 0x404040}, // veins, pattern, grout
		{"roughness", 0, 1000, 800},
		{"specular", 0, 1000, 100},
		{"reflect", 0, 1000, 0},
		{"scale", 1, 60000, 200},  // mm
		{"seed", 0, 65535, 0},
		{"axis", 0, 2, 0},         // wood's grain: x, y, z
		{"stagger", 0, 1, 0},      // tiles
		{"grout", 0, 100, 3},      // mm
		{"temperature", 1000, 12000, 2700}, // a lamp's, in kelvin
		{"brightness", 0, 1000, 500},
		{"speckle", 0, 1000, 300}, // plaster
		{"angle", 0, 179, 0},      // paneling's boards, 0 horizontal, 90 vertical
		{"contrast", 0, 3000, 1000}, // wood's grain, 1000 as it always was
	}, {
		{"name", "material"},
	}, {}},
};

static const TypeSchema* find_schema(const ss_ &type)
{
	for(const TypeSchema &s : SCHEMA)
		if(type == s.type)
			return &s;
	return nullptr;
}

static Entity make_default(const TypeSchema &s)
{
	Entity e;
	e.type = s.type;
	for(const IntField &f : s.ints)
		e.ints[f.name] = f.def;
	for(const StrField &f : s.strs)
		e.strs[f.name] = f.def;
	for(const ListField &f : s.lists)
		e.lists[f.name] = {};
	return e;
}

static bool valid_text(const ss_ &s)
{
	for(unsigned char c : s)
		if(c < 0x20 || c == 0x7f)
			return false;
	return true;
}

// PBKDF2-HMAC-SHA256 with one 32-byte block
static ss_ hmac_sha256(const ss_ &key_in, const ss_ &msg)
{
	ss_ key = key_in.size() > 64 ? interface::sha256::calculate(key_in) :
			key_in;
	key.resize(64, '\0');
	ss_ ipad(64, '\0'), opad(64, '\0');
	for(int i = 0; i < 64; i++){
		ipad[i] = key[i] ^ 0x36;
		opad[i] = key[i] ^ 0x5c;
	}
	return interface::sha256::calculate(opad +
			interface::sha256::calculate(ipad + msg));
}

static ss_ pbkdf2_sha256(const ss_ &password, const ss_ &salt, int iterations)
{
	ss_ u = hmac_sha256(password, salt + ss_("\0\0\0\1", 4));
	ss_ t = u;
	for(int i = 1; i < iterations; i++){
		u = hmac_sha256(password, u);
		for(size_t j = 0; j < t.size(); j++)
			t[j] ^= u[j];
	}
	return t;
}

// RFC 7914's PBKDF2-HMAC-SHA256 vectors. Run at every start: a wrong hash
// would lock everybody out of every save, silently.
static void check_pbkdf2()
{
	const ss_ a = interface::sha256::hex(pbkdf2_sha256("password", "salt", 1));
	const ss_ b = interface::sha256::hex(pbkdf2_sha256("password", "salt", 2));
	if(a != "120fb6cffcf8b32c43e7225256c4f837"
			"a86548c92ccc35480805987cb70be17b" ||
			b != "ae4d0c95af6b46d32d0adff928f06dd0"
			"2a303f8ef3c251dfd6e2d85a95474c43")
		throw Exception("floorplanner: PBKDF2-HMAC-SHA256 self-check failed");
}

struct Account
{
	ss_ salt;
	ss_ hash;
	sv_<ss_> privs;

	template<class Archive>
	void serialize(Archive &archive){
		archive(salt, hash, privs);
	}
	bool has(const ss_ &priv) const {
		for(const ss_ &p : privs)
			if(p == priv)
				return true;
		return false;
	}
};

// Who may make an account: the server's store's ([FP_ACCESS] 3,
// [FP_PLANS] 1), which only an admin's requests change
struct AccessSettings
{
	uint8_t open_registration = 0;

	template<class Archive>
	void serialize(Archive &archive){
		archive(open_registration);
	}
};

// A one-time invite ([FP_ACCESS] 2): the admin who made it. What its
// account may do is each plan's ([FP_PLANS] 2); privs is kept empty
struct Invite
{
	sv_<ss_> privs;
	ss_ by;

	template<class Archive>
	void serialize(Archive &archive){
		archive(privs, by);
	}
};

// Failed logins of one name or one address ([FP_ACCESS] 5): a wait that
// doubles with each, up to a minute, and after FAIL_LOCK of them in the
// window a lock of the window's length
struct Failures
{
	int count = 0;
	int64_t first_us = 0;
	int64_t wait_until_us = 0;
};
static const int64_t FAIL_WINDOW_US = 600LL * 1000000;
static const int FAIL_LOCK = 10;
static const size_t MIN_PASSWORD = 6;

// A code to type: no 0/O or 1/I to mistake for each other
static ss_ random_code(size_t n)
{
	static const char *alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
	std::random_device rd;
	ss_ s;
	for(size_t i = 0; i < n; i++)
		s += alphabet[rd() % 32];
	return s;
}

static ss_ upper(ss_ s)
{
	for(char &c : s)
		c = (char)toupper((unsigned char)c);
	return s;
}

// Luanti's rule for a player name
static bool valid_name(const ss_ &name)
{
	if(name.empty() || name.size() > 20)
		return false;
	for(char c : name)
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	return true;
}

struct Op
{
	// 0 create, 1 set, 2 delete, 3 restore: create again under the id it
	// had, which is what an undo of a delete sends
	uint8_t op = 0;
	Entity ent;
	template<class Archive>
	void serialize(Archive &archive){
		archive(op, ent);
	}
};

// Where a user is and what they have selected, as the others are shown it
struct Presence
{
	uint8_t view = 0;         // 0 the plan, 1 the 3D camera
	int32_t cx = 0, cz = 0;   // the cursor on the floor, mm
	int32_t px = 0, py = 0, pz = 0; // the camera, mm
	int32_t yaw = 0, pitch = 0;     // millidegrees
	sv_<int32_t> sel;
	template<class Archive>
	void serialize(Archive &archive){
		archive(view, cx, cz, px, py, pz, yaw, pitch, sel);
	}
};

struct Peer
{
	ss_ name; // empty until logged in
	ss_ address;
	ss_ plan; // the plan the user is in ([FP_PLANS] 3), or ""

	int failures = 0;
	Presence presence;
	bool has_presence = false;
	// Rate limit: a bucket of operations refilled per second
	double op_budget = 0;
};

template<typename T>
static ss_ pack(const T &value)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar(value);
	}
	return os.str();
}

template<typename T>
static bool unpack(const ss_ &data, T &value)
{
	try {
		std::istringstream is(data, std::ios::binary);
		cereal::PortableBinaryInputArchive ar(is);
		ar(value);
		return true;
	} catch(std::exception &e){
		return false;
	}
}

static const double OPS_PER_SECOND = 400;
static const double OPS_BURST = 4000;

struct VoxelEdit
{
	int32_t seq = 0;
	int32_t def = 0;
	// cell -> palette entry, 0 for none
	std::map<int32_t, int32_t> sets;
	template<class Archive>
	void serialize(Archive &archive){
		archive(seq, def, sets);
	}
};

struct LockRequest
{
	int32_t seq = 0;
	sv_<int32_t> ids;
	template<class Archive>
	void serialize(Archive &archive){
		archive(seq, ids);
	}
};

struct Preview
{
	int32_t peer = 0;
	sv_<Entity> ents;
	template<class Archive>
	void serialize(Archive &archive){
		archive(peer, ents);
	}
};

struct PresenceOut
{
	int32_t peer = 0;
	ss_ name;
	Presence p;
	template<class Archive>
	void serialize(Archive &archive){
		archive(peer, name, p);
	}
};

static bool valid_voxel_key(int32_t key)
{
	// Three bytes, each a cell coordinate + VOXEL_RANGE
	return key >= 0 && key < (1 << 24);
}


// One open plan ([FP_PLANS] 3): its save, and all of it in memory. The
// server has open as many as are in use, and closes one PLAN_IDLE_S after
// the last user has left it.
struct Plan
{
	interface::Server *m_server;
	ss_ m_name;
	// Owned by builtin/storage, which closes it when it unloads
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;

	std::map<int32_t, Entity> m_ents;
	// Each voxel volume's voxels: the cell, packed as voxel_key() does, to
	// the palette entry it is made of. Kept when its definition is deleted,
	// so an undo that restores the definition gets them back.
	// simplified: a volume is one blob in the save and whole in memory; the
	// upgrade for big volumes is chunks, as voxelworld keeps them
	std::map<int32_t, std::map<int32_t, int32_t>> m_voxels;
	set_<int32_t> m_voxels_dirty;
	int32_t m_next_id = 1;
	set_<int32_t> m_dirty;
	// What is being dragged, and by whom: nobody else's batch may touch it
	std::map<int32_t, network::PeerId> m_locks;
	// The save's images/ as files for the clients: the pictures a plan can
	// be traced over. Put there by hand; a name is one file name.
	sv_<ss_> m_images;
	// Seconds with nobody in it
	float m_idle = 0;

	Plan(interface::Server *server, const ss_ &name):
		m_server(server), m_name(name)
	{}

	// <save>/backups/1 is the newest of BACKUPS; the save is closed, so its
	// write-ahead log is copied as it is
	void backup(const ss_ &path)
	{
		namespace fs = interface::fs;
		ss_ dir = path+"/backups";
		fs::create_directories(dir);
		if(fs::path_exists(dir+"/"+itos(BACKUPS)))
			fs::remove_all(dir+"/"+itos(BACKUPS));
		for(int i = BACKUPS - 1; i >= 1; i--){
			ss_ from = dir+"/"+itos(i);
			if(!fs::path_exists(from))
				continue;
			fs::create_directories(dir+"/"+itos(i + 1));
			for(const char *f : {"/save.sqlite", "/save.sqlite-wal"})
				if(fs::path_exists(from+f))
					fs::copy_file(from+f, dir+"/"+itos(i + 1)+f);
			fs::remove_all(from);
		}
		fs::create_directories(dir+"/1");
		bool ok = fs::copy_file(path+"/save.sqlite", dir+"/1/save.sqlite");
		if(fs::path_exists(path+"/save.sqlite-wal"))
			ok = fs::copy_file(path+"/save.sqlite-wal",
					dir+"/1/save.sqlite-wal") && ok;
		if(!ok)
			log_w(MODULE, "Could not back the plan up into %s", cs(dir));
	}

	void find_images()
	{
		namespace fs = interface::fs;
		m_images.clear();
		ss_ dir = m_save->path()+"/images";
		fs::create_directories(dir);
		for(const fs::Node &n : fs::list_directory(dir)){
			ss_ lower = n.name;
			for(char &c : lower)
				c = tolower(c);
			bool image = fs::check_file_extension(lower.c_str(), "png") ||
					fs::check_file_extension(lower.c_str(), "jpg") ||
					fs::check_file_extension(lower.c_str(), "jpeg");
			if(n.is_directory || !image || !valid_text(n.name) ||
					n.name.find('/') != ss_::npos || n.name[0] == '.')
				continue;
			if(fs::file_size(dir+"/"+n.name) > MAX_IMAGE_BYTES){
				log_w(MODULE, "Image %s is too big to send; skipped",
						cs(n.name));
				continue;
			}
			m_images.push_back(n.name);
			client_file::access(m_server, [&](client_file::Interface *i){
				i->add_file_path("main/images/"+m_name+"/"+n.name, dir+"/"+n.name);
			});
		}
		log_i(MODULE, "%zu images to trace over", m_images.size());
	}

	bool load()
	{
		m_ents.clear();
		ss_ version;
		if(m_store->get("schema_version", version) &&
				std::stoi(version) > SCHEMA_VERSION){
			// A newer build's plan: refused rather than dropping what it has
			log_e(MODULE, "The plan %s is from a newer version (schema %s)",
					cs(m_name), cs(version));
			return false;
		}
		int32_t stored = version.empty() ? SCHEMA_VERSION : std::stoi(version);
		for(const ss_ &key : m_store->list("e/")){
			ss_ data;
			Entity e;
			if(!m_store->get(key, data) || !unpack(data, e) ||
					!find_schema(e.type)){
				log_w(MODULE, "Unreadable entity %s; skipped", cs(key));
				continue;
			}
			// 1 -> 2: a palette entry's colour became its own colour, and
			// `color` the paint over it
			if(stored < 2 && e.type == "palette" && e.ints.count("color") &&
					!e.ints.count("base")){
				e.ints["base"] = e.ints["color"];
				e.ints["color"] = 0xffffff;
			}
			// A field added since it was saved takes its default, and one
			// that is gone goes
			Entity d = make_default(*find_schema(e.type));
			for(auto &pair : d.ints)
				if(e.ints.count(pair.first))
					pair.second = e.ints[pair.first];
			for(auto &pair : d.strs)
				if(e.strs.count(pair.first))
					pair.second = e.strs[pair.first];
			for(auto &pair : d.lists)
				if(e.lists.count(pair.first))
					pair.second = e.lists[pair.first];
			d.id = e.id;
			e = d;
			m_ents[e.id] = e;
			if(stored < SCHEMA_VERSION)
				m_dirty.insert(e.id);
			if(e.id >= m_next_id)
				m_next_id = e.id + 1;
		}
		// The singletons, and a first palette entry so a first wall has a
		// material
		for(const TypeSchema &s : SCHEMA){
			if(!s.singleton || find_singleton(s.type))
				continue;
			Entity e = make_default(s);
			e.id = m_next_id++;
			m_ents[e.id] = e;
			m_dirty.insert(e.id);
		}
		// 2 -> 3: a plan from before layouts is one, and so is a new one
		int32_t first_layout = 0;
		for(auto &pair : m_ents)
			if(pair.second.type == "layout"){
				first_layout = pair.first;
				break;
			}
		if(first_layout == 0){
			Entity e = make_default(*find_schema("layout"));
			e.id = first_layout = m_next_id++;
			m_ents[e.id] = e;
			m_dirty.insert(e.id);
		}
		for(auto &pair : m_ents){
			Entity &e = pair.second;
			auto it = e.ints.find("layout");
			if(it == e.ints.end())
				continue;
			auto l = m_ents.find(it->second);
			if(l == m_ents.end() || l->second.type != "layout"){
				it->second = first_layout;
				m_dirty.insert(e.id);
			}
		}
		if(m_ents.size() == count_type("settings") + count_type("layout")){
			Entity e = make_default(*find_schema("palette"));
			e.id = m_next_id++;
			e.strs["name"] = "white drywall";
			m_ents[e.id] = e;
			m_dirty.insert(e.id);
		}
		m_voxels.clear();
		for(const ss_ &key : m_store->list("v/")){
			ss_ data;
			std::map<int32_t, int32_t> voxels;
			if(m_store->get(key, data) && unpack(data, voxels))
				m_voxels[std::stoi(key.substr(2))] = voxels;
		}
		m_store->set("schema_version", itos(SCHEMA_VERSION));
		log_i(MODULE, "Loaded %s: %zu entities and %zu voxel volumes",
				cs(m_name), m_ents.size(), m_voxels.size());
		return true;
	}

	size_t count_type(const ss_ &type)
	{
		size_t n = 0;
		for(auto &pair : m_ents)
			if(pair.second.type == type)
				n++;
		return n;
	}

	Entity* find_singleton(const ss_ &type)
	{
		for(auto &pair : m_ents)
			if(pair.second.type == type)
				return &pair.second;
		return nullptr;
	}

	void flush()
	{
		if(!m_store || (m_dirty.empty() && m_voxels_dirty.empty()))
			return;
		m_store->batch([&](){
			for(int32_t id : m_dirty){
				ss_ key = "e/"+itos(id);
				auto it = m_ents.find(id);
				if(it == m_ents.end())
					m_store->remove(key);
				else
					m_store->set(key, pack(it->second));
			}
			for(int32_t def : m_voxels_dirty)
				m_store->set("v/"+itos(def), pack(m_voxels[def]));
		});
		m_dirty.clear();
		m_voxels_dirty.clear();
	}


	// Applies ops to the document, all or nothing. On success returns ""
	// and fills changed and deleted; on failure the document is as it was.
	ss_ apply(const sv_<Op> &ops, std::map<int32_t, int32_t> &placeholders,
			set_<int32_t> &changed, set_<int32_t> &deleted)
	{
		// The previous state of every entity touched, for rolling back
		std::map<int32_t, std::pair<bool, Entity>> journal;
		int32_t next_id_before = m_next_id;
		auto touch = [&](int32_t id){
			if(journal.count(id))
				return;
			auto it = m_ents.find(id);
			journal[id] = it == m_ents.end() ? std::make_pair(false, Entity())
					: std::make_pair(true, it->second);
		};
		auto rollback = [&](const ss_ &error){
			for(auto &pair : journal){
				if(pair.second.first)
					m_ents[pair.first] = pair.second.second;
				else
					m_ents.erase(pair.first);
			}
			m_next_id = next_id_before;
			placeholders.clear();
			changed.clear();
			deleted.clear();
			return error;
		};
		auto resolve = [&](int32_t id) -> int32_t {
			if(id >= 0)
				return id;
			auto it = placeholders.find(id);
			return it == placeholders.end() ? -1 : it->second;
		};

		for(const Op &op : ops){
			const Entity &in = op.ent;
			if(op.op == 0){
				const TypeSchema *s = find_schema(in.type);
				if(!s || s->singleton)
					return rollback("Cannot create a \""+in.type+"\"");
				if(in.id >= 0 || placeholders.count(in.id))
					return rollback("A new entity needs a fresh negative id");
				if(m_ents.size() >= MAX_ENTITIES)
					return rollback("The plan is full");
				Entity e = make_default(*s);
				e.id = m_next_id++;
				placeholders[in.id] = e.id;
				touch(e.id);
				m_ents[e.id] = e;
				ss_ err = set_fields(e.id, in, resolve);
				if(!err.empty())
					return rollback(err);
				changed.insert(e.id);
			} else if(op.op == 1){
				int32_t id = resolve(in.id);
				if(!m_ents.count(id))
					return rollback("No entity "+itos(in.id));
				touch(id);
				ss_ err = set_fields(id, in, resolve);
				if(!err.empty())
					return rollback(err);
				changed.insert(id);
			} else if(op.op == 3){
				const TypeSchema *s = find_schema(in.type);
				if(!s || s->singleton)
					return rollback("Cannot restore a \""+in.type+"\"");
				if(in.id <= 0 || in.id >= m_next_id || m_ents.count(in.id))
					return rollback("Entity "+itos(in.id)+
							" cannot be restored");
				if(m_ents.size() >= MAX_ENTITIES)
					return rollback("The plan is full");
				Entity e = make_default(*s);
				e.id = in.id;
				touch(e.id);
				m_ents[e.id] = e;
				ss_ err = set_fields(e.id, in, resolve);
				if(!err.empty())
					return rollback(err);
				changed.insert(e.id);
				deleted.erase(e.id);
			} else if(op.op == 2){
				int32_t id = resolve(in.id);
				auto it = m_ents.find(id);
				if(it == m_ents.end())
					return rollback("No entity "+itos(in.id));
				if(find_schema(it->second.type)->singleton)
					return rollback("Cannot delete the "+it->second.type);
				touch(id);
				m_ents.erase(it);
				deleted.insert(id);
			} else {
				return rollback("Unknown operation");
			}
		}

		// What the deletes do to what referred to them, to a fixpoint: a
		// cascade can delete what something else refers to
		set_<int32_t> processed;
		for(;;){
			set_<int32_t> pending;
			for(int32_t id : deleted)
				if(!processed.count(id))
					pending.insert(id);
			if(pending.empty())
				break;
			processed.insert(pending.begin(), pending.end());
			sv_<int32_t> cascade;
			for(auto &pair : m_ents){
				Entity &e = pair.second;
				const TypeSchema *s = find_schema(e.type);
				for(const IntField &f : s->ints){
					if(!f.ref || !pending.count(e.ints[f.name]))
						continue;
					if(f.on_delete == OnDelete::Restrict)
						return rollback("A "+ss_(f.ref)+" still in use by "
								"a "+e.type+" cannot be deleted");
					cascade.push_back(e.id);
				}
				for(const ListField &f : s->lists){
					sv_<int32_t> &list = e.lists[f.name];
					sv_<int32_t> kept;
					for(int32_t v : list)
						if(!pending.count(v))
							kept.push_back(v);
					if(kept.size() == list.size())
						continue;
					if(f.on_delete == OnDelete::Restrict)
						return rollback("A "+ss_(f.ref)+" still in use by "
								"a "+e.type+" cannot be deleted");
					touch(e.id);
					list = kept;
					changed.insert(e.id);
					if(list.size() < f.min_len)
						cascade.push_back(e.id);
				}
			}
			for(int32_t id : cascade){
				touch(id);
				m_ents.erase(id);
				deleted.insert(id);
			}
		}

		// A palette entry voxels are made of is in use, as much as one a
		// wall is made of
		for(int32_t id : deleted){
			auto it = journal.find(id);
			if(it == journal.end() || !it->second.first ||
					it->second.second.type != "palette")
				continue;
			for(auto &vol : m_voxels){
				if(!m_ents.count(vol.first))
					continue;
				for(auto &v : vol.second)
					if(v.second == id)
						return rollback("A palette entry still in use by "
								"voxels cannot be deleted");
			}
		}

		// Every reference of what changed points at what it may
		for(int32_t id : changed){
			if(deleted.count(id))
				continue;
			ss_ err = check_refs(m_ents[id]);
			if(!err.empty())
				return rollback(err);
		}

		for(auto &pair : journal)
			m_dirty.insert(pair.first);
		return "";
	}

	// Sets the fields in `in` on entity id, with placeholders resolved and
	// every value checked against the schema. References are checked
	// after the whole batch, since they can point at what comes later.
	ss_ set_fields(int32_t id, const Entity &in,
			const std::function<int32_t(int32_t)> &resolve)
	{
		Entity &e = m_ents[id];
		const TypeSchema *s = find_schema(e.type);
		if(!in.type.empty() && in.type != e.type)
			return "Entity "+itos(id)+" is a "+e.type+", not a "+in.type;
		for(auto &pair : in.ints){
			const IntField *f = nullptr;
			for(const IntField &ff : s->ints)
				if(pair.first == ff.name)
					f = &ff;
			if(!f)
				return "A "+e.type+" has no field "+pair.first;
			int32_t v = pair.second;
			if(f->ref){
				v = resolve(v);
				if(v == 0 && f->optional){
					e.ints[f->name] = 0;
					continue;
				}
			}
			if(v < f->min || v > f->max)
				return e.type+"."+pair.first+" out of range";
			e.ints[f->name] = v;
		}
		for(auto &pair : in.strs){
			const StrField *f = nullptr;
			for(const StrField &ff : s->strs)
				if(pair.first == ff.name)
					f = &ff;
			if(!f)
				return "A "+e.type+" has no field "+pair.first;
			if(pair.second.size() > MAX_STRING ||
					!valid_text(pair.second))
				return e.type+"."+pair.first+" is not a valid text";
			e.strs[f->name] = pair.second;
		}
		for(auto &pair : in.lists){
			const ListField *f = nullptr;
			for(const ListField &ff : s->lists)
				if(pair.first == ff.name)
					f = &ff;
			if(!f)
				return "A "+e.type+" has no field "+pair.first;
			if(pair.second.size() > MAX_LIST ||
					pair.second.size() < f->min_len)
				return e.type+"."+pair.first+" has a wrong length";
			sv_<int32_t> list;
			for(int32_t v : pair.second)
				list.push_back(resolve(v));
			e.lists[f->name] = list;
		}
		return "";
	}

	ss_ check_refs(const Entity &e)
	{
		const TypeSchema *s = find_schema(e.type);
		auto is_a = [&](int32_t id, const char *type){
			auto it = m_ents.find(id);
			return it != m_ents.end() && it->second.type == type;
		};
		for(const IntField &f : s->ints){
			if(!f.ref)
				continue;
			int32_t v = e.ints.at(f.name);
			if(v == 0 && f.optional)
				continue;
			if(!is_a(v, f.ref))
				return e.type+"."+f.name+" is not a "+f.ref;
		}
		for(const ListField &f : s->lists){
			set_<int32_t> seen;
			for(int32_t v : e.lists.at(f.name)){
				if(!is_a(v, f.ref))
					return e.type+"."+f.name+" holds what is not a "+f.ref;
				if(!seen.insert(v).second)
					return e.type+"."+f.name+" holds an id twice";
			}
		}
		if(e.type == "wall" && e.ints.at("a") == e.ints.at("b"))
			return "A wall needs two different nodes";
		if(e.type == "instance"){
			const Entity &def = m_ents[e.ints.at("def")];
			int32_t kind = def.ints.at("kind");
			bool hosted = kind == DK_OPENING || kind == DK_DOOR ||
					kind == DK_WINDOW;
			int32_t host = e.ints.at("host");
			// A switch goes on a wall or anywhere
			if(kind != DK_SWITCH && hosted != (host != 0))
				return hosted ? "An opening needs a wall" :
						"Only openings, doors, windows and switches go in a wall";
			if(!e.lists.at("lamps").empty() && kind != DK_SWITCH)
				return "Only a switch has lamps";
			// It fits the wall it is put in. Checked when the instance
			// changes, not when the wall does: a wall shortened under a
			// door is the user's to sort out, not a refused drag.
			if(host){
				const Entity &w = m_ents[host];
				const Entity &a = m_ents[w.ints.at("a")];
				const Entity &b = m_ents[w.ints.at("b")];
				double dx = b.ints.at("x") - a.ints.at("x");
				double dz = b.ints.at("z") - a.ints.at("z");
				double len = std::sqrt(dx * dx + dz * dz);
				double along = e.ints.at("along");
				double half = def.ints.at("w") / 2.0;
				if(along - half < 0 || along + half > len)
					return "It does not fit its wall";
			}
		}
		return "";
	}
};

// How long a plan with nobody in it stays open ([FP_PLANS] 3)
static const float PLAN_IDLE_S = 60;
// A plan's role for a user ([FP_PLANS] 2), as meta/public gives it to
// everyone who has none of their own
static const int32_t PUBLIC_NONE = 0, PUBLIC_READ = 1, PUBLIC_EDIT = 2;

// A plan's name: what a save's directory can be called on every system,
// and never the server's own store, whose name begins with _
static bool valid_plan_name(const ss_ &name)
{
	if(name.empty() || name.size() > 40 || name[0] == '_')
		return false;
	for(char c : name)
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	return true;
}

struct Module: public interface::Module
{
	interface::Server *m_server;
	// The server's own store ([FP_PLANS] 1): the accounts, the invites and
	// the access settings, in the save _server, which is no plan
	storage::Save *m_accounts_save = nullptr;
	storage::Store *m_accounts = nullptr;
	// The plans in use, by name
	std::map<ss_, up_<Plan>> m_plans;
	float m_flush_timer = 0;

	std::map<network::PeerId, Peer> m_peers;
	// [FP_ACCESS]: the server's access settings, the code that claims it
	// while no account is an admin (empty when one is), and the failed
	// logins by name and by address
	AccessSettings m_access;
	ss_ m_setup_code;
	std::map<ss_, Failures> m_name_failures;
	std::map<ss_, Failures> m_address_failures;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		check_pbkdf2();
	}

	~Module(){}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		for(const char *name : {"fp:login", "fp:open", "fp:leave_plan",
				"fp:copy_plan", "fp:plan_admin", "fp:batch", "fp:chat",
				"fp:admin", "fp:passwd", "fp:voxels", "fp:lock", "fp:unlock",
				"fp:preview", "fp:presence"})
			m_server->sub_event(this,
					Event::t(ss_("network:packet_received/")+name));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_start)
		EVENT_VOIDN("core:unload", flush_all)
		EVENT_VOIDN("core:shutdown", flush_all)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/fp:login", on_login,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:open", on_open,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:leave_plan", on_leave_plan,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:copy_plan", on_copy_plan,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:plan_admin", on_plan_admin,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:batch", on_batch,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:chat", on_chat,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:admin", on_admin,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:passwd", on_passwd,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:voxels", on_voxels,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:lock", on_lock,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:unlock", on_unlock,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:preview", on_preview,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:presence", on_presence,
				network::Packet)
	}

	// The start

	// One key of what the launcher asked for through the server's -u, as
	// games/vanilla reads it: a value of the shape a save name has, or ""
	ss_ launch_param(const ss_ &key_name)
	{
		const ss_ u = m_server->get_config().get<ss_>("untrusted_launch");
		const ss_ key = key_name+"=";
		size_t at = u.find(key);
		if(at == ss_::npos || !(at == 0 || u[at - 1] == '\n'))
			return "";
		ss_ v = u.substr(at + key.size());
		v = v.substr(0, v.find('\n'));
		for(char c : v)
			if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
				return "";
		return v.size() <= 64 ? v : "";
	}

	// Started from the launch grid ([FP_LAUNCH]): the local user joins
	// without a password, and is the first admin
	bool m_launched = false;
	// A plan the launcher named (save=<name>), which the local user is
	// offered first
	ss_ m_launch_plan;

	void on_start()
	{
		m_launched = launch_param("pick") == "1";
		m_launch_plan = launch_param("save");
		if(m_accounts)
			return;
		storage::access(m_server, [&](storage::Interface *istorage){
			m_accounts_save = istorage->open("_server");
			if(!m_accounts_save)
				m_accounts_save = istorage->create("_server");
		});
		if(!m_accounts_save){
			m_server->shutdown(1, "floorplanner: no server store");
			return;
		}
		m_accounts = m_accounts_save->store("accounts");
		load_access();
	}

	// Plans

	// The plan of that name in use, opened (with create, made when it is not
	// there) if it is not; nullptr if it could not be
	Plan* open_plan(const ss_ &name, bool create)
	{
		auto it = m_plans.find(name);
		if(it != m_plans.end())
			return it->second.get();
		if(!valid_plan_name(name))
			return nullptr;
		up_<Plan> plan(new Plan(m_server, name));
		storage::access(m_server, [&](storage::Interface *istorage){
			plan->m_save = istorage->open(name);
			if(plan->m_save){
				// A copy of the plan as it was, before anything touches it:
				// what an undo that lives only for a session cannot give
				// back
				ss_ path = plan->m_save->path();
				istorage->close(plan->m_save);
				plan->backup(path);
				plan->m_save = istorage->open(name);
			} else if(create){
				plan->m_save = istorage->create(name);
			}
		});
		if(!plan->m_save){
			log_w(MODULE, "Could not open or create the plan %s", cs(name));
			return nullptr;
		}
		plan->m_store = plan->m_save->store("main");
		if(!plan->load()){
			close_save(plan.get());
			return nullptr;
		}
		plan->find_images();
		log_i(MODULE, "Opened the plan %s", cs(name));
		Plan *p = plan.get();
		m_plans[name] = std::move(plan);
		return p;
	}

	void close_save(Plan *plan)
	{
		storage::access(m_server, [&](storage::Interface *istorage){
			istorage->close(plan->m_save);
		});
		plan->m_save = nullptr;
		plan->m_store = nullptr;
	}

	void close_plan(const ss_ &name)
	{
		auto it = m_plans.find(name);
		if(it == m_plans.end())
			return;
		it->second->flush();
		close_save(it->second.get());
		m_plans.erase(it);
		log_i(MODULE, "Closed the plan %s", cs(name));
	}

	void flush_all()
	{
		for(auto &pair : m_plans)
			pair.second->flush();
	}

	sv_<ss_> plan_names()
	{
		sv_<ss_> names;
		storage::access(m_server, [&](storage::Interface *istorage){
			for(const storage::SaveInfo &i : istorage->list())
				if(valid_plan_name(i.name))
					names.push_back(i.name);
		});
		std::sort(names.begin(), names.end());
		return names;
	}

	// Who a plan is whose ([FP_PLANS] 2): read from the plan's store, which
	// for a plan not in use is opened for it
	struct PlanMeta
	{
		ss_ owner;
		int32_t pub = PUBLIC_READ;
		std::map<ss_, ss_> roles; // name -> editor or viewer
	};

	PlanMeta read_meta(storage::Store *store)
	{
		PlanMeta m;
		ss_ v;
		if(store->get("meta/owner", v))
			m.owner = v;
		if(store->get("meta/public", v))
			m.pub = std::max(PUBLIC_NONE, std::min(PUBLIC_EDIT, atoi(v.c_str())));
		for(const ss_ &key : store->list("role/"))
			if(store->get(key, v))
				m.roles[key.substr(5)] = v;
		return m;
	}

	PlanMeta plan_meta(const ss_ &name)
	{
		auto it = m_plans.find(name);
		if(it != m_plans.end())
			return read_meta(it->second->m_store);
		PlanMeta m;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(name);
			if(!save)
				return;
			m = read_meta(save->store("main"));
			istorage->close(save);
		});
		return m;
	}

	bool is_admin(const ss_ &user)
	{
		Account account;
		return !user.empty() && get_account(user, account) &&
				account.has("admin");
	}

	// What a user is in a plan: admin, owner, editor, viewer, or "" (not
	// let in)
	ss_ role_in(const PlanMeta &m, const ss_ &user)
	{
		// Owner first: the admin's own plan is theirs as well
		if(!m.owner.empty() && m.owner == user)
			return "owner";
		if(is_admin(user))
			return "admin";
		auto it = m.roles.find(user);
		if(it != m.roles.end())
			return it->second;
		return m.pub == PUBLIC_EDIT ? "editor" :
				m.pub == PUBLIC_READ ? "viewer" : "";
	}

	static bool role_edits(const ss_ &role)
	{
		return role == "admin" || role == "owner" || role == "editor";
	}

	static bool role_manages(const ss_ &role)
	{
		return role == "admin" || role == "owner";
	}

	Plan* plan_of(network::PeerId peer)
	{
		auto it = m_peers.find(peer);
		if(it == m_peers.end() || it->second.name.empty() ||
				it->second.plan.empty())
			return nullptr;
		auto p = m_plans.find(it->second.plan);
		return p == m_plans.end() ? nullptr : p->second.get();
	}

	ss_ peer_role(network::PeerId peer)
	{
		Plan *plan = plan_of(peer);
		return plan ? role_in(read_meta(plan->m_store), m_peers[peer].name) : "";
	}

	bool can_edit(network::PeerId peer)
	{
		return role_edits(peer_role(peer));
	}

	struct PlanRow
	{
		ss_ name;
		ss_ owner;
		ss_ role;       // the user's
		int32_t here = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, owner, role, here);
		}
	};

	// The plans a user may read, to open one or make one ([FP_PLANS] 4)
	void send_plans(network::PeerId peer)
	{
		const ss_ user = m_peers[peer].name;
		sv_<PlanRow> rows;
		for(const ss_ &name : plan_names()){
			PlanMeta m = plan_meta(name);
			PlanRow row;
			row.name = name;
			row.owner = m.owner;
			row.role = role_in(m, user);
			if(row.role.empty())
				continue;
			for(auto &pair : m_peers)
				if(pair.second.plan == name && !pair.second.name.empty())
					row.here++;
			rows.push_back(row);
		}
		send(peer, "fp:plans", pack(rows));
	}

	// A user into a plan: what it holds, where the others in it are, and what
	// this user may do in it
	void enter_plan(network::PeerId peer_id, Plan *plan)
	{
		Peer &peer = m_peers[peer_id];
		leave_plan(peer_id);
		peer.plan = plan->m_name;
		peer.has_presence = false;
		plan->m_idle = 0;
		send(peer_id, "fp:entered", pack(plan->m_name));
		send_privs(peer_id);
		sv_<Entity> all;
		for(auto &pair : plan->m_ents)
			all.push_back(pair.second);
		send(peer_id, "fp:snapshot", pack(all));
		send(peer_id, "fp:images", pack(plan->m_images));
		for(auto &pair : plan->m_voxels){
			if(!plan->m_ents.count(pair.first))
				continue;
			VoxelEdit v;
			v.seq = -1;
			v.def = pair.first;
			v.sets = pair.second;
			send(peer_id, "fp:voxels", pack(v));
		}
		// Where the others are
		for(auto &pair : m_peers){
			if(pair.first == peer_id || pair.second.plan != plan->m_name ||
					!pair.second.has_presence)
				continue;
			PresenceOut out;
			out.peer = (int32_t)pair.first;
			out.name = pair.second.name;
			out.p = pair.second.presence;
			send(peer_id, "fp:presence", pack(out));
		}
		log_i(MODULE, "%s entered the plan %s", cs(peer.name),
				cs(plan->m_name));
		send_to_plan(plan->m_name, "fp:chat", pack("*** "+peer.name+" joined"));
		if(role_manages(peer_role(peer_id)))
			send_members(peer_id);
	}

	// Out of the plan the user is in, if any: their locks go, the others
	// stop showing them
	void leave_plan(network::PeerId peer_id)
	{
		auto it = m_peers.find(peer_id);
		if(it == m_peers.end() || it->second.plan.empty())
			return;
		const ss_ plan = it->second.plan;
		it->second.plan.clear();
		it->second.has_presence = false;
		auto p = m_plans.find(plan);
		if(p != m_plans.end())
			unlock_all(*p->second, peer_id);
		send_to_plan(plan, "fp:gone", pack((int32_t)peer_id));
		if(!it->second.name.empty())
			send_to_plan(plan, "fp:chat", pack("*** "+it->second.name+" left"));
	}

	// Out of the plan and back to the plans page
	void to_plans(network::PeerId peer, const ss_ &why)
	{
		leave_plan(peer);
		send(peer, "fp:closed", pack(why));
		send_plans(peer);
	}

	struct OpenRequest
	{
		ss_ name;
		uint8_t create = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, create);
		}
	};

	void on_open(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		OpenRequest req;
		if(it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, req))
			return;
		const ss_ user = it->second.name;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:open_result", pack(why));
		};
		if(!valid_plan_name(req.name))
			return refuse("A plan's name is 1 to 40 letters, digits, _ or -, "
					"not starting with _");
		bool exists = false;
		for(const ss_ &n : plan_names())
			exists |= n == req.name;
		if(req.create && exists)
			return refuse("There is a plan called "+req.name+" already");
		if(!req.create && !exists)
			return refuse("There is no plan called "+req.name);
		if(exists && role_in(plan_meta(req.name), user).empty())
			return refuse("The plan "+req.name+" is not open to you");
		Plan *plan = open_plan(req.name, req.create);
		if(!plan)
			return refuse("Could not open the plan "+req.name);
		if(req.create){
			// Anyone can make a plan, and it is theirs
			plan->m_store->set("meta/owner", user);
			log_i(MODULE, "%s made the plan %s", cs(user), cs(req.name));
		}
		refuse("");
		enter_plan(packet.sender, plan);
		send_plans_to_idle();
	}

	void on_leave_plan(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(it == m_peers.end() || it->second.name.empty())
			return;
		to_plans(packet.sender, "");
		send_plans_to_idle();
	}

	// The others on the plans page see who is in which
	void send_plans_to_idle()
	{
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan.empty())
				send_plans(pair.first);
	}

	// **A copy of the plan under a new name, which is the copier's**
	// ([FP_COPY], [FP_PLANS] 5). The plan is flushed first, and nothing
	// writes to it until the copy is done, so its database and write-ahead
	// log are copied as they are; its images go with it, its backups and
	// its members do not.
	void on_copy_plan(const network::Packet &packet)
	{
		ss_ name;
		Plan *from_plan = plan_of(packet.sender);
		if(!from_plan || !unpack(packet.data, name))
			return;
		const ss_ user = m_peers[packet.sender].name;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:open_result", pack(why));
		};
		if(!valid_plan_name(name))
			return refuse("\""+name+"\" is not a name a plan can have");
		for(const ss_ &n : plan_names())
			if(n == name)
				return refuse("There is a plan called \""+name+"\" already");
		namespace fs = interface::fs;
		from_plan->flush();
		const ss_ from = from_plan->m_save->path();
		const size_t slash = from.find_last_of("/\\");
		const ss_ to = (slash == ss_::npos ? ss_(".") : from.substr(0, slash))+
				"/"+name;
		fs::create_directories(to+"/images");
		bool ok = fs::copy_file(from+"/save.sqlite", to+"/save.sqlite");
		if(fs::path_exists(from+"/save.sqlite-wal"))
			ok = fs::copy_file(from+"/save.sqlite-wal", to+"/save.sqlite-wal") &&
					ok;
		for(const fs::Node &n : fs::list_directory(from+"/images"))
			if(!n.is_directory)
				ok = fs::copy_file(from+"/images/"+n.name, to+"/images/"+n.name) &&
						ok;
		Plan *copy = ok ? open_plan(name, false) : nullptr;
		if(!copy){
			log_e(MODULE, "Could not copy the plan %s into %s",
					cs(from_plan->m_name), cs(to));
			fs::remove_all(to);
			return refuse("Could not copy the plan");
		}
		copy->m_store->set("meta/owner", user);
		copy->m_store->set("meta/public", itos(PUBLIC_READ));
		for(const ss_ &key : copy->m_store->list("role/"))
			copy->m_store->remove(key);
		log_i(MODULE, "%s copied the plan %s as %s", cs(user),
				cs(from_plan->m_name), cs(name));
		refuse("");
		enter_plan(packet.sender, copy);
		send_plans_to_idle();
	}

	// A plan's members and visibility ([FP_PLANS] 5), its owner's and an
	// admin's: every account with its role here
	struct MemberRow
	{
		ss_ name;
		ss_ role;
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, role);
		}
	};

	struct MembersInfo
	{
		ss_ plan;
		ss_ owner;
		int32_t pub = PUBLIC_READ;
		sv_<MemberRow> members;
		template<class Archive>
		void serialize(Archive &archive){
			archive(plan, owner, pub, members);
		}
	};

	void send_members(network::PeerId peer)
	{
		Plan *plan = plan_of(peer);
		if(!plan)
			return;
		PlanMeta m = read_meta(plan->m_store);
		MembersInfo info;
		info.plan = plan->m_name;
		info.owner = m.owner;
		info.pub = m.pub;
		for(const ss_ &key : m_accounts->list("auth/")){
			MemberRow row;
			row.name = key.substr(5);
			auto it = m.roles.find(row.name);
			row.role = it == m.roles.end() ? "" : it->second;
			info.members.push_back(row);
		}
		send(peer, "fp:members", pack(info));
	}

	// Everyone in the plan, after its members changed: what they may do, and
	// for those who manage it the list
	void plan_rights_changed(Plan *plan)
	{
		for(auto &pair : m_peers){
			if(pair.second.plan != plan->m_name || pair.second.name.empty())
				continue;
			const ss_ role = peer_role(pair.first);
			if(role.empty()){
				to_plans(pair.first, "You are no longer let into this plan");
				continue;
			}
			send_privs(pair.first);
			if(role_manages(role))
				send_members(pair.first);
		}
		send_plans_to_idle();
	}

	void on_plan_admin(const network::Packet &packet)
	{
		AdminRequest r;
		Plan *plan = plan_of(packet.sender);
		if(!plan || !role_manages(peer_role(packet.sender)) ||
				!unpack(packet.data, r))
			return;
		const ss_ by = m_peers[packet.sender].name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "fp:admin_result", pack(text));
		};
		Account account;
		if(r.cmd == "list"){
			// The page as it opens: accounts made since they entered
			return send_members(packet.sender);
		} else if(r.cmd == "role"){
			if(!get_account(r.name, account))
				return result("No account "+r.name);
			if(r.arg != "" && r.arg != "editor" && r.arg != "viewer")
				return result("No such role");
			if(r.arg.empty())
				plan->m_store->remove("role/"+r.name);
			else
				plan->m_store->set("role/"+r.name, r.arg);
			log_i(MODULE, "%s made %s %s in %s", cs(by), cs(r.name),
					r.arg.empty() ? "no member" : cs(r.arg), cs(plan->m_name));
			result("");
		} else if(r.cmd == "public"){
			const int32_t v = atoi(r.arg.c_str());
			if(v < PUBLIC_NONE || v > PUBLIC_EDIT)
				return result("No such setting");
			plan->m_store->set("meta/public", itos(v));
			log_i(MODULE, "%s set the plan %s public to %i", cs(by),
					cs(plan->m_name), v);
			result("");
		} else if(r.cmd == "delete"){
			const ss_ name = plan->m_name;
			for(auto &pair : m_peers)
				if(pair.second.plan == name)
					to_plans(pair.first, "The plan was deleted by "+by);
			close_plan(name);
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->remove(name);
			});
			log_i(MODULE, "%s deleted the plan %s", cs(by), cs(name));
			send_plans_to_idle();
			return;
		} else {
			return;
		}
		plan_rights_changed(plan);
	}

	// The local user: on this machine, of a server the launcher started
	bool is_local(network::PeerId peer)
	{
		auto it = m_peers.find(peer);
		return m_launched && it != m_peers.end() &&
				(it->second.address == "127.0.0.1" ||
				it->second.address == "::1");
	}

	struct Hello
	{
		uint8_t local = 0;      // no password asked
		// [FP_ACCESS]: the join asks for the setup code (the server has no
		// admin), or says a new name needs an invite (registration is not
		// open)
		uint8_t setup = 0;
		uint8_t open_registration = 0;
		ss_ plan;               // what the launcher named, for the local user
		template<class Archive>
		void serialize(Archive &archive){
			archive(local, setup, open_registration, plan);
		}
	};

	// What the client shows first: the join, with a password or without
	void send_hello(network::PeerId peer)
	{
		Hello h;
		h.local = is_local(peer);
		h.setup = !h.local && !m_setup_code.empty();
		h.open_registration = m_access.open_registration;
		h.plan = h.local ? m_launch_plan : "";
		send(peer, "fp:hello", pack(h));
	}

	void on_tick(const interface::TickEvent &event)
	{
		m_flush_timer += event.dtime;
		if(m_flush_timer >= 1.0f){
			m_flush_timer = 0;
			flush_all();
		}
		for(auto &pair : m_peers){
			pair.second.op_budget = std::min(OPS_BURST,
					pair.second.op_budget + OPS_PER_SECOND * event.dtime);
		}
		// A plan nobody is in is saved and closed after a while
		sv_<ss_> idle;
		for(auto &pair : m_plans){
			bool used = false;
			for(auto &peer : m_peers)
				used |= peer.second.plan == pair.first;
			pair.second->m_idle = used ? 0 : pair.second->m_idle + event.dtime;
			if(pair.second->m_idle >= PLAN_IDLE_S)
				idle.push_back(pair.first);
		}
		for(const ss_ &name : idle)
			close_plan(name);
	}

	// Peers

	void on_client_connected(const network::NewClient &client)
	{
		Peer peer;
		peer.op_budget = OPS_BURST;
		peer.address = client.info.address;
		m_peers[client.info.id] = peer;
	}

	void on_client_disconnected(const network::OldClient &client)
	{
		auto it = m_peers.find(client.info.id);
		if(it == m_peers.end())
			return;
		const ss_ name = it->second.name;
		leave_plan(client.info.id);
		m_peers.erase(client.info.id);
		if(!name.empty()){
			send_users_to_admins();
			send_plans_to_idle();
		}
	}

	void unlock_all(Plan &plan, network::PeerId peer)
	{
		for(auto it = plan.m_locks.begin(); it != plan.m_locks.end();){
			if(it->second == peer)
				it = plan.m_locks.erase(it);
			else
				++it;
		}
	}

	// Voxels

	void on_voxels(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		Peer &peer = m_peers[packet.sender];
		VoxelEdit edit;
		std::pair<int32_t, ss_> result;
		if(!unpack(packet.data, edit)){
			result.second = "Malformed voxels";
		} else {
			result.first = edit.seq;
			result.second = check_voxels(*plan, packet.sender, edit);
		}
		if(result.second.empty()){
			peer.op_budget -= edit.sets.size() / 10.0;
			std::map<int32_t, int32_t> &voxels = plan->m_voxels[edit.def];
			for(auto &pair : edit.sets){
				if(pair.second == 0)
					voxels.erase(pair.first);
				else
					voxels[pair.first] = pair.second;
			}
			plan->m_voxels_dirty.insert(edit.def);
			// The sender's copy carries its number, as with fp:changes
			for(auto &pair : m_peers){
				if(pair.second.plan != plan->m_name || pair.second.name.empty())
					continue;
				edit.seq = pair.first == packet.sender ? result.first : -1;
				send(pair.first, "fp:voxels", pack(edit));
			}
		} else {
			log_i(MODULE, "Voxels from %s refused: %s", cs(peer.name),
					cs(result.second));
		}
		send(packet.sender, "fp:voxels_result", pack(result));
	}

	ss_ check_voxels(Plan &plan, network::PeerId sender, const VoxelEdit &edit)
	{
		if(!can_edit(sender))
			return "You cannot edit this plan";
		auto it = plan.m_ents.find(edit.def);
		if(it == plan.m_ents.end() || it->second.type != "definition" ||
				it->second.ints.at("kind") != DK_VOXEL)
			return "Not a voxel volume";
		auto lock = plan.m_locks.find(edit.def);
		if(lock != plan.m_locks.end() && lock->second != sender)
			return m_peers[lock->second].name+" is moving that";
		if(m_peers[sender].op_budget < edit.sets.size() / 10.0)
			return "Too many voxels at once; slow down";
		const std::map<int32_t, int32_t> &voxels = plan.m_voxels[edit.def];
		size_t added = 0;
		for(auto &pair : edit.sets){
			if(!valid_voxel_key(pair.first))
				return "A voxel outside the volume";
			if(pair.second != 0){
				auto p = plan.m_ents.find(pair.second);
				if(p == plan.m_ents.end() || p->second.type != "palette")
					return "A voxel of what is not a palette entry";
				if(!voxels.count(pair.first))
					added++;
			}
		}
		if(voxels.size() + added > MAX_VOXELS)
			return "The volume is full";
		return "";
	}

	// Drag locks, previews and presence

	void on_lock(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		LockRequest req;
		std::pair<int32_t, ss_> result;
		if(!plan || !unpack(packet.data, req) ||
				req.ids.size() > MAX_OPS_PER_BATCH)
			return;
		result.first = req.seq;
		if(!can_edit(packet.sender)){
			result.second = "You cannot edit this plan";
		} else {
			for(int32_t id : req.ids){
				auto it = plan->m_locks.find(id);
				if(it != plan->m_locks.end() && it->second != packet.sender){
					result.second = m_peers[it->second].name+
							" is moving that";
					break;
				}
			}
		}
		if(result.second.empty()){
			// One drag at a time: what this user held before is let go
			unlock_all(*plan, packet.sender);
			for(int32_t id : req.ids)
				plan->m_locks[id] = packet.sender;
		}
		send(packet.sender, "fp:lock_result", pack(result));
	}

	void on_unlock(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		unlock_all(*plan, packet.sender);
		// And what it was showing the others goes
		relay_preview(packet.sender, {});
	}

	void relay_preview(network::PeerId sender, const sv_<Entity> &ents)
	{
		Preview p;
		p.peer = (int32_t)sender;
		p.ents = ents;
		ss_ data = pack(p);
		const ss_ plan = m_peers[sender].plan;
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan &&
					pair.first != sender)
				send(pair.first, "fp:preview", data);
	}

	// A drag as it goes: where the dragged things would be, for the others
	// to draw. Nothing in the document changes until the drag's batch.
	void on_preview(const network::Packet &packet)
	{
		sv_<Entity> ents;
		if(!can_edit(packet.sender) || !unpack(packet.data, ents) ||
				ents.size() > MAX_OPS_PER_BATCH)
			return;
		relay_preview(packet.sender, ents);
	}

	void on_presence(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		Peer &peer = m_peers[packet.sender];
		Presence p;
		if(!unpack(packet.data, p) || p.sel.size() > 1000)
			return;
		peer.presence = p;
		peer.has_presence = true;
		PresenceOut out;
		out.peer = (int32_t)packet.sender;
		out.name = peer.name;
		out.p = p;
		ss_ data = pack(out);
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan->m_name &&
					pair.first != packet.sender)
				send(pair.first, "fp:presence", data);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
		send_hello(event.recipient);
	}

	void send(network::PeerId peer, const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, data);
		});
	}

	void send_to_plan(const ss_ &plan, const ss_ &name, const ss_ &data)
	{
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan)
				send(pair.first, name, data);
	}

	void send_chat(network::PeerId peer, const ss_ &text)
	{
		send(peer, "fp:chat", pack(text));
	}

	// Accounts

	bool get_account(const ss_ &name, Account &account)
	{
		ss_ data;
		return m_accounts->get("auth/"+name, data) && unpack(data, account);
	}

	void set_account(const ss_ &name, const Account &account)
	{
		m_accounts->set("auth/"+name, pack(account));
	}

	// What the user may do: the server's admin, and in the plan they are in
	// edit and manage it ([FP_PLANS] 2)
	void send_privs(network::PeerId peer)
	{
		sv_<ss_> privs;
		const ss_ role = peer_role(peer);
		if(is_admin(m_peers[peer].name))
			privs.push_back("admin");
		if(role_edits(role))
			privs.push_back("edit");
		if(role_manages(role))
			privs.push_back("manage");
		send(peer, "fp:privs", pack(privs));
	}

	network::PeerId find_peer(const ss_ &name)
	{
		for(auto &pair : m_peers)
			if(pair.second.name == name)
				return pair.first;
		return 0;
	}

	// Access ([FP_ACCESS])

	void save_access()
	{
		m_accounts->set("access/settings", pack(m_access));
	}

	void load_access()
	{
		ss_ data;
		if(!(m_accounts->get("access/settings", data) &&
				unpack(data, m_access))){
			// Registration open where the launcher started the server
			m_access = AccessSettings();
			m_access.open_registration = m_launched;
			save_access();
		}
		update_setup_code();
	}

	int admin_count()
	{
		int n = 0;
		for(const ss_ &key : m_accounts->list("auth/")){
			Account account;
			if(get_account(key.substr(5), account) && account.has("admin"))
				n++;
		}
		return n;
	}

	// A server with no admin is claimed with a code from its log
	// ([FP_ACCESS] 1): on a public server the first to connect would
	// otherwise be its admin
	void update_setup_code()
	{
		if(admin_count() > 0){
			m_setup_code.clear();
			return;
		}
		if(!m_setup_code.empty())
			return;
		m_setup_code = random_code(8);
		log_w(MODULE, "The server has no admin. The first to join with the "
				"setup code %s becomes it.", cs(m_setup_code));
	}

	// How long, in microseconds, before a login of this name or from this
	// address may be tried again
	int64_t failure_wait(std::map<ss_, Failures> &m, const ss_ &key, int64_t now)
	{
		auto it = m.find(key);
		if(it == m.end())
			return 0;
		if(now - it->second.first_us > FAIL_WINDOW_US &&
				now >= it->second.wait_until_us){
			m.erase(it);
			return 0;
		}
		return std::max((int64_t)0, it->second.wait_until_us - now);
	}

	void note_failure(std::map<ss_, Failures> &m, const ss_ &key, int64_t now)
	{
		Failures &f = m[key];
		if(f.count == 0 || now - f.first_us > FAIL_WINDOW_US){
			f.count = 0;
			f.first_us = now;
		}
		f.count++;
		const int64_t wait = f.count >= FAIL_LOCK ? FAIL_WINDOW_US :
				std::min((int64_t)60, (int64_t)1 << (f.count - 1)) * 1000000;
		f.wait_until_us = now + wait;
	}

	Account new_account(const ss_ &password, const sv_<ss_> &privs)
	{
		Account account;
		std::random_device rd;
		account.salt.resize(16);
		for(char &c : account.salt)
			c = (char)(rd() & 0xff);
		account.hash = pbkdf2_sha256(password, account.salt, PBKDF2_ITERATIONS);
		account.privs = privs;
		return account;
	}

	struct LoginRequest
	{
		ss_ name;
		ss_ password;
		ss_ code; // the setup code, or an invite code ([FP_ACCESS])
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, password, code);
		}
	};

	// Into the server ([FP_PLANS] 4); the plans come after.
	// simplified: the password arrives in the clear on a native client's
	// connection, because the transport is not encrypted yet ([TRANSPORT]);
	// the join dialog says so. The web client behind an https proxy has TLS.
	void on_login(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end() || !m_accounts)
			return;
		Peer &peer = pit->second;
		LoginRequest cred;
		auto reply = [&](const ss_ &error){
			send(packet.sender, "fp:login_result", pack(error));
		};
		// The local user is on the machine the plans are on: a password
		// would keep out nobody the files themselves do not let in
		bool local = is_local(packet.sender);
		if(!peer.name.empty())
			return reply("Already joined");
		if(peer.failures >= MAX_LOGIN_FAILURES)
			return reply("Too many failed attempts; reconnect");
		if(!unpack(packet.data, cred))
			return reply("Malformed login");
		const ss_ &name = cred.name;
		const ss_ &password = cred.password;
		const ss_ code = upper(cred.code);
		if(!valid_name(name))
			return reply("A name is 1 to 20 letters, digits, _ or -");
		if(password.size() > 100 || code.size() > 100)
			return reply("The password is too long");
		if(find_peer(name))
			return reply(name+" is already here");

		// [FP_ACCESS] 5: a name and an address that failed wait before
		// they are tried again
		const int64_t now = interface::os::time_us();
		const int64_t wait = std::max(
				failure_wait(m_name_failures, name, now),
				failure_wait(m_address_failures, peer.address, now));
		if(wait > 0 && !local){
			log_i(MODULE, "Login of %s from %s refused: waiting after failures",
					cs(name), cs(peer.address));
			return reply("Too many failed logins; try again in "+
					itos((int)((wait + 999999) / 1000000))+" s");
		}
		auto fail = [&](const ss_ &why){
			peer.failures++;
			note_failure(m_name_failures, name, now);
			note_failure(m_address_failures, peer.address, now);
			log_i(MODULE, "Login of %s from %s failed: %s", cs(name),
					cs(peer.address), cs(why));
			reply(why);
		};

		Account account;
		if(get_account(name, account)){
			if(!local && pbkdf2_sha256(password, account.salt,
					PBKDF2_ITERATIONS) != account.hash)
				return fail("Wrong password");
			// An account of a server that has no admin can claim it too
			if(!local && !m_setup_code.empty() && !code.empty()){
				if(code != m_setup_code)
					return fail("Wrong setup code");
				account.privs = {"admin"};
				set_account(name, account);
				log_i(MODULE, "%s claimed the server with the setup code",
						cs(name));
			}
		} else {
			sv_<ss_> privs;
			if(local){
				// The first admin of the launcher's server is its own user
				if(admin_count() == 0)
					privs = {"admin"};
			} else {
				if(password.size() < MIN_PASSWORD)
					return reply("A new account's password is at least "+
							itos((int)MIN_PASSWORD)+" characters");
				Invite invite;
				ss_ data;
				if(!m_setup_code.empty()){
					if(code != m_setup_code)
						return fail(code.empty() ?
								"This server has no admin yet: the first "
								"account needs the setup code from the "
								"server's log" : "Wrong setup code");
					privs = {"admin"};
					log_i(MODULE, "%s claimed the server with the setup code",
							cs(name));
				} else if(!code.empty()){
					if(!(m_accounts->get("invite/"+code, data) &&
							unpack(data, invite)))
						return fail("No such invite code");
					m_accounts->remove("invite/"+code);
					log_i(MODULE, "%s used an invite of %s", cs(name),
							cs(invite.by));
				} else if(!m_access.open_registration){
					return reply("New accounts need an invite code from an "
							"admin");
				}
			}
			// A local account gets a password nobody knows, so its name
			// cannot be taken over from elsewhere with an empty one
			ss_ pw = password;
			if(local)
				pw = random_code(32);
			account = new_account(pw, privs);
			set_account(name, account);
			log_i(MODULE, "New account %s", cs(name));
		}
		m_name_failures.erase(name);
		update_setup_code();
		log_i(MODULE, "%s joined from %s", cs(name), cs(peer.address));
		peer.name = name;
		reply("");
		send_privs(packet.sender);
		send_plans(packet.sender);
		send_users_to_admins();
	}

	// Chat, in the plan the user is in

	void on_chat(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		ss_ text;
		if(!unpack(packet.data, text) || text.empty() || text.size() > 500 ||
				!valid_text(text))
			return;
		// The chat commands are the pause menu's now ([FP_ACCESS] 4)
		if(text[0] == '/'){
			send_chat(packet.sender, "The commands are in the pause menu "
					"(Esc): Users..., Plan members..., Change password...");
			return;
		}
		send_to_plan(plan->m_name, "fp:chat",
				pack("<"+m_peers[packet.sender].name+"> "+text));
	}

	// The server admin's menus ([FP_ACCESS] 4): the accounts, the invites
	// and the access settings

	struct UserRow
	{
		ss_ name;
		sv_<ss_> privs;
		uint8_t here = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, privs, here);
		}
	};

	struct UsersInfo
	{
		sv_<UserRow> users;
		sv_<std::pair<ss_, Invite>> invites;
		AccessSettings access;
		template<class Archive>
		void serialize(Archive &archive){
			archive(users, invites, access);
		}
	};

	void send_users(network::PeerId peer)
	{
		UsersInfo info;
		for(const ss_ &key : m_accounts->list("auth/")){
			UserRow row;
			row.name = key.substr(5);
			Account account;
			if(get_account(row.name, account))
				row.privs = account.privs;
			row.here = find_peer(row.name) != 0;
			info.users.push_back(row);
		}
		for(const ss_ &key : m_accounts->list("invite/")){
			Invite invite;
			ss_ data;
			if(m_accounts->get(key, data) && unpack(data, invite))
				info.invites.push_back(std::make_pair(key.substr(7), invite));
		}
		info.access = m_access;
		send(peer, "fp:users", pack(info));
	}

	void send_users_to_admins()
	{
		for(auto &pair : m_peers)
			if(is_admin(pair.second.name))
				send_users(pair.first);
	}

	// Off the server: the client is told to leave, and is logged out here
	// meanwhile.
	// simplified: the network module has no way to drop a peer
	void kick(network::PeerId target, const ss_ &why)
	{
		leave_plan(target);
		send(target, "fp:kicked", pack(why));
		m_peers[target].name.clear();
		send_plans_to_idle();
	}

	struct AdminRequest
	{
		ss_ cmd;
		ss_ name;
		ss_ arg;
		uint8_t on = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(cmd, name, arg, on);
		}
	};

	void on_admin(const network::Packet &packet)
	{
		AdminRequest r;
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end() || !is_admin(pit->second.name) ||
				!unpack(packet.data, r))
			return;
		const ss_ by = pit->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "fp:admin_result", pack(text));
		};
		Account account;
		const bool exists = !r.name.empty() && get_account(r.name, account);
		const network::PeerId target = exists ? find_peer(r.name) : 0;
		if(r.cmd == "list"){
			return send_users(packet.sender);
		} else if(r.cmd == "priv"){
			if(!exists || r.arg != "admin")
				return result("No such account or privilege");
			if(!r.on && account.has("admin") && admin_count() <= 1)
				return result("The last admin keeps admin");
			account.privs = r.on ? sv_<ss_>{"admin"} : sv_<ss_>{};
			set_account(r.name, account);
			if(target)
				send_privs(target);
			log_i(MODULE, "%s %s admin %s", cs(by), r.on ? "granted" : "revoked",
					cs(r.name));
			result(r.name+(r.on ? " is an admin" : " is no longer an admin"));
		} else if(r.cmd == "kick"){
			if(!target)
				return result(r.name+" is not here");
			kick(target, "kicked by "+by);
			result(r.name+" was kicked");
		} else if(r.cmd == "password"){
			if(!exists)
				return result("No account "+r.name);
			if(r.arg.size() < MIN_PASSWORD || r.arg.size() > 100)
				return result("A password is "+itos((int)MIN_PASSWORD)+
						" to 100 characters");
			set_account(r.name, new_account(r.arg, account.privs));
			if(target && target != packet.sender)
				kick(target, "the password was reset by "+by);
			log_i(MODULE, "%s reset the password of %s", cs(by), cs(r.name));
			result("The password of "+r.name+" was reset");
		} else if(r.cmd == "delete"){
			if(!exists)
				return result("No account "+r.name);
			if(r.name == by)
				return result("An admin does not delete their own account");
			if(account.has("admin") && admin_count() <= 1)
				return result("The last admin is not deleted");
			if(target)
				kick(target, "the account was deleted by "+by);
			m_accounts->remove("auth/"+r.name);
			log_i(MODULE, "%s deleted the account %s", cs(by), cs(r.name));
			result("The account "+r.name+" was deleted");
		} else if(r.cmd == "add"){
			if(!valid_name(r.name))
				return result("A name is 1 to 20 letters, digits, _ or -");
			if(exists)
				return result("There is an account "+r.name+" already");
			if(r.arg.size() < MIN_PASSWORD || r.arg.size() > 100)
				return result("A password is "+itos((int)MIN_PASSWORD)+
						" to 100 characters");
			set_account(r.name, new_account(r.arg, {}));
			log_i(MODULE, "%s added the account %s", cs(by), cs(r.name));
			result("The account "+r.name+" was added");
		} else if(r.cmd == "invite"){
			Invite invite;
			invite.by = by;
			const ss_ code = random_code(10);
			m_accounts->set("invite/"+code, pack(invite));
			log_i(MODULE, "%s made an invite", cs(by));
			result("Invite code: "+code);
		} else if(r.cmd == "uninvite"){
			m_accounts->remove("invite/"+upper(r.name));
			result("The invite was deleted");
		} else if(r.cmd == "setting"){
			if(r.name != "open_registration")
				return result("No such setting");
			m_access.open_registration = r.on;
			save_access();
			log_i(MODULE, "%s set %s to %i", cs(by), cs(r.name), (int)r.on);
			for(auto &pair : m_peers)
				if(pair.second.name.empty())
					send_hello(pair.first);
			result("");
		} else {
			return;
		}
		send_users_to_admins();
	}

	// A user's own password ([FP_ACCESS] 4): the old one and the new one
	void on_passwd(const network::Packet &packet)
	{
		std::pair<ss_, ss_> pw;
		auto it = m_peers.find(packet.sender);
		if(!m_accounts || it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, pw))
			return;
		const ss_ name = it->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "fp:passwd_result", pack(text));
		};
		Account account;
		if(!get_account(name, account))
			return;
		const int64_t now = interface::os::time_us();
		if(failure_wait(m_name_failures, name, now) > 0)
			return result("Too many failed attempts; wait and try again");
		if(pbkdf2_sha256(pw.first, account.salt, PBKDF2_ITERATIONS) !=
				account.hash){
			note_failure(m_name_failures, name, now);
			log_i(MODULE, "%s: a password change with a wrong password",
					cs(name));
			return result("The old password is wrong");
		}
		if(pw.second.size() < MIN_PASSWORD || pw.second.size() > 100)
			return result("A password is "+itos((int)MIN_PASSWORD)+
					" to 100 characters");
		set_account(name, new_account(pw.second, account.privs));
		log_i(MODULE, "%s changed their password", cs(name));
		result("");
	}

	// Batches

	struct Batch
	{
		int32_t seq = 0;
		sv_<Op> ops;
		template<class Archive>
		void serialize(Archive &archive){
			archive(seq, ops);
		}
	};

	struct BatchResult
	{
		int32_t seq = 0;
		ss_ error;
		std::map<int32_t, int32_t> placeholders;
		template<class Archive>
		void serialize(Archive &archive){
			archive(seq, error, placeholders);
		}
	};

	void on_batch(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		Peer &peer = m_peers[packet.sender];
		Batch batch;
		BatchResult result;
		if(!unpack(packet.data, batch)){
			result.error = "Malformed batch";
		} else if(!can_edit(packet.sender)){
			result.error = "You cannot edit this plan";
		} else if(batch.ops.size() > MAX_OPS_PER_BATCH){
			result.error = "Too many operations in one batch";
		} else if(peer.op_budget < batch.ops.size()){
			result.error = "Too many operations; slow down";
		} else if(!(result.error = locked_by_other(*plan, batch.ops,
				packet.sender)).empty()){
		} else {
			peer.op_budget -= batch.ops.size();
			set_<int32_t> changed, deleted;
			result.error = plan->apply(batch.ops, result.placeholders, changed,
					deleted);
			if(result.error.empty())
				broadcast_changes(*plan, batch.seq, packet.sender, changed,
						deleted);
		}
		result.seq = batch.seq;
		if(!result.error.empty())
			log_i(MODULE, "Batch %i from %s refused: %s", batch.seq,
					cs(peer.name), cs(result.error));
		send(packet.sender, "fp:batch_result", pack(result));
	}

	ss_ locked_by_other(Plan &plan, const sv_<Op> &ops, network::PeerId sender)
	{
		for(const Op &op : ops){
			auto it = plan.m_locks.find(op.ent.id);
			if(it != plan.m_locks.end() && it->second != sender)
				return m_peers[it->second].name+" is moving that";
		}
		return "";
	}

	struct Changes
	{
		int32_t seq = -1;       // the sender's batch, for the sender
		int32_t sender = 0;
		sv_<Entity> ents;
		sv_<int32_t> deleted;
		template<class Archive>
		void serialize(Archive &archive){
			archive(seq, sender, ents, deleted);
		}
	};

	void broadcast_changes(Plan &plan, int32_t seq, network::PeerId sender,
			const set_<int32_t> &changed, const set_<int32_t> &deleted)
	{
		Changes c;
		c.seq = -1;
		c.sender = (int32_t)sender;
		for(int32_t id : changed)
			if(!deleted.count(id))
				c.ents.push_back(plan.m_ents[id]);
		c.deleted.assign(deleted.begin(), deleted.end());
		// The sender's copy carries its batch's number, which is how it
		// knows the changes are its own
		ss_ others = pack(c);
		c.seq = seq;
		ss_ own = pack(c);
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan.m_name)
				send(pair.first, "fp:changes", pair.first == sender ? own : others);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
