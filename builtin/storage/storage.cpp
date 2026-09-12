// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "storage/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/mutex.h"
#include "interface/os.h"
#include <sqlite3.h>
#include <sys/stat.h>
#include <cstdio>
#include <map>
#ifdef _WIN32
	#include <direct.h>
#else
	#include <unistd.h>
#endif
#define MODULE "storage"

using interface::Event;

namespace storage {

// One table, so that no module ever runs DDL and the backend stays swappable.
// The keys are strings: Luanti uses an integer primary key for map blocks
// because it has millions of 16^3 ones, and buildat's sections are 2x2x2
// chunks of 32^3, so thousands of "world/x,y,z" rows is not the same problem.
// simplified: the ceiling is an integer key over a hashed position, and the
// upgrade does not change this API.
static const char *SCHEMA =
		"CREATE TABLE IF NOT EXISTS store ("
		"store TEXT NOT NULL, key TEXT NOT NULL, value BLOB,"
		" PRIMARY KEY(store, key))";

struct CSave;

struct SqliteError: public Exception {
	SqliteError(const ss_ &what): Exception(what){}
};

static void check(sqlite3 *db, int rc, const char *what)
{
	if(rc == SQLITE_OK || rc == SQLITE_ROW || rc == SQLITE_DONE)
		return;
	ss_ msg = ss_()+what+": "+(db ? sqlite3_errmsg(db) : "no connection");
	throw SqliteError(msg);
}

// A prepared statement that finalizes itself. Prepared once per use rather
// than cached: these run once per key and sqlite's prepare is not the
// expensive part of a batch.
struct Stmt
{
	sqlite3 *db = nullptr;
	sqlite3_stmt *stmt = nullptr;

	Stmt(sqlite3 *db, const char *sql): db(db)
	{
		check(db, sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr), sql);
	}
	~Stmt()
	{
		if(stmt)
			sqlite3_finalize(stmt);
	}
	void bind(int i, const ss_ &v)
	{
		check(db, sqlite3_bind_blob(stmt, i, v.c_str(), (int)v.size(),
				SQLITE_TRANSIENT), "bind");
	}
	void bind_text(int i, const ss_ &v)
	{
		check(db, sqlite3_bind_text(stmt, i, v.c_str(), (int)v.size(),
				SQLITE_TRANSIENT), "bind");
	}
	bool step()
	{
		int rc = sqlite3_step(stmt);
		check(db, rc, "step");
		return rc == SQLITE_ROW;
	}
	ss_ column_blob(int i)
	{
		const void *p = sqlite3_column_blob(stmt, i);
		int n = sqlite3_column_bytes(stmt, i);
		if(!p || n <= 0)
			return "";
		return ss_((const char*)p, (size_t)n);
	}
	ss_ column_text(int i)
	{
		const unsigned char *p = sqlite3_column_text(stmt, i);
		int n = sqlite3_column_bytes(stmt, i);
		if(!p || n <= 0)
			return "";
		return ss_((const char*)p, (size_t)n);
	}
};

struct CStore: public Store
{
	CSave *m_save;
	ss_ m_name;

	CStore(CSave *save, const ss_ &name): m_save(save), m_name(name){}

	bool get(const ss_ &key, ss_ &value_out);
	void set(const ss_ &key, const ss_ &value);
	void remove(const ss_ &key);
	sv_<ss_> list(const ss_ &prefix);
	void batch(std::function<void()> writes);
};

struct CSave: public Save
{
	ss_ m_path;
	sqlite3 *m_db = nullptr;
	// One connection behind a recursive mutex: the server is multithreaded and
	// voxelworld has a thread of its own, and the writes are batched anyway,
	// so this is the simplest thing that is correct. Recursive because
	// batch()'s callback calls set() on the same store.
	interface::Mutex m_mutex;
	std::map<ss_, up_<CStore>> m_stores;

