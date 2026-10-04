// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// **Hearth** ([HEARTH_MVP], doc/plan/forum_plan.md): a forum, as an app.
// Topics, threads under them and messages in those, each at a permanent
// address; an edit keeps what it replaced.
//
// Two faces. **To read**: plain HTML on the server's own port, claimed
// from builtin/network -- what a search engine indexes and a pasted link
// opens:
//   /                the portal: the topics, the latest threads, search
//   /topic/<id>      a topic's threads
//   /t/<id>          a thread, every message under its anchor #m<id>
//   /m/<id>          one message, with the way to its thread
//   /search?q=...    FTS5 over the titles and the messages
// **To take part**: the buildat client, joined by builtin/accounts (a local
// account or a Starport ID, as the admin set up its logins). "hr:req"
// carries a JSON {id, cmd, ...} and "hr:res" the answer {id, ok, result |
// error}; handle() says who may do what. Pushed to a client: "hr:new"
// {thread, message} when the thread it has open gets a message (a chat
// runs on it), and "hr:notify" {unseen} when it has a notification.
//
// The records are one SQLite file, <user>/apps/<app>/hearth.sqlite, with
// a full-text index beside them; every statement binds its values.
//
// **Before the public** ([HEARTH_MVP] step 6): automatic trust -- a new
// account posts less and no links until a day has passed, it has read
// five threads and three of its messages stand (a message hidden in the
// last 30 days puts it back) -- with rate limits by level; reports of a
// message, a queue for the moderators (the server's admins), a hidden
// message's statement of reasons to its author, and the author's appeal.
// simplified: Hearth's own queue; Starport's reports, appeals and audit
// log shared as a builtin is the upgrade, once a third app wants them.
#include "core/log.h"
#include "core/json.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/markup.h"
#include "client_file/api.h"
#include "network/api.h"
#include "accounts/api.h"
#include <sqlite3.h>
#include <ctime>
#include <cstring>
#include <set>
#include <tuple>
#define MODULE "main"

using interface::Event;

static int64_t now_s(){ return (int64_t)time(nullptr); }

static ss_ jstr(const json::Value &v, const char *k)
{
	const json::Value &x = v.get(k);
	return x.is_string() ? x.as_string() : "";
}

static int64_t jint(const json::Value &v, const char *k)
{
	const json::Value &x = v.get(k);
	return x.is_number() ? (int64_t)x.as_number() : 0;
}

// What a user writes: up to `max` bytes, no control bytes but a tab and,
// where lines are allowed, a line break
static ss_ text_ok(const ss_ &s, size_t max, bool lines, const char *what)
{
	if(s.empty())
		return ss_(what)+" is empty";
	if(s.size() > max)
		return ss_(what)+" is "+itos((int64_t)max)+" bytes at most";
	for(char c : s)
		if((unsigned char)c < 0x20 && c != '\t' && !(lines && c == '\n'))
			return ss_(what)+" has a control character";
	return "";
}

static ss_ html(const ss_ &s)
{
	ss_ r;
	for(char c : s){
		switch(c){
		case '&': r += "&amp;"; break;
		case '<': r += "&lt;"; break;
		case '>': r += "&gt;"; break;
		case '"': r += "&quot;"; break;
		case '\'': r += "&#39;"; break;
		default: r += c;
		}
	}
	return r;
}

static ss_ url_decode(const ss_ &s)
{
	ss_ r;
	for(size_t i = 0; i < s.size(); i++){
		if(s[i] == '+'){
			r += ' ';
		} else if(s[i] == '%' && i + 2 < s.size() &&
				isxdigit((unsigned char)s[i + 1]) &&
				isxdigit((unsigned char)s[i + 2])){
			r += (char)strtol(s.substr(i + 1, 2).c_str(), nullptr, 16);
			i += 2;
		} else {
			r += s[i];
		}
	}
	return r;
}

static ss_ query_value(const ss_ &query, const ss_ &key)
{
	size_t at = 0;
	while(at <= query.size()){
		size_t amp = query.find('&', at);
		if(amp == ss_::npos)
			amp = query.size();
		const ss_ part = query.substr(at, amp - at);
		const size_t eq = part.find('=');
		if(eq != ss_::npos && part.substr(0, eq) == key)
			return url_decode(part.substr(eq + 1));
		at = amp + 1;
	}
	return "";
}

// A search as FTS5 reads it: each word a quoted string, so nothing a user
// types is the query language; the last one a prefix
static ss_ fts_query(const ss_ &q)
{
	ss_ out, word;
	auto flush = [&](bool last){
		if(word.empty())
			return;
		ss_ quoted = "\"";
		for(char c : word)
			quoted += c == '"' ? ss_("\"\"") : ss_(1, c);
		out += (out.empty() ? "" : " ")+quoted+"\""+(last ? "*" : "");
		word.clear();
	};
	for(char c : q){
		if(c == ' ' || c == '\t' || c == '\n')
			flush(false);
		else
			word += c;
	}
	flush(true);
	return out;
}

static ss_ time_text(int64_t t)
{
	time_t tt = (time_t)t;
	struct tm tmv = {};
#ifdef _WIN32
	gmtime_s(&tmv, &tt);
#else
	gmtime_r(&tt, &tmv);
#endif
	char buf[32];
	strftime(buf, sizeof buf, "%Y-%m-%d %H:%M UTC", &tmv);
	return buf;
}

// One statement: values bound in order, columns read by index
struct Q
{
	sqlite3 *db;
	sqlite3_stmt *st = nullptr;
	int n = 0;
	Q(sqlite3 *db, const char *sql): db(db)
	{
		if(sqlite3_prepare_v2(db, sql, -1, &st, nullptr) != SQLITE_OK)
			throw Exception(ss_("hearth: ")+sqlite3_errmsg(db)+" in "+sql);
	}
	~Q(){ sqlite3_finalize(st); }
	Q& b(int64_t v){ sqlite3_bind_int64(st, ++n, v); return *this; }
	Q& b(const ss_ &v)
	{
		sqlite3_bind_text(st, ++n, v.data(), (int)v.size(), SQLITE_TRANSIENT);
		return *this;
	}
	bool step()
	{
		const int rc = sqlite3_step(st);
		if(rc == SQLITE_ROW)
			return true;
		if(rc == SQLITE_DONE)
			return false;
		throw Exception(ss_("hearth: ")+sqlite3_errmsg(db));
	}
	int64_t i(int col){ return sqlite3_column_int64(st, col); }
	ss_ s(int col)
	{
		const char *p = (const char*)sqlite3_column_text(st, col);
		return p ? ss_(p, sqlite3_column_bytes(st, col)) : ss_();
	}
};

