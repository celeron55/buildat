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

static const sv_<ss_> KNOWN_PRIVS = {"edit", "admin"};

// Who may make an account, the auth store's and not the document's
// ([FP_ACCESS] 3): the plan's settings entity is changed by any editor's
// ordinary edits, and its old default_edit is only read once, to carry it
// over
struct AccessSettings
{
	uint8_t open_registration = 0;
	uint8_t default_edit = 1;

	template<class Archive>
	void serialize(Archive &archive){
		archive(open_registration, default_edit);
	}
};

// A one-time invite ([FP_ACCESS] 2): the privileges the account it makes
// gets, and the admin who made it
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
	ss_ m_save_name; // the open plan's
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
	// [FP_ACCESS]: the plan's access settings, the code that claims it while
	// it has no admin (empty when it has one), and the failed logins by name
	// and by address
	AccessSettings m_access;
	ss_ m_setup_code;
	std::map<ss_, Failures> m_name_failures;
	std::map<ss_, Failures> m_address_failures;
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
		m_server->sub_event(this,
				Event::t("network:packet_received/fp:copy_plan"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:batch"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:chat"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:admin"));
		m_server->sub_event(this, Event::t("network:packet_received/fp:passwd"));
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
		EVENT_TYPEN("network:packet_received/fp:copy_plan", on_copy_plan,
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
		m_save_name = name;
		load();
		load_access();
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
		sv_<ss_> saves;         // for the local user
		ss_ plan;               // the one open, or ""
		// [FP_ACCESS]: the join asks for the setup code (the plan has no
		// admin), or says a new name needs an invite (registration is not
		// open)
		uint8_t setup = 0;
		uint8_t open_registration = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(local, pick, saves, plan, setup, open_registration);
		}
	};

	// What the client shows first: the plans to pick from, for the local
	// user when none is open; else the join, with a password or without
	void send_hello(network::PeerId peer)
	{
		Hello h;
		h.local = is_local(peer);
		h.pick = !m_store;
		h.plan = m_store ? m_save_name : "";
		h.setup = !h.local && !m_setup_code.empty();
		h.open_registration = m_access.open_registration;
		// Always, to the local user: the plan picker lists them, and a copy
		// is named past them ([FP_COPY])
		if(h.local){
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
		close_plan();
	}

	void close_plan()
	{
		flush();
		storage::access(m_server, [&](storage::Interface *istorage){
			istorage->close(m_save);
		});
		m_save = nullptr;
		m_store = nullptr;
		m_save_name.clear();
		m_ents.clear();
		m_voxels.clear();
		m_dirty.clear();
		m_voxels_dirty.clear();
		m_locks.clear();
		m_images.clear();
		m_setup_code.clear();
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

	// **A copy of the open plan under a new name, which is then the one
	// open** ([FP_COPY]; the local user's, as picking a plan is). Never
	// over a save that exists. The plan is closed first, so its database
	// and write-ahead log are copied whole; its images go with it, its
	// backups do not.
	void on_copy_plan(const network::Packet &packet)
	{
		ss_ name;
		if(!m_store || !is_local(packet.sender) || !unpack(packet.data, name))
			return;
		ss_ why;
		storage::access(m_server, [&](storage::Interface *istorage){
			if(!istorage->valid_name(name)){
				why = "\""+name+"\" is not a name a plan can have";
				return;
			}
			for(const storage::SaveInfo &i : istorage->list())
				if(i.name == name)
					why = "There is a plan called \""+name+"\" already";
		});
		if(!why.empty()){
			send(packet.sender, "fp:login_result", pack(why));
			return;
		}
		namespace fs = interface::fs;
		const ss_ from = m_save->path();
		const size_t slash = from.find_last_of("/\\");
		const ss_ to = (slash == ss_::npos ? ss_(".") : from.substr(0, slash))+
				"/"+name;
		const ss_ old_name = m_save_name;
		close_plan();
		fs::create_directories(to+"/images");
		bool ok = fs::copy_file(from+"/save.sqlite", to+"/save.sqlite");
		if(fs::path_exists(from+"/save.sqlite-wal"))
			ok = fs::copy_file(from+"/save.sqlite-wal", to+"/save.sqlite-wal") &&
					ok;
		for(const fs::Node &n : fs::list_directory(from+"/images"))
			if(!n.is_directory)
				ok = fs::copy_file(from+"/images/"+n.name, to+"/images/"+n.name) &&
						ok;
		// A copy that did not make it is not left as a plan to pick
		if(!ok){
			log_e(MODULE, "Could not copy the plan %s into %s", cs(old_name),
					cs(to));
			fs::remove_all(to);
			open_save(old_name, false);
		} else {
			log_i(MODULE, "Copied the plan %s as %s", cs(old_name), cs(name));
			open_save(name, false);
		}
		for(auto &pair : m_peers)
			send_hello(pair.first);
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
		if(!name.empty() && m_store)
			send_users_to_admins();
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

	// Access ([FP_ACCESS])

	void save_access()
	{
		m_store->set("access/settings", pack(m_access));
	}

	void load_access()
	{
		ss_ data;
		if(!(m_store->get("access/settings", data) && unpack(data, m_access))){
			// A plan from before: registration open where the launcher
			// started the server, and default_edit carried over from the
			// settings entity, where any editor could change it
			m_access = AccessSettings();
			m_access.open_registration = m_launched;
			Entity *s = find_singleton("settings");
			m_access.default_edit = !s || s->ints["default_edit"] != 0;
			save_access();
		}
		update_setup_code();
	}

	int admin_count()
	{
		int n = 0;
		for(const ss_ &key : m_store->list("auth/")){
			Account account;
			if(get_account(key.substr(5), account) && account.has("admin"))
				n++;
		}
		return n;
	}

	// A plan with no admin is claimed with a code from the server's log
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
		log_w(MODULE, "The plan %s has no admin. The first to join with the "
				"setup code %s becomes it.", cs(m_save_name), cs(m_setup_code));
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

	sv_<ss_> default_privs()
	{
		return m_access.default_edit ? sv_<ss_>{"edit"} : sv_<ss_>{};
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

	// simplified: the password arrives in the clear on a native client's
	// connection, because the transport is not encrypted yet ([TRANSPORT]);
	// the join dialog says so. The web client behind an https proxy has TLS.
	void on_login(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end())
			return;
		Peer &peer = pit->second;
		LoginRequest cred;
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
			// An account of a plan that has no admin can claim it too
			if(!local && !m_setup_code.empty() && !code.empty()){
				if(code != m_setup_code)
					return fail("Wrong setup code");
				account.privs = {"edit", "admin"};
				set_account(name, account);
				log_i(MODULE, "%s claimed the plan with the setup code",
						cs(name));
			}
		} else {
			sv_<ss_> privs;
			if(local){
				// The first admin of the launcher's plan is its own user
				privs = admin_count() == 0 ? sv_<ss_>{"edit", "admin"} :
						default_privs();
			} else {
				if(password.size() < MIN_PASSWORD)
					return reply("A new account's password is at least "+
							itos((int)MIN_PASSWORD)+" characters");
				Invite invite;
				ss_ data;
				if(!m_setup_code.empty()){
					if(code != m_setup_code)
						return fail(code.empty() ?
								"This plan has no admin yet: the first account "
								"needs the setup code from the server's log" :
								"Wrong setup code");
					privs = {"edit", "admin"};
					log_i(MODULE, "%s claimed the plan with the setup code",
							cs(name));
				} else if(!code.empty()){
					if(!(m_store->get("invite/"+code, data) &&
							unpack(data, invite)))
						return fail("No such invite code");
					privs = invite.privs;
					m_store->remove("invite/"+code);
					log_i(MODULE, "%s used an invite of %s", cs(name),
							cs(invite.by));
				} else if(m_access.open_registration){
					privs = default_privs();
				} else {
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
		// The admins' lists: who is here, a new account, an invite used
		send_users_to_admins();
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
		// The chat commands are the pause menu's now ([FP_ACCESS] 4)
		if(text[0] == '/'){
			send_chat(packet.sender, "The commands are in the pause menu "
					"(Esc): Users..., Change password...");
			return;
		}
		broadcast_chat("<"+it->second.name+"> "+text);
	}

	// The admin's menus ([FP_ACCESS] 4), which replace the chat commands

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
		for(const ss_ &key : m_store->list("auth/")){
			UserRow row;
			row.name = key.substr(5);
			Account account;
			if(get_account(row.name, account))
				row.privs = account.privs;
			row.here = find_peer(row.name) != 0;
			info.users.push_back(row);
		}
		for(const ss_ &key : m_store->list("invite/")){
			Invite invite;
			ss_ data;
			if(m_store->get(key, data) && unpack(data, invite))
				info.invites.push_back(std::make_pair(key.substr(7), invite));
		}
		info.access = m_access;
		send(peer, "fp:users", pack(info));
	}

	void send_users_to_admins()
	{
		for(auto &pair : m_peers)
			if(peer_has(pair.first, "admin"))
				send_users(pair.first);
	}

	// Out of the plan: the client is told to leave, and is logged out here
	// meanwhile.
	// simplified: the network module has no way to drop a peer
	void kick(network::PeerId target, const ss_ &why)
	{
		send(target, "fp:kicked", pack(why));
		const ss_ name = m_peers[target].name;
		m_peers[target].name.clear();
		leave(target, "");
		send_to_joined("fp:gone", pack((int32_t)target));
		broadcast_chat("*** "+name+" left: "+why);
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
		if(!m_store || !peer_has(packet.sender, "admin") ||
				!unpack(packet.data, r))
			return;
		const ss_ by = m_peers[packet.sender].name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "fp:admin_result", pack(text));
		};
		Account account;
		const bool exists = !r.name.empty() && get_account(r.name, account);
		const network::PeerId target = exists ? find_peer(r.name) : 0;
		if(r.cmd == "list"){
			return send_users(packet.sender);
		} else if(r.cmd == "priv"){
			bool known = false;
			for(const ss_ &p : KNOWN_PRIVS)
				known |= p == r.arg;
			if(!exists || !known)
				return result("No such account or privilege");
			if(r.arg == "admin" && !r.on && account.has("admin") &&
					admin_count() <= 1)
				return result("The last admin keeps admin");
			sv_<ss_> privs;
			for(const ss_ &p : account.privs)
				if(p != r.arg)
					privs.push_back(p);
			if(r.on)
				privs.push_back(r.arg);
			account.privs = privs;
			set_account(r.name, account);
			if(target)
				send_privs(target, account);
			log_i(MODULE, "%s %s %s %s", cs(by), r.on ? "granted" : "revoked",
					cs(r.arg), cs(r.name));
			result(r.name+(r.on ? " can " : " can no longer ")+
					(r.arg == "edit" ? "edit" : "administer"));
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
			Account fresh = new_account(r.arg, account.privs);
			set_account(r.name, fresh);
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
			m_store->remove("auth/"+r.name);
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
			set_account(r.name, new_account(r.arg,
					r.on ? sv_<ss_>{"edit"} : sv_<ss_>{}));
			log_i(MODULE, "%s added the account %s", cs(by), cs(r.name));
			result("The account "+r.name+" was added");
		} else if(r.cmd == "invite"){
			Invite invite;
			invite.by = by;
			if(r.on)
				invite.privs = {"edit"};
			const ss_ code = random_code(10);
			m_store->set("invite/"+code, pack(invite));
			log_i(MODULE, "%s made an invite", cs(by));
			result("Invite code: "+code);
		} else if(r.cmd == "uninvite"){
			m_store->remove("invite/"+upper(r.name));
			result("The invite was deleted");
		} else if(r.cmd == "setting"){
			if(r.name == "open_registration")
				m_access.open_registration = r.on;
			else if(r.name == "default_edit")
				m_access.default_edit = r.on;
			else
				return result("No such setting");
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
		if(!m_store || it == m_peers.end() || it->second.name.empty() ||
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