	// in_memory is for the self-check: everything above the sqlite calls is
	// the same, and nothing is left on anyone's disk.
	CSave(const ss_ &path, bool in_memory = false): m_path(path)
	{
		ss_ db_path = in_memory ? ":memory:" : path+"/save.sqlite";
		int rc = sqlite3_open_v2(db_path.c_str(), &m_db,
				SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nullptr);
		if(rc != SQLITE_OK){
			ss_ msg = m_db ? sqlite3_errmsg(m_db) : "out of memory";
			if(m_db)
				sqlite3_close(m_db);
			m_db = nullptr;
			throw SqliteError("Could not open "+db_path+": "+msg);
		}
		// A save that a crash interrupted is worth more than the milliseconds
		// a rollback journal would save, and WAL is what lets a reader and a
		// writer overlap at all
		exec("PRAGMA journal_mode=WAL");
		exec("PRAGMA synchronous=NORMAL");
		exec("PRAGMA foreign_keys=ON");
		exec(SCHEMA);
	}
	~CSave()
	{
		m_stores.clear();
		if(m_db){
			// Leaves one file instead of three, and is a no-op if anything
			// else still has the database open
			sqlite3_exec(m_db, "PRAGMA wal_checkpoint(TRUNCATE)",
					nullptr, nullptr, nullptr);
			sqlite3_close(m_db);
		}
	}

	void exec(const char *sql)
	{
		char *err = nullptr;
		int rc = sqlite3_exec(m_db, sql, nullptr, nullptr, &err);
		if(rc != SQLITE_OK){
			ss_ msg = err ? err : "unknown error";
			sqlite3_free(err);
			throw SqliteError(ss_()+sql+": "+msg);
		}
	}

	Store* store(const ss_ &name)
	{
		interface::MutexScope ms(m_mutex);
		auto it = m_stores.find(name);
		if(it != m_stores.end())
			return it->second.get();
		CStore *store = new CStore(this, name);
		m_stores[name] = up_<CStore>(store);
		return store;
	}

	ss_ path(){ return m_path; }
};

bool CStore::get(const ss_ &key, ss_ &value_out)
{
	interface::MutexScope ms(m_save->m_mutex);
	Stmt st(m_save->m_db,
			"SELECT value FROM store WHERE store=? AND key=?");
	st.bind_text(1, m_name);
	st.bind_text(2, key);
	if(!st.step())
		return false;
	value_out = st.column_blob(0);
	return true;
}

void CStore::set(const ss_ &key, const ss_ &value)
{
	interface::MutexScope ms(m_save->m_mutex);
	Stmt st(m_save->m_db,
			"INSERT INTO store (store, key, value) VALUES (?, ?, ?)"
			" ON CONFLICT(store, key) DO UPDATE SET value=excluded.value");
	st.bind_text(1, m_name);
	st.bind_text(2, key);
	st.bind(3, value);
	st.step();
}

void CStore::remove(const ss_ &key)
{
	interface::MutexScope ms(m_save->m_mutex);
	Stmt st(m_save->m_db, "DELETE FROM store WHERE store=? AND key=?");
	st.bind_text(1, m_name);
	st.bind_text(2, key);
	st.step();
}

sv_<ss_> CStore::list(const ss_ &prefix)
{
	interface::MutexScope ms(m_save->m_mutex);
	// >= prefix and < prefix with its last byte raised is the range a B-tree
	// can seek to, and it does not have to care what LIKE thinks % means
	sv_<ss_> result;
	if(prefix.empty()){
		Stmt st(m_save->m_db,
				"SELECT key FROM store WHERE store=? ORDER BY key");
		st.bind_text(1, m_name);
		while(st.step())
			result.push_back(st.column_text(0));
		return result;
	}
	ss_ upper = prefix;
	size_t i = upper.size();
	while(i > 0 && (unsigned char)upper[i-1] == 0xff)
		i--;
	if(i == 0){
		// Every byte is 0xff, so there is no next string; fall back to a
		// scan of the store
		Stmt st(m_save->m_db,
				"SELECT key FROM store WHERE store=? ORDER BY key");
		st.bind_text(1, m_name);
		while(st.step()){
			ss_ key = st.column_text(0);
			if(key.compare(0, prefix.size(), prefix) == 0)
				result.push_back(key);
		}
		return result;
	}
	upper.resize(i);
	upper[i-1] = (char)((unsigned char)upper[i-1] + 1);
	Stmt st(m_save->m_db,
			"SELECT key FROM store WHERE store=? AND key>=? AND key<?"
			" ORDER BY key");
	st.bind_text(1, m_name);
	st.bind_text(2, prefix);
	st.bind_text(3, upper);
	while(st.step())
		result.push_back(st.column_text(0));
	return result;
}