static const char *SCHEMA =
	"PRAGMA journal_mode=WAL;"
	"CREATE TABLE IF NOT EXISTS topics(id INTEGER PRIMARY KEY, "
		"parent INTEGER NOT NULL DEFAULT 0, name TEXT NOT NULL, "
		"about TEXT NOT NULL DEFAULT '');"
	// subject: what the thread is about, a package's "author/name" and key
	// ([PACKAGE_SUBJECT]); stored, and nothing reads it yet
	"CREATE TABLE IF NOT EXISTS threads(id INTEGER PRIMARY KEY, "
		"topic INTEGER NOT NULL, title TEXT NOT NULL, author TEXT NOT NULL, "
		"created INTEGER NOT NULL, last INTEGER NOT NULL, "
		"subject TEXT NOT NULL DEFAULT '', "
		// "This answered it": the message the asker marked, or 0
		"answer INTEGER NOT NULL DEFAULT 0, "
		// Its first message hidden: the thread with it
		"hidden INTEGER NOT NULL DEFAULT 0);"
	"CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, "
		"thread INTEGER NOT NULL, author TEXT NOT NULL, body TEXT NOT NULL, "
		"created INTEGER NOT NULL, edited INTEGER NOT NULL DEFAULT 0, "
		// A moderator's hiding, and its statement of reasons
		"hidden INTEGER NOT NULL DEFAULT 0, "
		"hidden_reason TEXT NOT NULL DEFAULT '');"
	"CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread, id);"
	"CREATE INDEX IF NOT EXISTS messages_author ON messages(author, created);"
	// What an edit replaced, and who made the edit
	"CREATE TABLE IF NOT EXISTS edits(message INTEGER NOT NULL, "
		"body TEXT NOT NULL, time INTEGER NOT NULL, editor TEXT NOT NULL);"
	// A row per message, its rowid the message's id; a thread's title is
	// on its first message
	"CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(title, body);"
	// Who follows a thread: whoever started it or wrote in it, and whoever
	// asked to
	"CREATE TABLE IF NOT EXISTS follows(account TEXT NOT NULL, "
		"thread INTEGER NOT NULL, PRIMARY KEY(account, thread));"
	// kind: "reply" (in a followed thread), "mention" (@name), "answer"
	// (a message of theirs answered a thread)
	"CREATE TABLE IF NOT EXISTS notifications(id INTEGER PRIMARY KEY, "
		"account TEXT NOT NULL, kind TEXT NOT NULL, thread INTEGER NOT NULL, "
		"message INTEGER NOT NULL, by TEXT NOT NULL, time INTEGER NOT NULL, "
		"seen INTEGER NOT NULL DEFAULT 0, "
		// A moderator's statement of reasons, for "hidden" and "appeal"
		"note TEXT NOT NULL DEFAULT '');"
	"CREATE INDEX IF NOT EXISTS notifications_account ON "
		"notifications(account, id);"
	// When an account first joined Hearth, and the threads it has read:
	// what its trust grows from
	"CREATE TABLE IF NOT EXISTS members(account TEXT PRIMARY KEY, "
		"first_seen INTEGER NOT NULL);"
	"CREATE TABLE IF NOT EXISTS reads(account TEXT NOT NULL, "
		"thread INTEGER NOT NULL, PRIMARY KEY(account, thread));"
	// kind "report" (of a message, by anyone) or "appeal" (of its hiding,
	// by its author); state "open", "upheld" or "dismissed"
	"CREATE TABLE IF NOT EXISTS reports(id INTEGER PRIMARY KEY, "
		"kind TEXT NOT NULL, message INTEGER NOT NULL, by TEXT NOT NULL, "
		"reason TEXT NOT NULL, time INTEGER NOT NULL, "
		"state TEXT NOT NULL DEFAULT 'open', handled_by TEXT NOT NULL DEFAULT '', "
		"handled_time INTEGER NOT NULL DEFAULT 0, "
		"statement TEXT NOT NULL DEFAULT '');";

static const char *const COLUMNS_ADDED[][3] = {
	{"threads", "answer", "INTEGER NOT NULL DEFAULT 0"},
	{"threads", "hidden", "INTEGER NOT NULL DEFAULT 0"},
	{"messages", "hidden", "INTEGER NOT NULL DEFAULT 0"},
	{"messages", "hidden_reason", "TEXT NOT NULL DEFAULT ''"},
	{"notifications", "note", "TEXT NOT NULL DEFAULT ''"},
};
static const char *CLAIMED[] = {"/topic/", "/t/", "/m/", "/search"};

// Trust ([HEARTH_MVP] step 6): what a level may post. Level 0 is a new
// account, 1 one that has stood a while, 2 the admin
struct Limits { int threads_a_day, messages_an_hour; bool links; };
static const Limits LIMITS[3] = {{2, 10, false}, {10, 60, true},
		{1000000, 1000000, true}};
static const int REPORTS_A_DAY = 10;
// Searches a minute, per address on the HTTP face and per account by
// packet: a search is a full-text query
static const int SEARCHES_A_MINUTE = 30;
static const size_t TITLE_MAX = 200;
static const size_t BODY_MAX = 20000;
static const size_t NAME_MAX = 80;

