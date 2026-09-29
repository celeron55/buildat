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
static const int32_t SCHEMA_VERSION = 2;
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
	MK_GLASS, MK_METAL, MK_TILE, MK_FABRIC, MK_PLASTER, MK_COUNT };

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
	}, {}, {}, true},
	{"node", {
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

static const sv_<ss_> KNOWN_PRIVS = {"edit", "admin"};

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

struct Module: public interface::Module
{
	interface::Server *m_server;
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
	float m_flush_timer = 0;

	std::map<network::PeerId, Peer> m_peers;
	// What is being dragged, and by whom: nobody else's batch may touch it
	std::map<int32_t, network::PeerId> m_locks;

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
		m_server->sub_event(this, Event::t("network:packet_received/fp:login"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:open"));
		m_server->sub_event(this,
				Event::t("network:packet_received/fp:close_plan"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:batch"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:chat"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:voxels"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:lock"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:unlock"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:preview"));
		m_server->sub_event(this,
				Event::t("network:packet_received/fp:presence"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_start)
		EVENT_VOIDN("core:unload", flush)
		EVENT_VOIDN("core:shutdown", flush)
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
		EVENT_TYPEN("network:packet_received/fp:close_plan", on_close_plan,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:batch", on_batch,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:chat", on_chat,
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

	// The save

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

	// Started from the launch grid ([FP_LAUNCH]): which plan is the local
	// user's to pick, and the local user joins without a password. Run by
	// hand, the server opens "plan", or the save=<name> it is given.
	bool m_launched = false;

	void on_start()
	{
		m_launched = launch_param("pick") == "1";
		ss_ name = launch_param("save");
		if(name.empty() && m_launched){
			log_i(MODULE, "Waiting for the local user to pick a plan");
			return;
		}
		open_save(name.empty() ? "plan" : name, true);
	}

	// Opens the save, or with create makes it when it is not there; a
	// copy goes into its backups first
	bool open_save(const ss_ &name, bool create)
	{
		bool valid = false;
		storage::access(m_server, [&](storage::Interface *istorage){
			valid = istorage->valid_name(name);
			if(!valid)
				return;
			m_save = istorage->open(name);
			if(m_save){
				// A copy of the plan as it was, before anything touches it:
				// what an undo that lives only for a session cannot give
				// back
				ss_ path = m_save->path();
				istorage->close(m_save);
				backup(path);
				m_save = istorage->open(name);
			} else if(create){
				m_save = istorage->create(name);
			}
		});
		if(!m_save){
			log_e(MODULE, "Could not open or create the save %s", cs(name));
			if(!m_launched)
				m_server->shutdown(1, "floorplanner: no save");
			return false;
		}
		m_store = m_save->store("main");
		load();
		find_images();
		log_i(MODULE, "Opened the plan %s", cs(name));
		return true;
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
		uint8_t pick = 0;       // no plan open: pick one of saves
		sv_<ss_> saves;
		template<class Archive>
		void serialize(Archive &archive){
			archive(local, pick, saves);
		}
	};

	// What the client shows first: the plans to pick from, for the local
	// user when none is open; else the join, with a password or without
	void send_hello(network::PeerId peer)
	{
		Hello h;
		h.local = is_local(peer);
		h.pick = !m_store;
		if(h.pick && h.local){
			storage::access(m_server, [&](storage::Interface *istorage){
				sv_<storage::SaveInfo> infos = istorage->list();
				// The one opened last first
				std::sort(infos.begin(), infos.end(),
						[](const storage::SaveInfo &a, const storage::SaveInfo &b){
					return a.modified_us > b.modified_us;
				});
				for(const storage::SaveInfo &i : infos)
					h.saves.push_back(i.name);
			});
		}
		send(peer, "fp:hello", pack(h));
	}

	void on_open(const network::Packet &packet)
	{
		std::pair<ss_, uint8_t> req;
		if(m_store || !is_local(packet.sender) || !unpack(packet.data, req))
			return;
		if(!open_save(req.first, req.second != 0)){
			send(packet.sender, "fp:login_result", pack(ss_("Could not open "
					"the plan \"")+req.first+"\""));
			send_hello(packet.sender);
			return;
		}
		for(auto &pair : m_peers)
			send_hello(pair.first);
	}

	// Back to the plan picker ([FP_OTHER_PLAN]): the plan saved and closed,
	// everybody logged out of it, the local user offered the plans again
	void on_close_plan(const network::Packet &packet)
	{
		if(!m_store || !is_local(packet.sender))
			return;
		flush();
		storage::access(m_server, [&](storage::Interface *istorage){
			istorage->close(m_save);
		});
		m_save = nullptr;
		m_store = nullptr;
		m_ents.clear();
		m_voxels.clear();
		m_dirty.clear();
		m_voxels_dirty.clear();
		m_locks.clear();
		m_images.clear();
		for(auto &pair : m_peers){
			pair.second.name.clear();
			pair.second.has_presence = false;
		}
		log_i(MODULE, "The plan is closed; the local user picks another");
		for(auto &pair : m_peers){
			send(pair.first, "fp:closed", "");
			send_hello(pair.first);
		}
	}

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

	// The save's images/ as files for the clients: the pictures a plan can
	// be traced over. Put there by hand; a name is one file name.
	sv_<ss_> m_images;
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
				i->add_file_path("main/images/"+n.name, dir+"/"+n.name);
			});
		}
		log_i(MODULE, "%zu images to trace over", m_images.size());
	}

	void load()
	{
		m_ents.clear();
		ss_ version;
		if(m_store->get("schema_version", version) &&
				std::stoi(version) > SCHEMA_VERSION){
			// A newer build's plan: refuse rather than drop what it has
			m_server->shutdown(1, "floorplanner: the plan is from a newer "
					"version (schema "+version+")");
			return;
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
		if(m_ents.size() == count_type("settings")){
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
		log_i(MODULE, "Loaded %zu entities and %zu voxel volumes",
				m_ents.size(), m_voxels.size());
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

	void on_tick(const interface::TickEvent &event)
	{
		m_flush_timer += event.dtime;
		if(m_flush_timer >= 1.0f){
			m_flush_timer = 0;
			flush();
		}
		for(auto &pair : m_peers){
			pair.second.op_budget = std::min(OPS_BURST,
					pair.second.op_budget + OPS_PER_SECOND * event.dtime);
		}
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
		ss_ name = it->second.name;
		m_peers.erase(it);
		leave(client.info.id, name);
	}

	// A user gone, by leaving or by a kick: their locks go, and the others
	// stop showing them
	void leave(network::PeerId peer, const ss_ &name)
	{
		unlock_all(peer);
		if(name.empty())
			return;
		send_to_joined("fp:gone", pack((int32_t)peer));
		broadcast_chat("*** "+name+" left");
	}

	void unlock_all(network::PeerId peer)
	{
		for(auto it = m_locks.begin(); it != m_locks.end();){
			if(it->second == peer)
				it = m_locks.erase(it);
			else
				++it;
		}
	}

	// Voxels

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

	static bool valid_voxel_key(int32_t key)
	{
		// Three bytes, each a cell coordinate + VOXEL_RANGE
		return key >= 0 && key < (1 << 24);
	}

	void on_voxels(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end() || pit->second.name.empty())
			return;
		VoxelEdit edit;
		std::pair<int32_t, ss_> result;
		if(!unpack(packet.data, edit)){
			result.second = "Malformed voxels";
		} else {
			result.first = edit.seq;
			result.second = check_voxels(packet.sender, edit);
		}
		if(result.second.empty()){
			pit->second.op_budget -= edit.sets.size() / 10.0;
			std::map<int32_t, int32_t> &voxels = m_voxels[edit.def];
			for(auto &pair : edit.sets){
				if(pair.second == 0)
					voxels.erase(pair.first);
				else
					voxels[pair.first] = pair.second;
			}
			m_voxels_dirty.insert(edit.def);
			// The sender's copy carries its number, as with fp:changes
			for(auto &pair : m_peers){
				if(pair.second.name.empty())
					continue;
				edit.seq = pair.first == packet.sender ? result.first : -1;
				send(pair.first, "fp:voxels", pack(edit));
			}
		} else {
			log_i(MODULE, "Voxels from %s refused: %s", cs(pit->second.name),
					cs(result.second));
		}
		send(packet.sender, "fp:voxels_result", pack(result));
	}

	ss_ check_voxels(network::PeerId sender, const VoxelEdit &edit)
	{
		if(!peer_has(sender, "edit"))
			return "You have no edit privilege";
		auto it = m_ents.find(edit.def);
		if(it == m_ents.end() || it->second.type != "definition" ||
				it->second.ints.at("kind") != DK_VOXEL)
			return "Not a voxel volume";
		auto lock = m_locks.find(edit.def);
		if(lock != m_locks.end() && lock->second != sender)
			return m_peers[lock->second].name+" is moving that";
		if(m_peers[sender].op_budget < edit.sets.size() / 10.0)
			return "Too many voxels at once; slow down";
		const std::map<int32_t, int32_t> &voxels = m_voxels[edit.def];
		size_t added = 0;
		for(auto &pair : edit.sets){
			if(!valid_voxel_key(pair.first))
				return "A voxel outside the volume";
			if(pair.second != 0){
				auto p = m_ents.find(pair.second);
				if(p == m_ents.end() || p->second.type != "palette")
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

	struct LockRequest
	{
		int32_t seq = 0;
		sv_<int32_t> ids;
		template<class Archive>
		void serialize(Archive &archive){
			archive(seq, ids);
		}
	};

	void on_lock(const network::Packet &packet)
	{
		LockRequest req;
		std::pair<int32_t, ss_> result;
		if(!unpack(packet.data, req) || req.ids.size() > MAX_OPS_PER_BATCH)
			return;
		result.first = req.seq;
		if(!peer_has(packet.sender, "edit")){
			result.second = "You have no edit privilege";
		} else {
			for(int32_t id : req.ids){
				auto it = m_locks.find(id);
				if(it != m_locks.end() && it->second != packet.sender){
					result.second = m_peers[it->second].name+
							" is moving that";
					break;
				}
			}
		}
		if(result.second.empty()){
			// One drag at a time: what this user held before is let go
			unlock_all(packet.sender);
			for(int32_t id : req.ids)
				m_locks[id] = packet.sender;
		}
		send(packet.sender, "fp:lock_result", pack(result));
	}

	void on_unlock(const network::Packet &packet)
	{
		unlock_all(packet.sender);
		// And what it was showing the others goes
		relay_preview(packet.sender, {});
	}

	struct Preview
	{
		int32_t peer = 0;
		sv_<Entity> ents;
		template<class Archive>
		void serialize(Archive &archive){
			archive(peer, ents);
		}
	};

	void relay_preview(network::PeerId sender, const sv_<Entity> &ents)
	{
		Preview p;
		p.peer = (int32_t)sender;
		p.ents = ents;
		ss_ data = pack(p);
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.first != sender)
				send(pair.first, "fp:preview", data);
	}

	// A drag as it goes: where the dragged things would be, for the others
	// to draw. Nothing in the document changes until the drag's batch.
	void on_preview(const network::Packet &packet)
	{
		sv_<Entity> ents;
		if(!peer_has(packet.sender, "edit") || !unpack(packet.data, ents) ||
				ents.size() > MAX_OPS_PER_BATCH)
			return;
		relay_preview(packet.sender, ents);
	}

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

	void on_presence(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(it == m_peers.end() || it->second.name.empty())
			return;
		Presence p;
		if(!unpack(packet.data, p) || p.sel.size() > 1000)
			return;
		it->second.presence = p;
		it->second.has_presence = true;
		PresenceOut out;
		out.peer = (int32_t)packet.sender;
		out.name = it->second.name;
		out.p = p;
		ss_ data = pack(out);
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.first != packet.sender)
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

	void send_to_joined(const ss_ &name, const ss_ &data)
	{
		for(auto &pair : m_peers)
			if(!pair.second.name.empty())
				send(pair.first, name, data);
	}

	void send_chat(network::PeerId peer, const ss_ &text)
	{
		send(peer, "fp:chat", pack(text));
	}

	void broadcast_chat(const ss_ &text)
	{
		send_to_joined("fp:chat", pack(text));
	}

	// Accounts

	bool get_account(const ss_ &name, Account &account)
	{
		ss_ data;
		return m_store->get("auth/"+name, data) && unpack(data, account);
	}

	void set_account(const ss_ &name, const Account &account)
	{
		m_store->set("auth/"+name, pack(account));
	}

	void send_privs(network::PeerId peer, const Account &account)
	{
		send(peer, "fp:privs", pack(account.privs));
	}

	network::PeerId find_peer(const ss_ &name)
	{
		for(auto &pair : m_peers)
			if(pair.second.name == name)
				return pair.first;
		return 0;
	}

	// simplified: the password arrives in the clear, because the transport
	// is not encrypted yet ([TRANSPORT]). The client's dialog says so.
	void on_login(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end())
			return;
		Peer &peer = pit->second;
		std::pair<ss_, ss_> cred;
		auto reply = [&](const ss_ &error){
			send(packet.sender, "fp:login_result", pack(error));
		};
		if(!m_store)
			return reply("No plan is open yet");
		// The local user is on the machine the plan is on: a password
		// would keep out nobody the files themselves do not let in
		bool local = is_local(packet.sender);
		if(!peer.name.empty())
			return reply("Already joined");
		if(peer.failures >= MAX_LOGIN_FAILURES)
			return reply("Too many failed attempts; reconnect");
		if(!unpack(packet.data, cred))
			return reply("Malformed login");
		const ss_ &name = cred.first;
		const ss_ &password = cred.second;
		if(!valid_name(name))
			return reply("A name is 1 to 20 letters, digits, _ or -");
		if(password.size() > 100)
			return reply("The password is too long");
		if(find_peer(name))
			return reply(name+" is already here");

		Account account;
		if(get_account(name, account)){
			if(!local && pbkdf2_sha256(password, account.salt,
					PBKDF2_ITERATIONS) != account.hash){
				peer.failures++;
				log_i(MODULE, "Wrong password for %s", cs(name));
				return reply("Wrong password");
			}
		} else {
			std::random_device rd;
			account.salt.resize(16);
			for(char &c : account.salt)
				c = (char)(rd() & 0xff);
			// A local account gets a password nobody knows, so its name
			// cannot be taken over from elsewhere with an empty one
			ss_ pw = password;
			if(local){
				pw.resize(32);
				for(char &c : pw)
					c = (char)(rd() & 0xff);
			}
			account.hash = pbkdf2_sha256(pw, account.salt, PBKDF2_ITERATIONS);
			// The first account of a plan is its admin: whoever made it
			if(m_store->list("auth/").empty())
				account.privs = {"edit", "admin"};
			else if(find_singleton("settings")->ints["default_edit"])
				account.privs = {"edit"};
			set_account(name, account);
			log_i(MODULE, "New account %s", cs(name));
		}
		peer.name = name;
		reply("");
		send_privs(packet.sender, account);
		sv_<Entity> all;
		for(auto &pair : m_ents)
			all.push_back(pair.second);
		send(packet.sender, "fp:snapshot", pack(all));
		send(packet.sender, "fp:images", pack(m_images));
		for(auto &pair : m_voxels){
			if(!m_ents.count(pair.first))
				continue;
			VoxelEdit v;
			v.seq = -1;
			v.def = pair.first;
			v.sets = pair.second;
			send(packet.sender, "fp:voxels", pack(v));
		}
		// Where the others are
		for(auto &pair : m_peers){
			if(pair.first == packet.sender || pair.second.name.empty() ||
					!pair.second.has_presence)
				continue;
			PresenceOut out;
			out.peer = (int32_t)pair.first;
			out.name = pair.second.name;
			out.p = pair.second.presence;
			send(packet.sender, "fp:presence", pack(out));
		}
		broadcast_chat("*** "+name+" joined");
	}

	bool peer_has(network::PeerId peer_id, const ss_ &priv)
	{
		auto it = m_peers.find(peer_id);
		if(it == m_peers.end() || it->second.name.empty())
			return false;
		Account account;
		return get_account(it->second.name, account) && account.has(priv);
	}

	// Chat and its commands

	void on_chat(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(it == m_peers.end() || it->second.name.empty())
			return;
		ss_ text;
		if(!unpack(packet.data, text) || text.empty() || text.size() > 500 ||
				!valid_text(text))
			return;
		if(text[0] == '/'){
			command(packet.sender, text.substr(1));
			return;
		}
		broadcast_chat("<"+it->second.name+"> "+text);
	}

	void command(network::PeerId sender, const ss_ &line)
	{
		std::istringstream is(line);
		ss_ cmd, name, priv;
		is >> cmd >> name >> priv;
		bool admin = peer_has(sender, "admin");
		if(cmd == "privs"){
			if(name.empty())
				name = m_peers[sender].name;
			Account account;
			if(!get_account(name, account))
				return send_chat(sender, "No account "+name);
			ss_ s;
			for(const ss_ &p : account.privs)
				s += (s.empty() ? "" : ", ")+p;
			return send_chat(sender, name+": "+(s.empty() ? "(none)" : s));
		}
		if(cmd == "grant" || cmd == "revoke"){
			if(!admin)
				return send_chat(sender, "That needs admin");
			bool known = false;
			for(const ss_ &p : KNOWN_PRIVS)
				known |= p == priv;
			if(!known)
				return send_chat(sender, "Usage: /"+cmd+" <name> <edit|admin>");
			Account account;
			if(!get_account(name, account))
				return send_chat(sender, "No account "+name);
			sv_<ss_> privs;
			for(const ss_ &p : account.privs)
				if(p != priv)
					privs.push_back(p);
			if(cmd == "grant")
				privs.push_back(priv);
			account.privs = privs;
			set_account(name, account);
			if(network::PeerId target = find_peer(name))
				send_privs(target, account);
			return broadcast_chat("*** "+name+(cmd == "grant" ? " was granted "
					: " lost ")+priv);
		}
		if(cmd == "kick"){
			if(!admin)
				return send_chat(sender, "That needs admin");
			network::PeerId target = find_peer(name);
			if(!target)
				return send_chat(sender, name+" is not here");
			// simplified: the network module has no way to drop a peer, so
			// the client is told to leave and is logged out here meanwhile
			send(target, "fp:kicked", pack(ss_("Kicked by ")+
					m_peers[sender].name));
			m_peers[target].name.clear();
			leave(target, "");
			send_to_joined("fp:gone", pack((int32_t)target));
			return broadcast_chat("*** "+name+" was kicked");
		}
		if(cmd == "default_edit"){
			if(!admin)
				return send_chat(sender, "That needs admin");
			if(name != "0" && name != "1")
				return send_chat(sender, "Usage: /default_edit <0|1>");
			Entity *s = find_singleton("settings");
			s->ints["default_edit"] = name == "1";
			m_dirty.insert(s->id);
			broadcast_changes(-1, 0, {s->id}, {});
			return send_chat(sender, "New accounts can "+
					ss_(name == "1" ? "" : "not ")+"edit");
		}
		send_chat(sender, "Commands: /privs [name], /grant <name> <priv>, "
				"/revoke <name> <priv>, /kick <name>, /default_edit <0|1>");
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
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end() || pit->second.name.empty())
			return;
		Batch batch;
		BatchResult result;
		if(!unpack(packet.data, batch)){
			result.error = "Malformed batch";
		} else if(!peer_has(packet.sender, "edit")){
			result.error = "You have no edit privilege";
		} else if(batch.ops.size() > MAX_OPS_PER_BATCH){
			result.error = "Too many operations in one batch";
		} else if(pit->second.op_budget < batch.ops.size()){
			result.error = "Too many operations; slow down";
		} else if(!(result.error = locked_by_other(batch.ops,
				packet.sender)).empty()){
		} else {
			pit->second.op_budget -= batch.ops.size();
			set_<int32_t> changed, deleted;
			result.error = apply(batch.ops, result.placeholders, changed,
					deleted);
			if(result.error.empty())
				broadcast_changes(batch.seq, packet.sender, changed, deleted);
		}
		result.seq = batch.seq;
		if(!result.error.empty())
			log_i(MODULE, "Batch %i from %s refused: %s", batch.seq,
					cs(pit->second.name), cs(result.error));
		send(packet.sender, "fp:batch_result", pack(result));
	}

	ss_ locked_by_other(const sv_<Op> &ops, network::PeerId sender)
	{
		for(const Op &op : ops){
			auto it = m_locks.find(op.ent.id);
			if(it != m_locks.end() && it->second != sender)
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

	void broadcast_changes(int32_t seq, network::PeerId sender,
			const set_<int32_t> &changed, const set_<int32_t> &deleted)
	{
		Changes c;
		c.seq = -1;
		c.sender = (int32_t)sender;
		for(int32_t id : changed)
			if(!deleted.count(id))
				c.ents.push_back(m_ents[id]);
		c.deleted.assign(deleted.begin(), deleted.end());
		// The sender's copy carries its batch's number, which is how it
		// knows the changes are its own
		ss_ others = pack(c);
		c.seq = seq;
		ss_ own = pack(c);
		for(auto &pair : m_peers)
			if(!pair.second.name.empty())
				send(pair.first, "fp:changes", pair.first == sender ? own : others);
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

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