void CStore::batch(std::function<void()> writes)
{
	interface::MutexScope ms(m_save->m_mutex);
	// IMMEDIATE takes the write lock up front rather than half way through,
	// which is what turns a busy database into an error here instead of a
	// rollback after the work was done
	m_save->exec("BEGIN IMMEDIATE");
	try {
		writes();
	} catch(...){
		sqlite3_exec(m_save->m_db, "ROLLBACK", nullptr, nullptr, nullptr);
		throw;
	}
	m_save->exec("COMMIT");
}

// Deleting a save deletes a directory the user made. Only names valid_name()
// accepts ever get here, and only under the one saves directory, so this
// cannot be pointed at anything else by a bad name.
static bool remove_directory_tree(const ss_ &path)
{
	bool ok = true;
	for(const interface::fs::Node &n : interface::fs::list_directory(path)){
		if(n.name == "." || n.name == "..")
			continue;
		ss_ sub = path+"/"+n.name;
		if(n.is_directory){
			if(!remove_directory_tree(sub))
				ok = false;
		} else {
			if(::remove(sub.c_str()) != 0)
				ok = false;
		}
	}
#ifdef _WIN32
	if(_rmdir(path.c_str()) != 0)
		ok = false;
#else
	if(::rmdir(path.c_str()) != 0)
		ok = false;
#endif
	return ok;
}