struct Module: public interface::Module
{
	interface::Server *m_server;
	sqlite3 *m_db = nullptr;
	// The thread each client has open, for "hr:new"
	sm_<network::PeerId, int64_t> m_viewing;
	// Searches per address in the current minute
	sm_<ss_, int> m_searches;
	int64_t m_searches_minute = 0;
	// What a request changed, sent once it is committed
	sv_<int64_t> m_new_messages;
	std::set<ss_> m_notified;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		if(m_db)
			sqlite3_close(m_db);
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("network:packet_received/hr:req"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:http_request", on_http, network::HttpRequest)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/hr:req", on_req, network::Packet)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
	}

	void on_client_disconnected(const network::OldClient &old)
	{
		m_viewing.erase(old.info.id);
	}

	void on_start()
	{
		// One user's clients at once, as in floorplanner
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_multiple_logins(true);
		});
		const interface::ServerConfig &c = m_server->get_config();
		const ss_ dir = c.get<ss_>("user_path")+"/apps/"+m_server->get_app_id();
		interface::fs::create_directories(dir);
		const ss_ path = dir+"/hearth.sqlite";
		if(sqlite3_open(path.c_str(), &m_db) != SQLITE_OK)
			throw Exception("hearth: cannot open "+path);
		char *err = nullptr;
		if(sqlite3_exec(m_db, SCHEMA, nullptr, nullptr, &err) != SQLITE_OK){
			const ss_ e = err ? err : "";
			sqlite3_free(err);
			throw Exception("hearth: the schema: "+e);
		}
		// A file from before a column (2026-10-04's first ones)
		for(const char *const *c : COLUMNS_ADDED){
			Q cols(m_db, (ss_("SELECT count(*) FROM pragma_table_info('")+
					c[0]+"') WHERE name = '"+c[1]+"'").c_str());
			cols.step();
			if(cols.i(0) == 0)
				exec((ss_("ALTER TABLE ")+c[0]+" ADD COLUMN "+c[1]+" "+c[2])
						.c_str());
		}
		network::access(m_server, [&](network::Interface *iface){
			iface->claim_http_path("/");
			for(const char *p : CLAIMED)
				iface->claim_http_path(p);
		});
		Q q(m_db, "SELECT count(*) FROM messages");
		q.step();
		log_i(MODULE, "Hearth: %lld messages in %s", (long long)q.i(0),
				cs(path));
	}

	void exec(const char *sql)
	{
		Q q(m_db, sql);
		q.step();
	}

	// -----------------------------------------------------------------------
	// Reading and writing

	json::Value topics()
	{
		json::Value list = json::array();
		Q q(m_db, "SELECT t.id, t.parent, t.name, t.about, "
				"(SELECT count(*) FROM threads WHERE topic = t.id AND hidden = 0) "
				"FROM topics t ORDER BY t.parent, t.id");
		while(q.step()){
			json::Value t = json::object();
			t.set("id", q.i(0));
			t.set("parent", q.i(1));
			t.set("name", q.s(2));
			t.set("about", q.s(3));
			t.set("threads", q.i(4));
			list.append(t);
		}
		return list;
	}

	json::Value topic(int64_t id)
	{
		Q q(m_db, "SELECT name, about, parent FROM topics WHERE id = ?");
		q.b(id);
		if(!q.step())
			return json::Value();
		json::Value t = json::object();
		t.set("id", id);
		t.set("name", q.s(0));
		t.set("about", q.s(1));
		t.set("parent", q.i(2));
		return t;
	}

	json::Value thread_row(Q &q)
	{
		json::Value t = json::object();
		t.set("id", q.i(0));
		t.set("topic", q.i(1));
		t.set("title", q.s(2));
		t.set("author", q.s(3));
		t.set("created", q.i(4));
		t.set("last", q.i(5));
		t.set("subject", q.s(6));
		t.set("messages", q.i(7));
		t.set("answer", q.i(8));
		t.set("hidden", q.i(9) != 0);
		return t;
	}