static int64_t file_modified_us(const ss_ &path)
{
	struct stat st;
	if(stat(path.c_str(), &st) != 0)
		return 0;
	return (int64_t)st.st_mtime * 1000000;
}

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	ss_ m_saves_path;
	// Saves this server has open. The pointer a module holds stays valid
	// until it closes it.
	sv_<up_<CSave>> m_open;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		// One game per server -- it is started -m ../games/<game> and that is
		// the whole of it -- so the game is not a parameter of any call here,
		// and a game has no way to name another game's saves.
		m_saves_path = m_server->get_config().get<ss_>("user_path")+
				"/games/"+m_server->get_game_id()+"/saves";
	}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		check_round_trip();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
	}

	void on_start()
	{
	}

	// The check: a save's whole life, on a database that is never a file.
	// Everything above the sqlite calls -- the batch, the prefix range, the
	// blob round trip -- is what this is here for.
	void check_round_trip()
	{
		CSave save("", true);
		Store *s = save.store("things");
		ss_ v;
		if(s->get("a", v))
			throw Exception("storage check: a new store had a key in it");
		// A value with a zero byte in it, because these are blobs and a save
		// is full of serialized volumes
		ss_ binary("x\0y", 3);
		s->batch([&](){
			s->set("a", binary);
			s->set("b/1", "one");
			s->set("b/2", "two");
			s->set("c", "three");
		});
		if(!s->get("a", v) || v != binary)
			throw Exception("storage check: value did not survive");
		if(v.size() != 3)
			throw Exception("storage check: value was cut at a zero byte");
		sv_<ss_> keys = s->list("b/");
		if(keys.size() != 2 || keys[0] != "b/1" || keys[1] != "b/2")
			throw Exception("storage check: prefix list");
		if(s->list("").size() != 4)
			throw Exception("storage check: full list");
		s->set("a", "again");
		if(!s->get("a", v) || v != "again")
			throw Exception("storage check: overwrite");
		s->remove("a");
		if(s->get("a", v))
			throw Exception("storage check: remove");
		// Stores are namespaces: the same key in another one is another value
		Store *other = save.store("others");
		if(other->get("c", v))
			throw Exception("storage check: stores are not separate");
		// A failed batch leaves nothing behind
		try {
			s->batch([&](){
				s->set("d", "four");
				throw Exception("deliberate");
			});
			throw Exception("storage check: batch swallowed an exception");
		} catch(Exception &e){
		}
		if(s->get("d", v))
			throw Exception("storage check: a failed batch was not rolled back");

		if(valid_name("..") || valid_name("a/b") || valid_name("") ||
				valid_name(".hidden") || valid_name("a\\b"))
			throw Exception("storage check: valid_name accepted a bad name");
		if(!valid_name("my save") || !valid_name("world_1"))
			throw Exception("storage check: valid_name refused a good name");
	}

	// Interface

	// A save name becomes a directory name, so this is where it stops being
	// whatever a game felt like passing.
	bool valid_name(const ss_ &name)
	{
		if(name.empty() || name.size() > 200)
			return false;
		if(name[0] == '.')
			return false;
		if(name[name.size()-1] == '.' || name[name.size()-1] == ' ')
			return false; // Windows quietly strips these
		for(char c : name){
			unsigned char u = (unsigned char)c;
			if(u < 0x20 || c == '/' || c == '\\' || c == ':' || c == '*' ||
					c == '?' || c == '"' || c == '<' || c == '>' || c == '|')
				return false;
		}
		return true;
	}

	Save* open(const ss_ &name)
	{
		if(!valid_name(name)){
			log_w(MODULE, "open(): invalid save name \"%s\"", cs(name));
			return nullptr;
		}
		ss_ path = m_saves_path+"/"+name;
		if(!interface::fs::path_exists(path+"/save.sqlite")){
			log_v(MODULE, "open(): no save at [%s]", cs(path));
			return nullptr;
		}
		return open_at(path);
	}

	Save* create(const ss_ &name)
	{
		if(!valid_name(name)){
			log_w(MODULE, "create(): invalid save name \"%s\"", cs(name));
			return nullptr;
		}
		ss_ path = m_saves_path+"/"+name;
		if(interface::fs::path_exists(path+"/save.sqlite")){
			log_w(MODULE, "create(): a save already exists at [%s]", cs(path));
			return nullptr;
		}
		interface::fs::create_directories(path);
		return open_at(path);
	}

	Save* open_at(const ss_ &path)
	{
		CSave *save = new CSave(path);
		m_open.push_back(up_<CSave>(save));
		log_v(MODULE, "Opened save [%s]", cs(path));
		return save;
	}

	void close(Save *save)
	{
		for(auto it = m_open.begin(); it != m_open.end(); it++){
			if(it->get() == save){
				m_open.erase(it);
				return;
			}
		}
		log_w(MODULE, "close(): this save is not open");
	}

	sv_<SaveInfo> list()
	{
		sv_<SaveInfo> result;
		for(const interface::fs::Node &n :
				interface::fs::list_directory(m_saves_path)){
			if(!n.is_directory || n.name == "." || n.name == "..")
				continue;
			ss_ db = m_saves_path+"/"+n.name+"/save.sqlite";
			if(!interface::fs::path_exists(db))
				continue;
			SaveInfo info;
			info.name = n.name;
			info.modified_us = file_modified_us(db);
			result.push_back(info);
		}
		return result;
	}

	void remove(const ss_ &name)
	{
		if(!valid_name(name)){
			log_w(MODULE, "remove(): invalid save name \"%s\"", cs(name));
			return;
		}
		ss_ path = m_saves_path+"/"+name;
		if(!interface::fs::path_exists(path+"/save.sqlite")){
			log_w(MODULE, "remove(): no save at [%s]", cs(path));
			return;
		}
		for(const up_<CSave> &save : m_open){
			if(save->m_path == path){
				log_w(MODULE, "remove(): [%s] is open", cs(path));
				return;
			}
		}
		if(!remove_directory_tree(path))
			log_w(MODULE, "remove(): [%s] was not fully removed", cs(path));
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_storage(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