#define THREAD_COLUMNS "id, topic, title, author, created, last, subject, " \
		"(SELECT count(*) FROM messages WHERE thread = threads.id), answer, " \
		"hidden"

	// Answered ones first, then by the latest message
	// simplified: 200; paging when a topic has more
	json::Value threads(int64_t topic_id)
	{
		json::Value list = json::array();
		Q q(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE topic = ? "
				"AND hidden = 0 ORDER BY answer != 0 DESC, last DESC LIMIT 200");
		q.b(topic_id);
		while(q.step())
			list.append(thread_row(q));
		return list;
	}

	json::Value latest_threads(int n)
	{
		json::Value list = json::array();
		Q q(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE hidden = 0 "
				"ORDER BY last DESC LIMIT ?");
		q.b((int64_t)n);
		while(q.step())
			list.append(thread_row(q));
		return list;
	}

	// The thread and its messages after `after` (0: all of them). A hidden
	// message's body is its author's and the admin's to see
	// simplified: 1000 messages at most a call; a longer thread is read on
	// with `after`
	json::Value thread(int64_t id, int64_t after, const ss_ &viewer = "",
			bool admin = false)
	{
		Q q(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE id = ?");
		q.b(id);
		if(!q.step())
			return json::Value();
		json::Value t = thread_row(q);
		json::Value list = json::array();
		Q m(m_db, "SELECT id, author, body, created, edited, hidden, "
				"hidden_reason FROM messages "
				"WHERE thread = ? AND id > ? ORDER BY id LIMIT 1000");
		m.b(id).b(after);
		while(m.step()){
			json::Value v = json::object();
			const bool hidden = m.i(5) != 0;
			v.set("id", m.i(0));
			v.set("author", m.s(1));
			v.set("body", hidden && !admin && viewer != m.s(1) ? ss_() : m.s(2));
			v.set("created", m.i(3));
			v.set("edited", m.i(4));
			v.set("hidden", hidden);
			v.set("hidden_reason", m.s(6));
			list.append(v);
		}
		t.set("list", list);
		return t;
	}

	int64_t add_message(int64_t thread_id, const ss_ &author, const ss_ &body,
			const ss_ &title)
	{
		const int64_t t = now_s();
		Q q(m_db, "INSERT INTO messages(thread, author, body, created) "
				"VALUES(?, ?, ?, ?)");
		q.b(thread_id).b(author).b(body).b(t).step();
		const int64_t id = sqlite3_last_insert_rowid(m_db);
		Q s(m_db, "INSERT INTO search(rowid, title, body) VALUES(?, ?, ?)");
		s.b(id).b(title).b(body).step();
		Q u(m_db, "UPDATE threads SET last = ? WHERE id = ?");
		u.b(t).b(thread_id).step();
		// Who is told: those mentioned, then the thread's other followers
		std::set<ss_> told;
		for(const ss_ &n : mentions(body)){
			if(n == author || told.count(n))
				continue;
			bool exists = false;
			accounts::access(m_server, [&](accounts::Interface *a){
				exists = a->exists(n);
			});
			if(exists){
				notify(n, "mention", thread_id, id, author);
				told.insert(n);
			}
		}
		Q f(m_db, "SELECT account FROM follows WHERE thread = ?");
		f.b(thread_id);
		while(f.step())
			if(f.s(0) != author && !told.count(f.s(0)))
				notify(f.s(0), "reply", thread_id, id, author);
		Q fo(m_db, "INSERT OR IGNORE INTO follows(account, thread) VALUES(?, ?)");
		fo.b(author).b(thread_id).step();
		m_new_messages.push_back(thread_id);
		m_new_messages.push_back(id);
		return id;
	}

	// "@name" in a message: a name's characters after an @ that does not
	// follow a word (an address's @ is not one)
	static std::set<ss_> mentions(const ss_ &body)
	{
		std::set<ss_> r;
		for(size_t i = 0; i < body.size(); i++){
			if(body[i] != '@' || (i > 0 && (isalnum((unsigned char)body[i - 1]) ||
					body[i - 1] == '_')))
				continue;
			size_t e = i + 1;
			while(e < body.size() && e - i <= NAME_MAX &&
					(isalnum((unsigned char)body[e]) || body[e] == '_' ||
					body[e] == '-'))
				e++;
			if(e > i + 1)
				r.insert(body.substr(i + 1, e - i - 1));
			if(r.size() >= 20)
				break;
		}
		return r;
	}

	void notify(const ss_ &account, const char *kind, int64_t thread_id,
			int64_t message_id, const ss_ &by, const ss_ &note = "")
	{
		Q n(m_db, "INSERT INTO notifications(account, kind, thread, message, "
				"by, time, note) VALUES(?, ?, ?, ?, ?, ?, ?)");
		n.b(account).b(ss_(kind)).b(thread_id).b(message_id).b(by).b(now_s())
				.b(note).step();
		m_notified.insert(account);
	}

	int64_t unseen(const ss_ &account)
	{
		Q q(m_db, "SELECT count(*) FROM notifications WHERE account = ? "
				"AND seen = 0");
		q.b(account);
		q.step();
		return q.i(0);
	}

	// After a commit: "hr:new" to whoever has the thread open, "hr:notify"
	// to whoever was notified
	void push()
	{
		sv_<std::tuple<network::PeerId, ss_, ss_>> out;
		for(size_t i = 0; i + 1 < m_new_messages.size(); i += 2){
			json::Value v = json::object();
			v.set("thread", m_new_messages[i]);
			v.set("message", m_new_messages[i + 1]);
			for(auto &pv : m_viewing)
				if(pv.second == m_new_messages[i])
					out.emplace_back(pv.first, "hr:new", v.stringify());
		}
		for(const ss_ &account : m_notified){
			sv_<network::PeerId> peers;
			accounts::access(m_server, [&](accounts::Interface *a){
				peers = a->find_peers(account);
			});
			json::Value v = json::object();
			v.set("unseen", unseen(account));
			for(network::PeerId p : peers)
				out.emplace_back(p, "hr:notify", v.stringify());
		}
		m_new_messages.clear();
		m_notified.clear();
		network::access(m_server, [&](network::Interface *iface){
			for(auto &o : out)
				iface->send(std::get<0>(o), std::get<1>(o), std::get<2>(o));
		});
	}

	json::Value search(const ss_ &text)
	{
		json::Value list = json::array();
		const ss_ match = fts_query(text);
		if(match.empty())
			return list;
		// simplified: BM25, the title weighed 5 to the body's 1, and an
		// answer counted twice (BM25 is better the more negative); the other
		// signals and recency join it with the computed portal
		Q q(m_db, "SELECT m.id, m.thread, t.title, m.author, m.created, "
				"snippet(search, 1, '\x01', '\x02', '...', 24) "
				"FROM search JOIN messages m ON m.id = search.rowid "
				"JOIN threads t ON t.id = m.thread "
				"WHERE search MATCH ? AND m.hidden = 0 AND t.hidden = 0 "
				"ORDER BY bm25(search, 5.0, 1.0) * "
				"(CASE WHEN t.answer = m.id THEN 2.0 ELSE 1.0 END) LIMIT 50");
		q.b(match);
		while(q.step()){
			json::Value v = json::object();
			v.set("message", q.i(0));
			v.set("thread", q.i(1));
			v.set("title", q.s(2));
			v.set("author", q.s(3));
			v.set("created", q.i(4));
			v.set("snippet", q.s(5));
			list.append(v);
		}
		return list;
	}

	// -----------------------------------------------------------------------
	// The HTML face

	void respond(const network::HttpRequest &r, int status, const ss_ &body)
	{
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, status, "text/html; charset=utf-8",
					body);
		});
	}

	ss_ page(const ss_ &title, const ss_ &content)
	{
		return "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
				"<meta name=\"viewport\" content=\"width=device-width, "
				"initial-scale=1\"><title>"+html(title)+"</title><style>"
				"body{max-width:46em;margin:0 auto;padding:0 1em;"
				"font:16px/1.5 sans-serif;color:#222;background:#fff}"
				"header{border-bottom:2px solid #444;padding:.5em 0;"
				"display:flex;gap:1em;align-items:center;flex-wrap:wrap}"
				"header a{font-weight:bold}"
				"a{color:#1a4fa0}"
				".box{border:1px solid #999;border-radius:4px;padding:.5em 1em;"
				"margin:1em 0}"
				".meta{color:#555;font-size:.9em}"
				".answer{border:2px solid #2a7a2a}"
				"ul.list{padding-left:1.2em}"
				"mark{background:#fe8}"
				"pre{overflow-x:auto;background:#f4f4f4;padding:.5em}"
				"code{background:#f4f4f4}"
				"blockquote{border-left:3px solid #999;margin:0;padding-left:1em}"
				"td,th{border:1px solid #999;padding:0 .4em}"
				"table{border-collapse:collapse}"
				".spoiler{background:#222;color:#222}"
				".spoiler:hover,.spoiler:focus{background:none;color:inherit}"
				"input,button{font:inherit}"
				"</style></head><body><header><a href=\"/\">Hearth</a>"
				"<form action=\"/search\"><input name=\"q\" size=\"24\" "
				"aria-label=\"Search\"> <button>Search</button></form>"
				"</header>\n"+content+
				"\n<p class=\"meta\">Posts are CC-BY-SA. To take part, open "
				"this server in the buildat client (<a href=\"/index.html\">"
				"in the browser</a>).</p></body></html>\n";
	}

	ss_ thread_line(const json::Value &t)
	{
		return "<li><a href=\"/t/"+itos(jint(t, "id"))+"\">"+
				html(jstr(t, "title"))+"</a> <span class=\"meta\">"+
				(jint(t, "answer") ? "answered, " : "")+
				html(jstr(t, "author"))+", "+itos(jint(t, "messages"))+
				" messages, last "+time_text(jint(t, "last"))+"</span></li>\n";
	}

	ss_ message_box(const json::Value &m, bool answer = false)
	{
		const ss_ id = itos(jint(m, "id"));
		if(m.get("hidden").is_true())
			return "<div class=\"box\" id=\"m"+id+"\"><p class=\"meta\">"
					"Hidden by a moderator: "+html(jstr(m, "hidden_reason"))+
					"</p></div>\n";
		return "<div class=\"box"+ss_(answer ? " answer" : "")+"\" id=\"m"+id+
				"\"><p class=\"meta\">"+(answer ? "<b>This answered it:</b> " :
				"")+"<b>"+
				html(jstr(m, "author"))+"</b>, <a href=\"/m/"+id+"\">"+
				time_text(jint(m, "created"))+"</a>"+(jint(m, "edited") ?
				" (edited "+time_text(jint(m, "edited"))+")" : "")+"</p>"+
				interface::markup::to_html(jstr(m, "body"))+"</div>\n";
	}

	// The id after a prefix, or -1
	static int64_t path_id(const ss_ &path, const ss_ &prefix)
	{
		if(path.compare(0, prefix.size(), prefix) != 0)
			return -1;
		const ss_ rest = path.substr(prefix.size());
		if(rest.empty() || rest.size() > 15 ||
				rest.find_first_not_of("0123456789") != ss_::npos)
			return -1;
		return atoll(rest.c_str());
	}

	void on_http(const network::HttpRequest &r)
	{
		// Every claimed path is answered, a 404 where nothing is
		bool ours = r.path == "/";
		for(const char *p : CLAIMED)
			ours = ours || r.path.compare(0, strlen(p), p) == 0;
		if(!ours)
			return;
		if(!m_db)
			return respond(r, 503, page("Hearth", "<p>Starting.</p>"));
		if(r.path == "/search" && !search_allowed(r.address))
			return respond(r, 429, page("Hearth", "<p>Too many searches "
					"from this address; try again in a minute.</p>"));
		ss_ title, body;
		if(r.method == "GET")
			http_page(r.path, r.query, title, body);
		if(body.empty())
			return respond(r, 404, page("Not found", "<p>Nothing is here.</p>"));
		respond(r, 200, page(title, body));
	}

	void http_page(const ss_ &path, const ss_ &query, ss_ &title, ss_ &body)
	{
		int64_t id;
		if(path == "/"){
			title = "Hearth";
			body = "<h1>Hearth</h1>\n<h2>Topics</h2>\n<ul class=\"list\">\n";
			const json::Value ts = topics();
			for(unsigned i = 0; i < ts.size(); i++){
				const json::Value &t = ts.at(i);
				if(jint(t, "parent") != 0)
					continue;
				body += "<li><a href=\"/topic/"+itos(jint(t, "id"))+"\">"+
						html(jstr(t, "name"))+"</a> <span class=\"meta\">"+
						html(jstr(t, "about"))+" ("+itos(jint(t, "threads"))+
						" threads)</span>";
				ss_ sub;
				for(unsigned j = 0; j < ts.size(); j++)
					if(jint(ts.at(j), "parent") == jint(t, "id"))
						sub += "<li><a href=\"/topic/"+
								itos(jint(ts.at(j), "id"))+"\">"+
								html(jstr(ts.at(j), "name"))+"</a></li>";
				if(!sub.empty())
					body += "<ul>"+sub+"</ul>";
				body += "</li>\n";
			}
			body += "</ul>\n<h2>Latest</h2>\n<ul class=\"list\">\n";
			const json::Value latest = latest_threads(20);
			for(unsigned i = 0; i < latest.size(); i++)
				body += thread_line(latest.at(i));
			body += "</ul>\n";
		} else if((id = path_id(path, "/topic/")) >= 0){
			const json::Value t = topic(id);
			if(!t.is_object())
				return;
			title = jstr(t, "name")+" - Hearth";
			body = "<h1>"+html(jstr(t, "name"))+"</h1>\n<p>"+
					html(jstr(t, "about"))+"</p>\n<ul class=\"list\">\n";
			const json::Value list = threads(id);
			for(unsigned i = 0; i < list.size(); i++)
				body += thread_line(list.at(i));
			body += "</ul>\n";
		} else if((id = path_id(path, "/t/")) >= 0){
			const json::Value t = thread(id, 0);
			if(!t.is_object())
				return;
			const json::Value top = topic(jint(t, "topic"));
			if(t.get("hidden").is_true()){
				// Its title too, which is what a spammer's thread is
				title = "A hidden thread - Hearth";
				body = "<h1>A hidden thread</h1>\n"+
						message_box(t.get("list").at(0));
				return;
			}
			title = jstr(t, "title")+" - Hearth";
			body = "<p class=\"meta\"><a href=\"/topic/"+
					itos(jint(t, "topic"))+"\">"+html(jstr(top, "name"))+
					"</a></p>\n<h1>"+html(jstr(t, "title"))+"</h1>\n";
			// The question, its answer, then the rest in order
			const json::Value &list = t.get("list");
			const int64_t answer = jint(t, "answer");
			for(unsigned i = 0; i < list.size(); i++){
				if(jint(list.at(i), "id") == answer)
					continue;
				body += message_box(list.at(i));
				for(unsigned j = 0; i == 0 && j < list.size(); j++)
					if(jint(list.at(j), "id") == answer)
						body += message_box(list.at(j), true);
			}
		} else if((id = path_id(path, "/m/")) >= 0){
			Q q(m_db, "SELECT m.id, m.author, m.body, m.created, m.edited, "
					"m.thread, t.title, m.hidden, m.hidden_reason, t.hidden "
					"FROM messages m "
					"JOIN threads t ON t.id = m.thread WHERE m.id = ?");
			q.b(id);
			if(!q.step())
				return;
			json::Value m = json::object();
			m.set("id", q.i(0));
			m.set("author", q.s(1));
			m.set("body", q.i(7) ? ss_() : q.s(2));
			m.set("created", q.i(3));
			m.set("edited", q.i(4));
			m.set("hidden", q.i(7) != 0);
			m.set("hidden_reason", q.s(8));
			const ss_ thread_title = q.i(9) ? ss_("A hidden thread") : q.s(6);
			title = thread_title+" - Hearth";
			body = "<p class=\"meta\">In <a href=\"/t/"+itos(q.i(5))+"#m"+
					itos(id)+"\">"+html(thread_title)+"</a></p>\n"+
					message_box(m);
		} else if(path == "/search"){
			const ss_ text = query_value(query, "q").substr(0, 200);
			title = text+" - Hearth search";
			body = "<h1>Search: "+html(text)+"</h1>\n<ul class=\"list\">\n";
			const json::Value list = search(text);
			for(unsigned i = 0; i < list.size(); i++){
				const json::Value &v = list.at(i);
				// The marks are bytes no message holds (control bytes are
				// refused), put in after the escaping
				ss_ snip = html(jstr(v, "snippet"));
				for(size_t at; (at = snip.find('\x01')) != ss_::npos;)
					snip.replace(at, 1, "<mark>");
				for(size_t at; (at = snip.find('\x02')) != ss_::npos;)
					snip.replace(at, 1, "</mark>");
				body += "<li><a href=\"/t/"+itos(jint(v, "thread"))+"#m"+
						itos(jint(v, "message"))+"\">"+html(jstr(v, "title"))+
						"</a> <span class=\"meta\">"+html(jstr(v, "author"))+
						"</span><br>"+snip+"</li>\n";
			}
			if(list.size() == 0)
				body += "<li>Nothing found.</li>\n";
			body += "</ul>\n";
		}
	}

	// -----------------------------------------------------------------------
	// The client

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface *iface){
			iface->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
	}

	void on_req(const network::Packet &packet)
	{
		const json::Value q = json::load_string(packet.data.c_str());
		json::Value res = json::object();
		res.set("id", q.get("id"));
		ss_ name;
		bool admin = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			name = a->name_of(packet.sender);
			admin = !name.empty() && a->is_admin(name);
		});
		ss_ error;
		json::Value result;
		if(!m_db)
			error = "Hearth is not ready";
		else if(name.empty())
			error = "join first";
		else {
			try {
				exec("BEGIN");
				result = handle(name, admin, jstr(q, "cmd"), q, packet.sender);
				exec("COMMIT");
			} catch(std::exception &e){
				sqlite3_exec(m_db, "ROLLBACK", nullptr, nullptr, nullptr);
				m_new_messages.clear();
				m_notified.clear();
				error = e.what();
			}
		}
		res.set("ok", error.empty());
		if(error.empty())
			res.set("result", result);
		else
			res.set("error", error);
		network::access(m_server, [&](network::Interface *iface){
			iface->send(packet.sender, "hr:res", res.stringify());
		});
		push();
	}

	// 0 a new account, 1 one that has stood a while, 2 the admin
	int level(const ss_ &name, bool admin)
	{
		if(admin)
			return 2;
		const int64_t now = now_s();
		Q h(m_db, "SELECT count(*) FROM messages WHERE author = ? AND "
				"hidden = 0");
		h.b(name).step();
		const int64_t stood = h.i(0);
		Q hd(m_db, "SELECT count(*) FROM messages WHERE author = ? AND "
				"hidden != 0 AND created > ?");
		hd.b(name).b(now - 30 * 86400).step();
		Q f(m_db, "SELECT first_seen FROM members WHERE account = ?");
		f.b(name);
		const int64_t first = f.step() ? f.i(0) : now;
		Q r(m_db, "SELECT count(*) FROM reads WHERE account = ?");
		r.b(name).step();
		return now - first >= 86400 && r.i(0) >= 5 && stood >= 3 &&
				hd.i(0) == 0 ? 1 : 0;
	}

	// `who`: an address, or "@" and an account
	bool search_allowed(const ss_ &who)
	{
		if(now_s() / 60 != m_searches_minute){
			m_searches_minute = now_s() / 60;
			m_searches.clear();
		}
		return ++m_searches[who] <= SEARCHES_A_MINUTE;
	}

	// An address in the text, or a link the markup makes ("//host",
	// "mailto:", a reference definition) without one
	static bool has_link(const ss_ &text)
	{
		ss_ t = text;
		for(char &c : t)
			c = tolower((unsigned char)c);
		return t.find("://") != ss_::npos || t.find("www.") != ss_::npos ||
				interface::markup::to_html(text).find("<a ") != ss_::npos;
	}

	// Whether `name` may post this now, by its level; why not
	void check_limits(const ss_ &name, bool admin, bool new_thread,
			const ss_ &text)
	{
		const int lv = level(name, admin);
		const Limits &l = LIMITS[lv];
		const char *how = lv == 0 ? " (a new account's limit, until a day "
				"has passed, five threads are read and three of its messages "
				"stand)" : "";
		if(!l.links && has_link(text))
			throw Exception(ss_("no links yet")+how);
		// An edit counts as a message: each keeps the old body
		Q m(m_db, "SELECT (SELECT count(*) FROM messages WHERE author = ? "
				"AND created > ?) + (SELECT count(*) FROM edits WHERE "
				"editor = ? AND time > ?)");
		m.b(name).b(now_s() - 3600).b(name).b(now_s() - 3600).step();
		if(m.i(0) >= l.messages_an_hour)
			throw Exception(itos(l.messages_an_hour)+" messages an hour at "
					"most"+how);
		if(new_thread){
			Q t(m_db, "SELECT count(*) FROM threads WHERE author = ? AND "
					"created > ?");
			t.b(name).b(now_s() - 86400).step();
			if(t.i(0) >= l.threads_a_day)
				throw Exception(itos(l.threads_a_day)+" new threads a day at "
						"most"+how);
		}
	}

	// Hidden or shown again: the message, its thread if it is the first,
	// and the search index
	void set_hidden(int64_t message_id, bool hidden, const ss_ &reason)
	{
		Q m(m_db, "SELECT m.thread, m.body, t.title, (SELECT min(id) FROM "
				"messages WHERE thread = m.thread) FROM messages m JOIN threads t "
				"ON t.id = m.thread WHERE m.id = ?");
		m.b(message_id);
		if(!m.step())
			throw Exception("no such message");
		const bool first = m.i(3) == message_id;
		Q u(m_db, "UPDATE messages SET hidden = ?, hidden_reason = ? "
				"WHERE id = ?");
		u.b((int64_t)hidden).b(hidden ? reason : ss_()).b(message_id).step();
		if(first){
			Q t(m_db, "UPDATE threads SET hidden = ? WHERE id = ?");
			t.b((int64_t)hidden).b(m.i(0)).step();
		}
		Q d(m_db, "DELETE FROM search WHERE rowid = ?");
		d.b(message_id).step();
		if(!hidden){
			Q i(m_db, "INSERT INTO search(rowid, title, body) VALUES(?, ?, ?)");
			i.b(message_id).b(first ? m.s(2) : ss_()).b(m.s(1)).step();
		}
	}

	static void need(const ss_ &why)
	{
		if(!why.empty())
			throw Exception(why);
	}

	json::Value handle(const ss_ &name, bool admin, const ss_ &cmd,
			const json::Value &q, network::PeerId peer)
	{
		if(cmd == "me"){
			json::Value v = json::object();
			v.set("account", name);
			v.set("admin", admin);
			v.set("unseen", unseen(name));
			Q mb(m_db, "INSERT OR IGNORE INTO members(account, first_seen) "
					"VALUES(?, ?)");
			mb.b(name).b(now_s()).step();
			v.set("level", (int64_t)level(name, admin));
			if(admin){
				Q o(m_db, "SELECT count(*) FROM reports WHERE state = 'open'");
				o.step();
				v.set("open_reports", o.i(0));
			}
			return v;
		}
		if(cmd != "thread" && cmd != "reply" && cmd != "edit" &&
				cmd != "answered" && cmd != "follow")
			m_viewing.erase(peer);
		if(cmd == "topics"){
			json::Value v = json::object();
			v.set("topics", topics());
			v.set("latest", latest_threads(20));
			return v;
		}
		if(cmd == "topic"){
			json::Value t = topic(jint(q, "topic"));
			if(!t.is_object())
				throw Exception("no such topic");
			t.set("threads", threads(jint(q, "topic")));
			return t;
		}
		if(cmd == "thread"){
			json::Value t = thread(jint(q, "thread"), jint(q, "after"), name,
					admin);
			if(!t.is_object())
				throw Exception("no such thread");
			m_viewing[peer] = jint(q, "thread");
			Q rd(m_db, "INSERT OR IGNORE INTO reads(account, thread) "
					"VALUES(?, ?)");
			rd.b(name).b(jint(q, "thread")).step();
			Q f(m_db, "SELECT 1 FROM follows WHERE account = ? AND thread = ?");
			f.b(name).b(jint(q, "thread"));
			t.set("following", f.step());
			return t;
		}
		if(cmd == "search"){
			const ss_ text = jstr(q, "q");
			need(text_ok(text, 200, false, "the search"));
			if(!search_allowed("@"+name))
				throw Exception("too many searches; try again in a minute");
			return search(text);
		}
		if(cmd == "new_topic"){
			// The tree changes rarely, by a trusted hand: the admin's
			if(!admin)
				throw Exception("only the admin adds topics");
			const ss_ topic_name = jstr(q, "name"), about = jstr(q, "about");
			need(text_ok(topic_name, NAME_MAX, false, "the name"));
			if(!about.empty())
				need(text_ok(about, 400, false, "the description"));
			const int64_t parent = jint(q, "parent");
			if(parent != 0 && !topic(parent).is_object())
				throw Exception("no such parent topic");
			Q i(m_db, "INSERT INTO topics(parent, name, about) VALUES(?, ?, ?)");
			i.b(parent).b(topic_name).b(about).step();
			log_i(MODULE, "%s added the topic %s", cs(name), cs(topic_name));
			return json::Value((int64_t)sqlite3_last_insert_rowid(m_db));
		}
		if(cmd == "new_thread"){
			const int64_t topic_id = jint(q, "topic");
			const ss_ title = jstr(q, "title"), body = jstr(q, "body"),
					subject = jstr(q, "subject");
			if(!topic(topic_id).is_object())
				throw Exception("no such topic");
			need(text_ok(title, TITLE_MAX, false, "the title"));
			need(text_ok(body, BODY_MAX, true, "the message"));
			if(!subject.empty())
				need(text_ok(subject, 400, false, "the subject"));
			check_limits(name, admin, true, title+"\n"+body);
			const int64_t t = now_s();
			Q i(m_db, "INSERT INTO threads(topic, title, author, created, last, "
					"subject) VALUES(?, ?, ?, ?, ?, ?)");
			i.b(topic_id).b(title).b(name).b(t).b(t).b(subject).step();
			const int64_t id = sqlite3_last_insert_rowid(m_db);
			add_message(id, name, body, title);
			return json::Value(id);
		}
		if(cmd == "reply"){
			const int64_t thread_id = jint(q, "thread");
			const ss_ body = jstr(q, "body");
			Q t(m_db, "SELECT 1 FROM threads WHERE id = ?");
			t.b(thread_id);
			if(!t.step())
				throw Exception("no such thread");
			need(text_ok(body, BODY_MAX, true, "the message"));
			Q th(m_db, "SELECT hidden FROM threads WHERE id = ?");
			th.b(thread_id).step();
			if(th.i(0) && !admin)
				throw Exception("the thread is hidden");
			check_limits(name, admin, false, body);
			return json::Value(add_message(thread_id, name, body, ""));
		}
		if(cmd == "edit"){
			const int64_t id = jint(q, "message");
			const ss_ body = jstr(q, "body");
			Q m(m_db, "SELECT author, body FROM messages WHERE id = ?");
			m.b(id);
			if(!m.step())
				throw Exception("no such message");
			if(m.s(0) != name && !admin)
				throw Exception("only its author edits a message");
			need(text_ok(body, BODY_MAX, true, "the message"));
			check_limits(name, admin, false, body);
			const int64_t t = now_s();
			Q h(m_db, "INSERT INTO edits(message, body, time, editor) "
					"VALUES(?, ?, ?, ?)");
			h.b(id).b(m.s(1)).b(t).b(name).step();
			Q u(m_db, "UPDATE messages SET body = ?, edited = ? WHERE id = ?");
			u.b(body).b(t).b(id).step();
			Q s(m_db, "UPDATE search SET body = ? WHERE rowid = ?");
			s.b(body).b(id).step();
			return json::Value(true);
		}
		if(cmd == "answered"){
			// By whoever asked (or the admin); message 0 takes it back
			const int64_t thread_id = jint(q, "thread"),
					message_id = jint(q, "message");
			Q t(m_db, "SELECT author, (SELECT min(id) FROM messages "
					"WHERE thread = threads.id) FROM threads WHERE id = ?");
			t.b(thread_id);
			if(!t.step())
				throw Exception("no such thread");
			if(t.s(0) != name && !admin)
				throw Exception("only whoever started the thread says what "
						"answered it");
			ss_ by;
			if(message_id != 0){
				Q m(m_db, "SELECT author FROM messages WHERE id = ? AND "
						"thread = ?");
				m.b(message_id).b(thread_id);
				if(!m.step() || message_id == t.i(1))
					throw Exception("not a reply in this thread");
				by = m.s(0);
			}
			Q u(m_db, "UPDATE threads SET answer = ? WHERE id = ?");
			u.b(message_id).b(thread_id).step();
			if(!by.empty() && by != name)
				notify(by, "answer", thread_id, message_id, name);
			return json::Value(true);
		}
		if(cmd == "follow"){
			const int64_t thread_id = jint(q, "thread");
			if(q.get("on").is_true()){
				Q f(m_db, "INSERT OR IGNORE INTO follows(account, thread) "
						"SELECT ?, id FROM threads WHERE id = ?");
				f.b(name).b(thread_id).step();
			} else {
				Q f(m_db, "DELETE FROM follows WHERE account = ? AND thread = ?");
				f.b(name).b(thread_id).step();
			}
			return json::Value(true);
		}
		if(cmd == "notifications"){
			// The latest 50, and they are seen now
			json::Value list = json::array();
			Q n(m_db, "SELECT n.id, n.kind, n.thread, n.message, n.by, n.time, "
					"n.seen, t.title, n.note FROM notifications n JOIN threads t ON "
					"t.id = n.thread WHERE n.account = ? ORDER BY n.id DESC "
					"LIMIT 50");
			n.b(name);
			while(n.step()){
				json::Value v = json::object();
				v.set("id", n.i(0));
				v.set("kind", n.s(1));
				v.set("thread", n.i(2));
				v.set("message", n.i(3));
				v.set("by", n.s(4));
				v.set("time", n.i(5));
				v.set("seen", n.i(6) != 0);
				v.set("title", n.s(7));
				v.set("note", n.s(8));
				list.append(v);
			}
			Q u(m_db, "UPDATE notifications SET seen = 1 WHERE account = ? "
					"AND seen = 0");
			u.b(name).step();
			return list;
		}
		if(cmd == "report" || cmd == "appeal"){
			// A report: someone else's shown message. An appeal: one's own
			// hidden message. One open of each per account and message.
			const bool appeal = cmd == "appeal";
			const int64_t id = jint(q, "message");
			const ss_ reason = jstr(q, appeal ? "text" : "reason");
			need(text_ok(reason, 1000, true, appeal ? "the appeal" :
					"the reason"));
			Q m(m_db, "SELECT author, hidden FROM messages WHERE id = ?");
			m.b(id);
			if(!m.step())
				throw Exception("no such message");
			if(appeal && m.s(0) != name)
				throw Exception("only its author appeals");
			if(appeal && !m.i(1))
				throw Exception("the message is not hidden");
			if(!appeal && m.s(0) == name)
				throw Exception("one's own message is edited, not reported");
			if(!appeal && m.i(1))
				throw Exception("the message is hidden already");
			Q o(m_db, "SELECT 1 FROM reports WHERE kind = ? AND message = ? AND "
					"by = ? AND state = 'open'");
			o.b(cmd).b(id).b(name);
			if(o.step())
				throw Exception(appeal ? "the appeal is waiting already" :
						"the report is waiting already");
			Q d(m_db, "SELECT count(*) FROM reports WHERE by = ? AND time > ?");
			d.b(name).b(now_s() - 86400).step();
			if(!admin && d.i(0) >= REPORTS_A_DAY)
				throw Exception(itos(REPORTS_A_DAY)+" reports a day at most");
			Q i(m_db, "INSERT INTO reports(kind, message, by, reason, time) "
					"VALUES(?, ?, ?, ?, ?)");
			i.b(cmd).b(id).b(name).b(reason).b(now_s()).step();
			return json::Value((int64_t)sqlite3_last_insert_rowid(m_db));
		}
		if(cmd == "queue"){
			if(!admin)
				throw Exception("only the admin moderates");
			json::Value list = json::array();
			Q r(m_db, "SELECT r.id, r.kind, r.message, r.by, r.reason, r.time, "
					"m.author, m.body, m.thread, t.title, m.hidden_reason FROM "
					"reports r JOIN messages m ON m.id = r.message JOIN threads t "
					"ON t.id = m.thread WHERE r.state = 'open' ORDER BY r.id");
			while(r.step()){
				json::Value v = json::object();
				v.set("id", r.i(0));
				v.set("kind", r.s(1));
				v.set("message", r.i(2));
				v.set("by", r.s(3));
				v.set("reason", r.s(4));
				v.set("time", r.i(5));
				v.set("author", r.s(6));
				v.set("body", r.s(7));
				v.set("thread", r.i(8));
				v.set("title", r.s(9));
				v.set("hidden_reason", r.s(10));
				list.append(v);
			}
			return list;
		}
		if(cmd == "moderate"){
			// hide (a report), restore (an appeal), dismiss (either). Hiding
			// and refusing an appeal say why: the author is told it.
			if(!admin)
				throw Exception("only the admin moderates");
			const ss_ action = jstr(q, "action"), statement = jstr(q, "statement");
			Q r(m_db, "SELECT r.kind, r.message, m.author, m.thread FROM reports r "
					"JOIN messages m ON m.id = r.message WHERE r.id = ? AND "
					"r.state = 'open'");
			r.b(jint(q, "report"));
			if(!r.step())
				throw Exception("no such open report");
			const bool appeal = r.s(0) == "appeal";
			const int64_t message_id = r.i(1), thread_id = r.i(3);
			const ss_ author = r.s(2);
			if(action != "dismiss" && action != (appeal ? "restore" : "hide"))
				throw Exception(appeal ? "an appeal is restored or dismissed" :
						"a report is hidden or dismissed");
			if(action == "hide" || (appeal && action == "dismiss"))
				need(text_ok(statement, 1000, true, "the statement"));
			else if(!statement.empty())
				need(text_ok(statement, 1000, true, "the statement"));
			if(action == "hide"){
				set_hidden(message_id, true, statement);
				notify(author, "hidden", thread_id, message_id, name, statement);
			}else if(action == "restore"){
				set_hidden(message_id, false, "");
				notify(author, "restored", thread_id, message_id, name, statement);
			}else if(appeal){
				notify(author, "appeal_dismissed", thread_id, message_id, name,
						statement);
			}
			// A hide settles the other reports of the message too
			Q u(m_db, action == "dismiss" ?
					"UPDATE reports SET state = ?, handled_by = ?, handled_time = ?, "
					"statement = ? WHERE id = ?" :
					"UPDATE reports SET state = ?, handled_by = ?, handled_time = ?, "
					"statement = ? WHERE state = 'open' AND kind = (SELECT kind "
					"FROM reports WHERE id = ?5) AND message = (SELECT message "
					"FROM reports WHERE id = ?5)");
			u.b(ss_(action == "dismiss" ? "dismissed" : "upheld")).b(name)
					.b(now_s()).b(statement).b(jint(q, "report")).step();
			return json::Value(true);
		}
		throw Exception("no such command: "+cmd);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
// vim: set noet ts=4 sw=4:
