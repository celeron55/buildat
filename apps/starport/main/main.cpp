// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// **Starport** ([STARPORT], doc/plan/starport_plan.md): a directory of public
// servers of buildat apps, as an app. Servers announce to it
// (builtin/starport_announce); clients list from it and report listings
// (extensions/starport); moderators, operators and the admin use it by
// joining it (client_lua/init.lua).
//
// The HTTP API, under /api/ on the server's port (network:http_request),
// JSON in and out, a refusal an {"ok": false, "error": ...} with status 200:
//   POST /api/announce       a server's announce ([STARPORT] 2)
//   GET|POST /api/list       the listings this instance serves ([STARPORT] 4)
//   POST /api/report         a report ([STARPORT] 5)
//   POST /api/report_status  a reporter's receipts' outcomes
//   GET /api/transparency    the numbers ([STARPORT] 6)
// In the app, "sp:req" carries a JSON {id, cmd, ...} from a joined client
// and "sp:res" the answer {id, ok, result | error}.
//
// Everything is in the save "starport", a store a kind of record, each
// record JSON: listings, keys, reports, groups, audit, operators, appeals,
// settings, bans.
#include "core/log.h"
#include "core/json.h"
#include "core/version.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/http.h"
#include "interface/sha256.h"
#include "interface/bignum.h"
#include "client_file/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "accounts/api.h"
#include <algorithm>
#include <cmath>
#include <ctime>
#include <deque>
#include <mutex>
#include <thread>
#include <set>
#include <condition_variable>
#define MODULE "main"

using interface::Event;

namespace starport {

// ---------------------------------------------------------------------------
// Helpers

static int64_t now_s(){ return (int64_t)time(nullptr); }
static int64_t day_of(int64_t t){ return t / 86400; }

static ss_ hex(const ss_ &raw){ return interface::sha256::hex(raw); }
static ss_ unhex(const ss_ &h)
{
	ss_ out;
	for(size_t i = 0; i + 1 < h.size(); i += 2)
		out += (char)strtol(h.substr(i, 2).c_str(), nullptr, 16);
	return out;
}
static ss_ random_hex(size_t bytes){
	return hex(interface::bignum::random_bytes(bytes));
}
// The same, without telling how much of it was
static bool same(const ss_ &a, const ss_ &b)
{
	if(a.size() != b.size())
		return false;
	unsigned char d = 0;
	for(size_t i = 0; i < a.size(); i++)
		d |= (unsigned char)(a[i] ^ b[i]);
	return d == 0;
}
static bool is_hex(const ss_ &s, size_t len)
{
	return s.size() == len &&
			s.find_first_not_of("0123456789abcdef") == ss_::npos;
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
		if(eq != ss_::npos && part.substr(0, eq) == key){
			ss_ v, raw = part.substr(eq + 1);
			for(size_t i = 0; i < raw.size(); i++){
				if(raw[i] == '+')
					v += ' ';
				else if(raw[i] == '%' && i + 2 < raw.size()){
					v += (char)strtol(raw.substr(i + 1, 2).c_str(), nullptr, 16);
					i += 2;
				} else
					v += raw[i];
			}
			return v;
		}
		at = amp + 1;
	}
	return "";
}

// One address counts once: an IPv4 address's /24, an IPv6 one's /48 (the
// first three groups)
static ss_ subnet_of(const ss_ &addr)
{
	if(addr.find(':') != ss_::npos){
		size_t at = 0;
		for(int i = 0; i < 3 && at != ss_::npos; i++){
			at = addr.find(':', at);
			if(at != ss_::npos)
				at++;
		}
		return at == ss_::npos ? addr : addr.substr(0, at);
	}
	const size_t dot = addr.rfind('.');
	return dot == ss_::npos ? addr : addr.substr(0, dot);
}

static const json::Value& jget(const json::Value &v, const char *k)
{
	return v.get(k);
}
static ss_ jstr(const json::Value &v, const char *k, const ss_ &def = "")
{
	const json::Value &x = v.get(k);
	return x.is_string() ? x.as_string() : def;
}
static int64_t jint(const json::Value &v, const char *k, int64_t def = 0)
{
	const json::Value &x = v.get(k);
	return x.is_integer() ? x.as_integer() : x.is_real() ? (int64_t)x.as_real() :
			def;
}
static double jnum(const json::Value &v, const char *k, double def = 0)
{
	const json::Value &x = v.get(k);
	return x.is_number() ? x.as_number() : def;
}
static bool in_set(const ss_ &s, std::initializer_list<const char*> set)
{
	for(const char *x : set)
		if(s == x)
			return true;
	return false;
}

// ---------------------------------------------------------------------------
// The categories ([STARPORT] 3)

static const std::initializer_list<const char*> KINDS =
		{"world", "arena", "app", "other"};
static const std::initializer_list<const char*> AUDIENCES =
		{"everyone", "teen", "adult"};
static const std::initializer_list<const char*> ACCESSES =
		{"open", "registration", "invite", "password", "external"};
static const std::initializer_list<const char*> REASONS = {"category",
		"illegal", "csam", "harassment", "scam", "malware", "impersonation",
		"spam", "other"};
// Each descriptor and the values it takes; a bool one is "yes"/"no"
static const sm_<ss_, sv_<ss_>> DESCRIPTORS = {
	{"violence", {"none", "cartoon", "realistic"}},
	{"chat", {"none", "moderated", "unmoderated"}},
	{"ugc", {"none", "moderated", "unmoderated"}},
	{"language", {"no", "yes"}},
	{"sexual", {"no", "yes"}},
	{"drugs", {"no", "yes"}},
	{"purchases", {"no", "yes"}},
	{"gambling", {"no", "yes"}},
	{"personal_data", {"no", "yes"}},
};
// How much a reason weighs in the queue's order
static int severity(const ss_ &reason)
{
	static const sm_<ss_, int> s = {{"csam", 100}, {"malware", 60},
		{"illegal", 50}, {"scam", 40}, {"harassment", 30},
		{"impersonation", 25}, {"category", 20}, {"spam", 15}, {"other", 10}};
	auto it = s.find(reason);
	return it == s.end() ? 10 : it->second;
}

// "" when the announce's categories are whole and right, else why not
static ss_ check_categories(const json::Value &b)
{
	const ss_ name = jstr(b, "name");
	if(name.empty() || name.size() > 60)
		return "name: 1 to 60 characters";
	if(jstr(b, "description").size() > 500)
		return "description: at most 500 characters";
	if(!in_set(jstr(b, "kind"), KINDS))
		return "kind: world, arena, app or other";
	if(!in_set(jstr(b, "audience"), AUDIENCES))
		return "audience: everyone, teen or adult";
	if(!in_set(jstr(b, "access"), ACCESSES))
		return "access: open, registration, invite, password or external";
	// How people log in: its own accounts, Starport IDs, or both (10c)
	const ss_ login = jstr(b, "login", "local");
	if(!in_set(login, {"local", "starport", "both"}))
		return "login: local, starport or both";
	// An account made somewhere else first: where ([STARPORT] 3)
	const ss_ signup = jstr(b, "signup_url");
	if(jstr(b, "access") == "external" && (signup.size() > 200 ||
			(signup.compare(0, 8, "https://") != 0 &&
			signup.compare(0, 7, "http://") != 0) ||
			signup.find_first_of(" \"<>\r\n") != ss_::npos))
		return "signup_url: the http(s) address an account is made at, "
				"for access external";
	const json::Value &d = b.get("descriptors");
	if(!d.is_object())
		return "descriptors: an object";
	for(const auto &pair : DESCRIPTORS){
		const ss_ v = jstr(d, pair.first.c_str());
		// One a server's version does not know yet is "unknown" ([STARPORT]
		// 3: categories are versioned)
		if(d.get(pair.first).is_undefined())
			continue;
		if(std::find(pair.second.begin(), pair.second.end(), v) ==
				pair.second.end())
			return "descriptors."+pair.first+": one of "+dump(pair.second);
	}
	const json::Value &tags = b.get("tags");
	if(!tags.is_undefined()){
		if(!tags.is_array() || tags.size() > 8)
			return "tags: at most 8";
		for(unsigned i = 0; i < tags.size(); i++){
			const json::Value &t = tags.at(i);
			if(!t.is_string() || t.as_string().empty() ||
					t.as_string().size() > 24 || t.as_string().find_first_not_of(
					"abcdefghijklmnopqrstuvwxyz0123456789_-") != ss_::npos)
				return "tags: a-z, 0-9, _ and -, at most 24 characters";
		}
	}
	const json::Value &langs = b.get("languages");
	if(!langs.is_undefined()){
		if(!langs.is_array() || langs.size() > 8)
			return "languages: at most 8";
		for(unsigned i = 0; i < langs.size(); i++)
			if(!langs.at(i).is_string() || langs.at(i).as_string().size() > 8)
				return "languages: codes such as \"en\" or \"fi\"";
	}
	if(jstr(b, "region").size() > 32)
		return "region: at most 32 characters";
	const ss_ addr = jstr(b, "address");
	if(addr.size() > 253 || addr.find_first_of(" /?#@\\") != ss_::npos)
		return "address: a host name or an address";
	return "";
}

// ---------------------------------------------------------------------------
// The instance's settings, with their defaults ([STARPORT] 5a, 7, 8)

static json::Value default_settings()
{
	json::Value s = json::object();
	s.set("name", "Starport");
	// What this instance serves, whatever a client asks ([STARPORT] 4)
	json::Value filter = json::object();
	filter.set("exclude_audience", json::array());
	filter.set("exclude_kind", json::array());
	filter.set("exclude_descriptors", json::array());
	s.set("filter", filter);
	// A key's standing ([STARPORT] 5a)
	s.set("lambda", 0.937);
	s.set("f_full", 0.139);
	s.set("b", 0.3);
	s.set("tau_days", 14.2);
	s.set("w_min", 0.01);
	// Reports' thresholds, per reason ([STARPORT] 7)
	json::Value th = json::object();
	json::Value d = json::object();
	d.set("hide", 3.0);
	d.set("delist", 8.0);
	th.set("default", d);
	for(const char *r : {"csam", "malware"}){
		json::Value x = json::object();
		x.set("hide", 1.0);
		x.set("delist", 2.0);
		th.set(r, x);
	}
	s.set("thresholds", th);
	// How long an address is kept ([STARPORT] 8)
	s.set("retention_days", (int64_t)7);
	// Who moderates, and whose reports go first ([STARPORT] 6)
	// Whether an operator's e-mail address is confirmed by a code mailed
	// to it ([STARPORT] 2a); off for a test instance, the address then
	// taken as given
	s.set("email_confirmation", true);
	// Whether players can make Starport IDs here (10)
	s.set("id_registration", true);
	// How the codes go: url smtp://host:587 or smtps://host:465
	json::Value smtp = json::object();
	for(const char *k : {"url", "from", "user", "password"})
		smtp.set(k, "");
	s.set("smtp", smtp);
	s.set("moderators", json::array());
	s.set("trusted_flaggers", json::array());
	return s;
}

// A listing's categories as served: the announce's, with what a moderator
// set over it
static json::Value effective(const json::Value &l)
{
	json::Value out = json::object();
	for(const char *k : {"kind", "audience", "access"})
		out.set(k, l.get(k));
	out.set("descriptors", l.get("descriptors").deepcopy());
	const json::Value &r = l.get("relabel");
	if(r.is_object()){
		for(json::Iterator it(r); it.valid(); it.next()){
			const ss_ k = it.key();
			if(k == "kind" || k == "audience" || k == "access")
				out.set(k, it.value());
			else if(DESCRIPTORS.count(k)){
				json::Value d = out.get("descriptors").deepcopy();
				d.set(k, it.value());
				out.set("descriptors", d);
			}
		}
	}
	return out;
}

// ---------------------------------------------------------------------------

struct VerifyJob {
	ss_ listing;
	ss_ url;      // http://host:port/api/starport/challenge?...
	ss_ expect;   // the hex HMAC
};
struct VerifyResult {
	ss_ listing;
	bool ok = false;
	ss_ why;
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	storage::Save *m_save = nullptr;
	json::Value m_settings;
	int64_t m_last_day = 0;
	int64_t m_next_reverify = 0;
	// Rate limits, in memory only: by key, a count and when it started
	sm_<ss_, std::pair<int, int64_t>> m_rates;

	// The verifier: a thread of its own, as it waits on other servers
	std::mutex m_vmutex;
	std::condition_variable m_vwake;
	std::deque<VerifyJob> m_vjobs;
	std::deque<VerifyResult> m_vresults;
	std::thread m_vthread;
	bool m_vstop = false;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{
		{
			std::lock_guard<std::mutex> lock(m_vmutex);
			m_vstop = true;
		}
		m_vwake.notify_all();
		if(m_vthread.joinable())
			m_vthread.join();
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("network:packet_received/sp:req"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:http_request", on_http, network::HttpRequest)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/sp:req", on_req, network::Packet)
	}

	// -----------------------------------------------------------------------
	// Storage

	storage::Store* store(const char *name){ return m_save->store(name); }

	json::Value load(const char *store_name, const ss_ &key)
	{
		ss_ text;
		if(!store(store_name)->get(key, text))
			return json::Value();
		return json::load_string(text.c_str());
	}
	void put(const char *store_name, const ss_ &key, const json::Value &v)
	{
		store(store_name)->set(key, v.stringify());
	}

	const json::Value& setting(const char *k)
	{
		const json::Value &v = m_settings.get(k);
		if(!v.is_undefined())
			return v;
		static json::Value defaults = default_settings();
		return defaults.get(k);
	}
	double setting_num(const char *k){ return setting(k).as_number(); }

	void on_start()
	{
		storage::access(m_server, [&](storage::Interface *s){
			m_save = s->open("starport");
			if(!m_save)
				m_save = s->create("starport");
		});
		if(!m_save)
			throw Exception("starport: cannot open or create the save");
		m_settings = load("settings", "settings");
		if(!m_settings.is_object()){
			m_settings = default_settings();
			put("settings", "settings", m_settings);
		}
		m_last_day = day_of(now_s());
		m_vthread = std::thread([this](){ verifier(); });
		log_i(MODULE, "Starport \"%s\": %zu listings", cs(jstr(m_settings,
				"name")), store("listings")->list("").size());
	}

	// -----------------------------------------------------------------------
	// Rate limits

	// Whether one more of `what` from `who` fits in `per` seconds
	bool rate_ok(const ss_ &what, const ss_ &who, int max, int64_t per)
	{
		auto &r = m_rates[what+"|"+who];
		const int64_t t = now_s();
		if(t - r.second >= per)
			r = std::make_pair(0, t);
		if(r.first >= max)
			return false;
		r.first++;
		return true;
	}

	// -----------------------------------------------------------------------
	// The HTTP API

	void respond(const network::HttpRequest &r, int status, const json::Value &v)
	{
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, status, "application/json",
					v.stringify());
		});
	}
	void refuse(const network::HttpRequest &r, const ss_ &why)
	{
		json::Value v = json::object();
		v.set("ok", false);
		v.set("error", why);
		respond(r, 200, v);
	}

	void on_http(const network::HttpRequest &r)
	{
		if(!m_save)
			return;
		json::Value body;
		if(r.method == "POST"){
			json::json_error_t err;
			body = json::load_string(r.body.c_str(), &err);
			if(!body.is_object()){
				refuse(r, "the body is not a JSON object");
				return;
			}
		} else {
			body = json::object();
		}
		if(r.path == "/api/announce" && r.method == "POST")
			api_announce(r, body);
		else if(r.path == "/api/list")
			api_list(r, body);
		else if(r.path == "/api/report" && r.method == "POST")
			api_report(r, body);
		else if(r.path == "/api/report_status" && r.method == "POST")
			api_report_status(r, body);
		else if(r.path.compare(0, 8, "/api/id/") == 0 && r.method == "POST")
			api_id(r, body);
		else if(r.path == "/api/transparency")
			api_transparency(r);
		else if(r.path.compare(0, 14, "/api/starport/") == 0)
			return; // builtin/starport_announce's, were this listed itself
		else {
			json::Value v = json::object();
			v.set("ok", false);
			v.set("error", "no such call");
			respond(r, 404, v);
		}
	}

	bool banned(const ss_ &kind, const ss_ &what)
	{
		if(what.empty())
			return false;
		json::Value b = load("bans", kind+":"+what);
		if(!b.is_object())
			return false;
		const int64_t until = jint(b, "until");
		return until == 0 || until > now_s();
	}

	// -- 2. Announce

	void api_announce(const network::HttpRequest &r, const json::Value &b)
	{
		if(banned("address", r.address)){
			refuse(r, "this address may not announce");
			return;
		}
		const ss_ why = check_categories(b);
		if(!why.empty()){
			refuse(r, why);
			return;
		}
		const int64_t port = jint(b, "port");
		if(port < 1 || port > 65535){
			refuse(r, "port: 1 to 65535");
			return;
		}
		const ss_ id = jstr(b, "id");
		json::Value l;
		json::Value answer = json::object();
		const int64_t t = now_s();
		if(!id.empty()){
			if(!rate_ok("announce", id, 1, 20)){
				refuse(r, "announced too often");
				return;
			}
			l = load("listings", id);
			if(!l.is_object() || !same(jstr(l, "secret"), jstr(b, "secret"))){
				refuse(r, "no such listing, or not its secret");
				return;
			}
		} else {
			if(!rate_ok("new_listing", r.address, 5, 86400)){
				refuse(r, "too many new listings from this address today");
				return;
			}
			l = json::object();
			l.set("id", random_hex(8));
			l.set("secret", random_hex(32));
			l.set("first_seen", t);
			l.set("status", "active");
			l.set("owner", "");
			l.set("strikes", json::array());
			answer.set("secret", jstr(l, "secret"));
		}
		if(banned("listing", jstr(l, "id")) ||
				banned("account", jstr(l, "owner"))){
			refuse(r, "this listing may not announce");
			return;
		}
		// The address it is reached at: what it named, or where the announce
		// came from
		ss_ host = jstr(b, "address");
		if(host.empty())
			host = r.address;
		const bool moved = jstr(l, "host") != host || jint(l, "port") != port;
		for(const char *k : {"name", "description", "kind", "audience",
				"access", "region", "app", "version", "signup_url"})
			l.set(k, b.get(k).is_string() ? b.get(k) : json::Value(""));
		l.set("login", jstr(b, "login", "local"));
		json::Value desc = b.get("descriptors").deepcopy();
		for(const auto &pair : DESCRIPTORS)
			if(desc.get(pair.first).is_undefined())
				desc.set(pair.first, "unknown");
		l.set("descriptors", desc);
		l.set("tags", b.get("tags").is_array() ? b.get("tags") : json::array());
		l.set("languages", b.get("languages").is_array() ? b.get("languages") :
				json::array());
		l.set("players", jint(b, "players"));
		l.set("players_max", jint(b, "players_max"));
		l.set("host", host);
		l.set("port", port);
		l.set("last_announce", t);
		// A failed check is tried again at the next announce: a restart,
		// a moment's network trouble
		if(moved || jstr(l, "verify") != "ok"){
			l.set("verify", "pending");
			queue_verify(l);
		}
		join_fleet(l, jstr(b, "fleet"), jstr(b, "pool"));
		put("listings", jstr(l, "id"), l);
		consistency_check(l);
		pool_check(l);
		take_bans(l, b.get("bans"));
		answer.set("blocked", blocked_for(l));
		answer.set("ok", true);
		answer.set("id", jstr(l, "id"));
		answer.set("status", served_status(l));
		respond(r, 200, answer);
	}

	// -- 2b. Fleets and pools

	// "<id>:<code>" from the announce: the right code puts the listing in
	// the fleet and claims it for the fleet's owner; none takes it out;
	// a wrong one leaves it out and a moderator looks
	void join_fleet(json::Value &l, const ss_ &line, ss_ pool)
	{
		const size_t colon = line.find(':');
		const ss_ fid = colon == ss_::npos ? line : line.substr(0, colon);
		const ss_ code = colon == ss_::npos ? "" : line.substr(colon + 1);
		if(pool.size() > 32)
			pool = pool.substr(0, 32);
		if(fid.empty()){
			l.set("fleet", "");
			l.set("pool", "");
			return;
		}
		const json::Value f = load("fleets", fid);
		if(jstr(l, "fleet_removed") == fid)
			return; // its operator took it out; the config still says it
		if(f.is_object() && same(jstr(f, "code"), code) &&
				!banned("account", jstr(f, "owner"))){
			if(jstr(l, "fleet") != fid)
				audit("", jstr(l, "id"), "fleet", "", "joined fleet "+fid,
						true);
			l.set("fleet", fid);
			l.set("pool", pool);
			l.set("owner", jstr(f, "owner"));
			return;
		}
		// One the fleet's new code turned away just leaves; one that never
		// was in it is looked at, once
		if(jstr(l, "fleet") != fid && jstr(l, "fleet_flagged") != fid){
			l.set("fleet_flagged", fid);
			const ss_ gid = jstr(l, "id")+"|impersonation";
			json::Value g = load("groups", gid);
			if(!g.is_object() || jstr(g, "state") != "open")
				open_group(gid, jstr(l, "id"), "impersonation",
						"Starport: announced with a wrong code for fleet "+fid);
		}
		l.set("fleet", "");
		l.set("pool", "");
	}

	// A pool's servers are one entry, so they have to be the same thing:
	// one that differs from the others is shown on its own and looked at
	void pool_check(json::Value l)
	{
		if(jstr(l, "pool").empty())
			return;
		const json::Value mine = effective(l);
		for(const ss_ &id : store("listings")->list("")){
			if(id == jstr(l, "id"))
				continue;
			const json::Value o = load("listings", id);
			if(jstr(o, "fleet") != jstr(l, "fleet") ||
					jstr(o, "pool") != jstr(l, "pool") ||
					o.get("pool_mismatch").is_true())
				continue;
			const json::Value e = effective(o);
			const bool differs = jstr(o, "app") != jstr(l, "app") ||
					e.stringify() != mine.stringify();
			if(differs != l.get("pool_mismatch").is_true()){
				l.set("pool_mismatch", differs);
				put("listings", jstr(l, "id"), l);
				if(differs)
					open_group(jstr(l, "id")+"|category", jstr(l, "id"),
							"category", "Starport: not the app or the "
							"categories of the rest of pool "+jstr(l, "pool"));
			}
			return;
		}
	}

	// The listings a group is about: its listing's, or its fleet's
	sv_<ss_> members_of(const json::Value &g)
	{
		const ss_ fid = jstr(g, "fleet");
		if(fid.empty())
			return {jstr(g, "listing")};
		sv_<ss_> out;
		for(const ss_ &id : store("listings")->list(""))
			if(jstr(load("listings", id), "fleet") == fid)
				out.push_back(id);
		return out;
	}

	// What it says that a listing whose audience is everyone has
	// unmoderated chat or content: a moderator looks ([STARPORT] 3)
	void consistency_check(const json::Value &l)
	{
		const json::Value e = effective(l);
		if(jstr(e, "audience") != "everyone")
			return;
		const json::Value &d = e.get("descriptors");
		if(jstr(d, "chat") != "unmoderated" && jstr(d, "ugc") != "unmoderated")
			return;
		const ss_ gid = jstr(l, "id")+"|category";
		json::Value g = load("groups", gid);
		if(g.is_object() && jstr(g, "state") == "open")
			return;
		if(g.is_object() && jstr(g, "decided") == "dismiss")
			return; // a moderator has looked already
		open_group(gid, jstr(l, "id"), "category",
				"Starport: an audience of everyone with unmoderated chat or "
				"content");
	}

	// "listed", or why it is not served
	ss_ served_status(const json::Value &l)
	{
		const ss_ st = jstr(l, "status");
		if(st == "delisted" || st == "banned")
			return st;
		if(jstr(l, "verify") != "ok")
			return jstr(l, "verify") == "failed" ?
					"unverified: the challenge to its address failed" :
					"unverified: being checked";
		if(jstr(l, "owner").empty())
			return "unclaimed: an operator account claims it with the claim "
					"code (starport_claim.txt)";
		const ss_ f = filtered_out(l);
		if(!f.empty())
			return "filtered out by this instance: "+f;
		if(now_s() - jint(l, "last_announce") > 900)
			return "offline";
		return st == "hidden" ? "hidden from filtered views" : "listed";
	}

	// Why the instance's own filter leaves it out, or ""
	ss_ filtered_out(const json::Value &l)
	{
		const json::Value e = effective(l);
		const json::Value &f = setting("filter");
		auto has = [](const json::Value &arr, const ss_ &v){
			if(!arr.is_array())
				return false;
			for(unsigned i = 0; i < arr.size(); i++)
				if(arr.at(i).is_string() && arr.at(i).as_string() == v)
					return true;
			return false;
		};
		if(has(f.get("exclude_audience"), jstr(e, "audience")))
			return "audience "+jstr(e, "audience");
		if(has(f.get("exclude_kind"), jstr(e, "kind")))
			return "kind "+jstr(e, "kind");
		const json::Value &ex = f.get("exclude_descriptors");
		if(ex.is_array()){
			for(unsigned i = 0; i < ex.size(); i++){
				const ss_ d = ex.at(i).is_string() ? ex.at(i).as_string() : "";
				const ss_ v = jstr(e.get("descriptors"), d.c_str());
				// Unknown is left out with what it might be
				if(v == "yes" || v == "unmoderated" || v == "realistic" ||
						v == "unknown")
					return "descriptor "+d;
			}
		}
		return "";
	}

	// -- The verifier

	void queue_verify(const json::Value &l)
	{
		const ss_ nonce = random_hex(16);
		ss_ host = jstr(l, "host");
		if(host.find(':') != ss_::npos)
			host = "["+host+"]";
		VerifyJob j;
		j.listing = jstr(l, "id");
		j.url = "http://"+host+":"+itos(jint(l, "port"))+
				"/api/starport/challenge?listing="+j.listing+"&nonce="+nonce;
		j.expect = hex(interface::sha256::hmac(unhex(jstr(l, "secret")), nonce));
		{
			std::lock_guard<std::mutex> lock(m_vmutex);
			m_vjobs.push_back(j);
		}
		m_vwake.notify_all();
	}

	void verifier()
	{
		for(;;){
			VerifyJob j;
			{
				std::unique_lock<std::mutex> lock(m_vmutex);
				m_vwake.wait(lock, [this](){
					return m_vstop || !m_vjobs.empty();
				});
				if(m_vstop)
					return;
				j = m_vjobs.front();
				m_vjobs.pop_front();
			}
			VerifyResult res;
			res.listing = j.listing;
			try {
				const ss_ text = interface::http_get(j.url);
				const json::Value v = json::load_string(text.c_str());
				res.ok = v.is_object() && same(jstr(v, "response"), j.expect);
				if(!res.ok)
					res.why = "a wrong answer";
			} catch(std::exception &e){
				res.why = e.what();
			}
			std::lock_guard<std::mutex> lock(m_vmutex);
			m_vresults.push_back(res);
		}
	}

	void apply_verify_results()
	{
		std::deque<VerifyResult> results;
		{
			std::lock_guard<std::mutex> lock(m_vmutex);
			results.swap(m_vresults);
		}
		for(const VerifyResult &res : results){
			json::Value l = load("listings", res.listing);
			if(!l.is_object())
				continue;
			l.set("verify", res.ok ? "ok" : "failed");
			l.set("verified_at", now_s());
			put("listings", res.listing, l);
			log_i(MODULE, "Listing %s (%s): verified %s%s", cs(res.listing),
					cs(jstr(l, "name")), res.ok ? "ok" : "not",
					res.ok ? "" : cs(": "+res.why));
		}
	}

	// -- 4. List

	void api_list(const network::HttpRequest &r, const json::Value &b)
	{
		if(!rate_ok("list", r.address, 60, 60)){
			refuse(r, "listed too often");
			return;
		}
		const ss_ key = jstr(b, "key");
		if(!key.empty())
			key_seen(key);
		json::Value servers = json::array();
		for(const ss_ &id : store("listings")->list("")){
			const json::Value l = load("listings", id);
			if(!l.is_object())
				continue;
			const ss_ st = served_status(l);
			if(st != "listed" && st != "hidden from filtered views")
				continue;
			json::Value s = json::object();
			for(const char *k : {"id", "name", "description", "host", "port",
					"app", "version", "tags", "languages", "region", "signup_url",
					"login",
					"players", "players_max"})
				s.set(k, l.get(k));
			const json::Value e = effective(l);
			for(const char *k : {"kind", "audience", "access", "descriptors"})
				s.set(k, e.get(k));
			s.set("restricted", st != "listed");
			const ss_ fid = jstr(l, "fleet");
			if(!fid.empty()){
				const json::Value f = load("fleets", fid);
				json::Value fs = json::object();
				for(const char *k : {"id", "name", "description", "link"})
					fs.set(k, jstr(f, k));
				s.set("fleet", fs);
				if(!l.get("pool_mismatch").is_true())
					s.set("pool", jstr(l, "pool"));
			}
			servers.append(s);
		}
		json::Value v = json::object();
		v.set("ok", true);
		v.set("starport", jstr(m_settings, "name"));
		v.set("servers", servers);
		respond(r, 200, v);
	}

	// -- 5a. A key's standing

	// The record of a client's key, by the hash of its secret
	void key_seen(const ss_ &secret_hex)
	{
		if(!is_hex(secret_hex, 64))
			return;
		const ss_ h = hex(interface::sha256::calculate(unhex(secret_hex)));
		const int64_t d = day_of(now_s());
		json::Value k = load("keys", h);
		if(!k.is_object()){
			k = json::object();
			k.set("first_day", d);
			k.set("f", 1.0);
			k.set("last_day", d);
			k.set("upheld", (int64_t)0);
			k.set("rejected", (int64_t)0);
			put("keys", h, k);
			return;
		}
		const int64_t last = jint(k, "last_day");
		if(last >= d)
			return;
		// The filter run to today: the days between were 0, today is 1
		const double lambda = setting_num("lambda");
		k.set("f", jnum(k, "f") * pow(lambda, (double)(d - last)) + 1.0);
		k.set("last_day", d);
		put("keys", h, k);
	}

	// What a report by this key weighs ([STARPORT] 5a): its age and its
	// freshness, then its reports' record
	double key_weight(const ss_ &h)
	{
		const double w_min = setting_num("w_min");
		json::Value k = h.empty() ? json::Value() : load("keys", h);
		if(!k.is_object())
			return w_min;
		const int64_t d = day_of(now_s());
		const double lambda = setting_num("lambda");
		const double f = jnum(k, "f") * pow(lambda, (double)(d -
				jint(k, "last_day")));
		const double F = f * (1.0 - lambda);
		const double age = (double)(d - jint(k, "first_day"));
		double w = (1.0 - exp(-age / setting_num("tau_days"))) *
				pow(std::min(1.0, F / setting_num("f_full")), setting_num("b"));
		// A record of reports a moderator upheld adds to it; one of
		// rejected ones takes from it
		const int64_t up = jint(k, "upheld"), rej = jint(k, "rejected");
		w *= (1.0 + 0.1 * std::min<int64_t>(up, 10)) / (1.0 + 0.5 * rej);
		return std::max(w_min, w);
	}

	bool key_muted(const ss_ &h)
	{
		json::Value k = h.empty() ? json::Value() : load("keys", h);
		if(!k.is_object())
			return false;
		return jint(k, "muted_until") > now_s();
	}

	bool trusted(const ss_ &h)
	{
		const json::Value &t = setting("trusted_flaggers");
		for(unsigned i = 0; t.is_array() && i < t.size(); i++)
			if(t.at(i).is_string() && t.at(i).as_string() == h)
				return true;
		return false;
	}

	// -- 5. Report

	void api_report(const network::HttpRequest &r, const json::Value &b)
	{
		if(!rate_ok("report_addr", r.address, 10, 3600)){
			refuse(r, "too many reports from this address; try later");
			return;
		}
		const ss_ listing = jstr(b, "listing");
		json::Value l = load("listings", listing);
		if(!l.is_object()){
			refuse(r, "no such listing");
			return;
		}
		const ss_ reason = jstr(b, "reason");
		if(!in_set(reason, REASONS)){
			refuse(r, "reason: one of category, illegal, csam, harassment, "
					"scam, malware, impersonation, spam, other");
			return;
		}
		const ss_ text = jstr(b, "text");
		if(text.size() > 2000){
			refuse(r, "text: at most 2000 characters");
			return;
		}
		const ss_ evidence = jstr(b, "evidence");
		if(evidence.size() > 48 * 1024){
			refuse(r, "evidence: at most 48 KiB");
			return;
		}
		ss_ h;
		const ss_ key = jstr(b, "key");
		if(!key.empty()){
			if(!is_hex(key, 64)){
				refuse(r, "key: 64 hex digits");
				return;
			}
			key_seen(key);
			h = hex(interface::sha256::calculate(unhex(key)));
			if(!rate_ok("report_key", h, 5, 3600)){
				refuse(r, "too many reports from this key; try later");
				return;
			}
		}
		json::Value rep = json::object();
		const ss_ id = random_hex(8);
		rep.set("id", id);
		rep.set("listing", listing);
		rep.set("reason", reason);
		rep.set("text", text);
		if(!evidence.empty())
			rep.set("evidence", evidence);
		if(b.get("suggest").is_object())
			rep.set("suggest", b.get("suggest"));
		rep.set("key", h);
		rep.set("address", r.address);
		rep.set("ts", now_s());
		rep.set("trusted", trusted(h));
		rep.set("weight", trusted(h) ? 1.0 : key_weight(h));
		// The spam filter ([STARPORT] 7): held back, not counted
		const ss_ held = spam_reason(rep);
		rep.set("state", held.empty() ? "open" : "held");
		if(!held.empty())
			rep.set("held", held);
		// Of the whole fleet the listing is in, where the reporter said so
		const ss_ fleet = b.get("whole_fleet").is_true() ? jstr(l, "fleet") :
				ss_();
		const ss_ gid = (fleet.empty() ? listing : "fleet:"+fleet)+"|"+reason;
		rep.set("group", gid);
		if(!fleet.empty())
			rep.set("fleet", fleet);
		put("reports", id, rep);
		if(held.empty())
			add_to_group(gid, listing, reason, id, fleet);
		json::Value v = json::object();
		v.set("ok", true);
		v.set("receipt", id);
		respond(r, 200, v);
	}

	// Why a report is held back, or ""
	ss_ spam_reason(const json::Value &rep)
	{
		const ss_ h = jstr(rep, "key");
		if(key_muted(h))
			return "a key whose reports were mostly rejected";
		const ss_ text = jstr(rep, "text");
		if(text.size() >= 20){
			// The same words as several others today
			int same_text = 0;
			const int64_t t = now_s();
			for(const ss_ &id : store("reports")->list("")){
				const json::Value o = load("reports", id);
				if(t - jint(o, "ts") < 86400 && jstr(o, "text") == text)
					same_text++;
			}
			if(same_text >= 3)
				return "the same text as other reports today";
		}
		return "";
	}

	// -- 7. Groups

	json::Value open_group(const ss_ &gid, const ss_ &listing,
			const ss_ &reason, const ss_ &note, const ss_ &fleet = "")
	{
		json::Value g = json::object();
		g.set("id", gid);
		g.set("listing", listing);
		g.set("fleet", fleet);
		g.set("reason", reason);
		g.set("reports", json::array());
		g.set("state", "open");
		g.set("opened", now_s());
		g.set("note", note);
		g.set("weight", 0.0);
		g.set("auto", "");
		put("groups", gid, g);
		return g;
	}

	void add_to_group(const ss_ &gid, const ss_ &listing, const ss_ &reason,
			const ss_ &report_id, const ss_ &fleet)
	{
		json::Value g = load("groups", gid);
		if(!g.is_object() || jstr(g, "state") != "open")
			g = open_group(gid, listing, reason, "", fleet);
		json::Value reps = g.get("reports").deepcopy();
		reps.append(report_id);
		g.set("reports", reps);
		g.set("weight", group_weight(g));
		put("groups", gid, g);
		auto_act(g);
	}

	// What a group weighs ([STARPORT] 7): the reports' weights, one per
	// address range, and all the new keys of a burst together as one
	double group_weight(const json::Value &g)
	{
		sm_<ss_, double> buckets;
		const int64_t d = day_of(now_s());
		const json::Value &reps = g.get("reports");
		for(unsigned i = 0; i < reps.size(); i++){
			const json::Value rep = load("reports", reps.at(i).as_string());
			if(!rep.is_object() || jstr(rep, "state") != "open")
				continue;
			const double w = jnum(rep, "weight");
			ss_ bucket;
			if(rep.get("trusted").is_true())
				bucket = "trusted:"+jstr(rep, "key");
			else {
				const json::Value k = load("keys", jstr(rep, "key"));
				const bool fresh = !k.is_object() ||
						d - jint(k, "first_day") < 2;
				bucket = fresh ? "fresh" : "net:"+subnet_of(jstr(rep,
						"address"));
			}
			buckets[bucket] = std::max(buckets[bucket], w);
		}
		double sum = 0;
		for(auto &pair : buckets)
			sum += pair.second;
		return sum;
	}

	json::Value thresholds(const ss_ &reason)
	{
		const json::Value &th = setting("thresholds");
		const json::Value &t = th.get(reason);
		return t.is_object() ? t : th.get("default");
	}

	// Past a threshold, hidden or delisted until a moderator looks; never
	// for good, never banned ([STARPORT] 7)
	void auto_act(json::Value g)
	{
		// An ID is suspended by a moderator, never by reports alone (10d)
		if(!jstr(g, "id_name").empty())
			return;
		const json::Value t = thresholds(jstr(g, "reason"));
		const double w = jnum(g, "weight");
		ss_ want;
		if(w >= jnum(t, "delist", 1e9))
			want = "delist";
		else if(w >= jnum(t, "hide", 1e9))
			want = "hide";
		if(want.empty() || want == jstr(g, "auto") ||
				(want == "hide" && jstr(g, "auto") == "delist"))
			return;
		g.set("auto", want);
		put("groups", jstr(g, "id"), g);
		for(const ss_ &id : members_of(g))
			auto_act_on(g, load("listings", id), want, w);
	}

	void auto_act_on(const json::Value &g, json::Value l, const ss_ &want,
			double w)
	{
		if(!l.is_object())
			return;
		const ss_ reason = jstr(g, "reason");
		if(reason == "category" && want == "hide"){
			// Relabelled to what most reporters said, where they said it
			sm_<ss_, int> votes;
			const json::Value &reps = g.get("reports");
			for(unsigned i = 0; i < reps.size(); i++){
				const json::Value rep = load("reports", reps.at(i).as_string());
				const ss_ a = jstr(rep.get("suggest"), "audience");
				if(in_set(a, AUDIENCES))
					votes[a]++;
			}
			ss_ best;
			int n = 0;
			for(auto &pair : votes)
				if(pair.second > n)
					best = pair.first, n = pair.second;
			if(!best.empty()){
				json::Value rl = l.get("relabel").is_object() ?
						l.get("relabel").deepcopy() : json::object();
				rl.set("audience", best);
				l.set("relabel", rl);
			}
		}
		const ss_ prev = jstr(l, "status");
		if(want == "delist" || prev != "delisted")
			l.set("status", want == "delist" ? "delisted" : "hidden");
		l.set("status_auto", true);
		put("listings", jstr(l, "id"), l);
		const ss_ text = "Automatic, pending a moderator's review: reports of "
				"\""+reason+"\" weighing "+std::to_string(w).substr(0, 4)+
				" passed this instance's threshold to "+want+".";
		audit("", jstr(l, "id"), want == "delist" ? "delist" : "hide", reason,
				text, true);
		statement(l, want == "delist" ? "delisted" : "hidden", reason, text);
	}

	// -- 6. The audit log and the statements of reasons

	void audit(const ss_ &by, const ss_ &listing, const ss_ &action,
			const ss_ &reason, const ss_ &text, bool automatic)
	{
		json::Value a = json::object();
		const int64_t t = now_s();
		a.set("ts", t);
		a.set("by", by);
		a.set("listing", listing);
		a.set("action", action);
		a.set("reason", reason);
		a.set("text", text);
		a.set("auto", automatic);
		// Sortable by time
		char key[40];
		snprintf(key, sizeof key, "%012lld-%s", (long long)t,
				random_hex(3).c_str());
		put("audit", key, a);
	}

	// To the operator who claimed it: what was done, why, how to appeal
	void statement(const json::Value &l, const ss_ &action, const ss_ &reason,
			const ss_ &text, const ss_ &by = "")
	{
		const ss_ owner = jstr(l, "owner");
		json::Value s = json::object();
		const ss_ id = random_hex(6);
		s.set("id", id);
		s.set("ts", now_s());
		s.set("listing", jstr(l, "id"));
		s.set("listing_name", jstr(l, "name"));
		s.set("action", action);
		s.set("reason", reason);
		s.set("text", text);
		s.set("by", by);
		s.set("owner", owner);
		s.set("appeal", "Appeal from your account on this Starport; another "
				"moderator than the one who acted decides.");
		put("statements", id, s);
		const json::Value o = owner.empty() ? json::Value() :
				load("operators", owner);
		if(!jstr(o, "email").empty() && can_mail()){
			const ss_ sp = jstr(m_settings, "name");
			mail(owner, jstr(o, "email"), sp+": "+action+": "+
					jstr(l, "name"),
					"Your listing \""+jstr(l, "name")+"\" ("+jstr(l, "id")+
					") on "+sp+":\n\n"
					"    "+action+", for "+reason+"\n\n"+text+"\n\n"+
					"Appeal from your account on "+sp+"; another moderator "
					"than the one who acted decides.\n");
		}
		log_i(MODULE, "Statement of reasons to %s: listing %s %s (%s)",
				owner.empty() ? "(unclaimed)" : cs(owner), cs(jstr(l, "id")),
				cs(action), cs(reason));
	}

	// -- 5. The reporter's outcomes

	void api_report_status(const network::HttpRequest &r, const json::Value &b)
	{
		const ss_ key = jstr(b, "key");
		if(!is_hex(key, 64)){
			refuse(r, "key: 64 hex digits");
			return;
		}
		const ss_ h = hex(interface::sha256::calculate(unhex(key)));
		json::Value out = json::array();
		const json::Value &ids = b.get("receipts");
		for(unsigned i = 0; ids.is_array() && i < ids.size() && i < 100; i++){
			if(!ids.at(i).is_string())
				continue;
			const json::Value rep = load("reports", ids.at(i).as_string());
			if(!rep.is_object() || jstr(rep, "key") != h)
				continue;
			json::Value o = json::object();
			o.set("receipt", jstr(rep, "id"));
			o.set("state", jstr(rep, "state"));
			o.set("outcome", jstr(rep, "outcome"));
			out.append(o);
		}
		json::Value v = json::object();
		v.set("ok", true);
		v.set("reports", out);
		respond(r, 200, v);
	}

	// -- 6. Transparency

	void api_transparency(const network::HttpRequest &r)
	{
		json::Value by_reason = json::object(), by_action = json::object();
		sv_<int64_t> times;
		int64_t reports = 0;
		for(const ss_ &id : store("reports")->list("")){
			const json::Value rep = load("reports", id);
			const ss_ reason = jstr(rep, "reason");
			by_reason.set(reason, jint(by_reason, reason.c_str()) + 1);
			reports++;
			if(jint(rep, "decided_at") > 0)
				times.push_back(jint(rep, "decided_at") - jint(rep, "ts"));
		}
		for(const ss_ &id : store("audit")->list("")){
			const json::Value a = load("audit", id);
			const ss_ k = jstr(a, "action")+(a.get("auto").is_true() ?
					" (automatic)" : "");
			by_action.set(k, jint(by_action, k.c_str()) + 1);
		}
		std::sort(times.begin(), times.end());
		json::Value v = json::object();
		v.set("ok", true);
		v.set("starport", jstr(m_settings, "name"));
		v.set("reports", reports);
		v.set("reports_by_reason", by_reason);
		v.set("actions", by_action);
		v.set("median_seconds_to_decide", times.empty() ? (int64_t)0 :
				times[times.size() / 2]);
		respond(r, 200, v);
	}

	// -----------------------------------------------------------------------
	// 10. Starport ID: an account of this server's builtin/accounts, and
	// what Starport keeps of it in "ids" (all of it listed to the user at
	// registration, 10a)

	static int64_t this_year()
	{
		const time_t t = time(nullptr);
		struct tm tm;
		gmtime_r(&t, &tm);
		return tm.tm_year + 1900;
	}

	// 10b: the lowest the age can be, from the year alone; 18 for "18 or
	// over", which is all that is known of an adult
	static int64_t age_low(const json::Value &id)
	{
		if(id.get("adult").is_true())
			return 18;
		// Not said yet (an account made by joining the app): the youngest
		if(id.get("birth_year").is_undefined())
			return 0;
		return this_year() - jint(id, "birth_year") - 1;
	}
	static const char* band(const json::Value &id)
	{
		const int64_t a = age_low(id);
		return a >= 18 ? "18+" : a >= 13 ? "13-17" : "under 13";
	}

	// The account: "" when done, else why not. q has adult (bool), or
	// birth_year and, under 13, consent
	ss_ set_age(json::Value &id, const json::Value &q)
	{
		if(q.get("adult").is_true()){
			id.set("adult", true);
			id.del_key("birth_year");
			id.del_key("consent");
			return "";
		}
		const int64_t y = jint(q, "birth_year");
		if(y < this_year() - 120 || y > this_year())
			return "birth_year: the year you were born";
		json::Value probe = json::object();
		probe.set("birth_year", y);
		if(age_low(probe) >= 18){
			// Not kept: an adult is "18 or over" and nothing more
			id.set("adult", true);
			id.del_key("birth_year");
			id.del_key("consent");
			return "";
		}
		if(age_low(probe) < 13 && !q.get("consent").is_true())
			return "consent: under 13, a parent's consent is needed";
		id.set("adult", false);
		id.set("birth_year", y);
		id.set("consent", q.get("consent").is_true());
		return "";
	}

	json::Value id_me(const ss_ &name)
	{
		const json::Value id = load("ids", name);
		const json::Value o = load("operators", name);
		json::Value me = json::object();
		me.set("name", name);
		me.set("email", jstr(o, "email"));
		me.set("email_pending", jstr(o, "email_pending"));
		me.set("adult", id.get("adult").is_true());
		if(!id.get("adult").is_true())
			me.set("birth_year", jint(id, "birth_year"));
		me.set("consent", id.get("consent").is_true());
		me.set("band", !id.get("adult").is_true() &&
				id.get("birth_year").is_undefined() ? "not said" : band(id));
		me.set("logins", jint(id, "logins"));
		me.set("key", jstr(id, "key"));
		bool totp = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			totp = a->totp_on(name);
		});
		me.set("totp", totp);
		me.set("suspended_until", jint(id, "suspended_until"));
		json::Value scopes = json::array();
		const json::Value &sc = id.get("scopes");
		if(sc.is_object())
			for(json::Iterator it(sc); it.valid(); it.next()){
				json::Value x = json::object();
				x.set("scope", it.key());
				x.set("name", jstr(it.value(), "name"));
				scopes.append(x);
			}
		me.set("scopes", scopes);
		// Its statements of reasons (6), where it was suspended
		json::Value st = json::array();
		for(const ss_ &sid : store("statements")->list("")){
			const json::Value s = load("statements", sid);
			if(jstr(s, "owner") == name)
				st.append(s);
		}
		me.set("statements", st);
		return me;
	}

	ss_ new_session(const ss_ &name)
	{
		const ss_ session = random_hex(32);
		json::Value s = json::object();
		s.set("name", name);
		s.set("expires", now_s() + 30 * 86400);
		put("sessions", hex(interface::sha256::calculate(session)), s);
		return session;
	}

	// The ID a session is of, or ""
	ss_ session_name(const ss_ &session)
	{
		if(session.empty() || session.size() > 100)
			return "";
		const ss_ key = hex(interface::sha256::calculate(session));
		const json::Value s = load("sessions", key);
		if(!s.is_object())
			return "";
		if(jint(s, "expires") < now_s()){
			store("sessions")->remove(key);
			return "";
		}
		return jstr(s, "name");
	}

	// The reminder of a missing recovery e-mail: on the 2nd, 6th, 18th,
	// 54th... login (2 * 3^n, 10a)
	static bool remind_login(int64_t n)
	{
		for(int64_t m = 2; m <= n; m *= 3)
			if(m == n)
				return true;
		return false;
	}

	// A per-fleet identity (10c): the same in a fleet, different in any
	// other; a listing in no fleet is its own scope
	ss_ scope_of(const json::Value &l)
	{
		return jstr(l, "fleet").empty() ? "listing:"+jstr(l, "id") :
				"fleet:"+jstr(l, "fleet");
	}
	ss_ sub_of(const ss_ &name, const ss_ &scope)
	{
		json::Value k = load("settings", "id_secret");
		if(!k.is_string()){
			k = json::Value(random_hex(32));
			put("settings", "id_secret", k);
		}
		return hex(interface::sha256::hmac(unhex(k.as_string()),
				name+"|"+scope)).substr(0, 24);
	}

	static ss_ base64url(const ss_ &data)
	{
		static const char *A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop"
				"qrstuvwxyz0123456789-_";
		ss_ out;
		uint32_t buf = 0;
		int bits = 0;
		for(unsigned char c : data){
			buf = (buf << 8) | c;
			bits += 8;
			while(bits >= 6){
				out += A[(buf >> (bits - 6)) & 63];
				bits -= 6;
			}
		}
		if(bits > 0)
			out += A[(buf << (6 - bits)) & 63];
		return out;
	}

	void api_id(const network::HttpRequest &r, const json::Value &b)
	{
		const ss_ what = r.path.substr(8);
		json::Value result;
		ss_ error;
		try {
			result = id_call(r, what, b);
		} catch(std::exception &e){
			error = e.what();
		}
		json::Value v = json::object();
		if(error.empty()){
			v.set("ok", true);
			v.set("result", result);
		} else {
			v.set("ok", false);
			v.set("error", error);
		}
		respond(r, 200, v);
	}

	json::Value id_call(const network::HttpRequest &r, const ss_ &what,
			const json::Value &b)
	{
		accounts::Interface *acc = nullptr;
		accounts::access(m_server, [&](accounts::Interface *a){ acc = a; });
		if(!acc)
			throw Exception("Starport is not ready");
		if(what == "register"){
			if(!setting("id_registration").is_true())
				throw Exception("this Starport makes no new IDs");
			if(!rate_ok("id_register", r.address, 5, 86400))
				throw Exception("too many new IDs from this address today");
			const ss_ name = jstr(b, "name");
			json::Value id = json::object();
			const ss_ age_error = set_age(id, b);
			if(!age_error.empty())
				throw Exception(age_error);
			const ss_ err = acc->create_account(name, jstr(b, "password"));
			if(!err.empty())
				throw Exception(err);
			id.set("logins", (int64_t)1);
			id.set("created", now_s());
			id.set("scopes", json::object());
			// The report key the client had, or a new one (5c)
			const ss_ key = jstr(b, "key");
			id.set("key", is_hex(key, 64) ? key : random_hex(32));
			put("ids", name, id);
			json::Value out = json::object();
			if(!jstr(b, "email").empty()){
				try {
					out.set("email", cmd_set_email(name, jstr(b, "email")));
				} catch(std::exception &e){
					out.set("email_error", e.what());
				}
			}
			out.set("session", new_session(name));
			out.set("me", id_me(name));
			return out;
		}
		if(what == "login"){
			const ss_ name = jstr(b, "name");
			if(!rate_ok("id_login_addr", r.address, 30, 3600) ||
					!rate_ok("id_login_name", name, 10, 3600))
				throw Exception("too many logins; try later");
			json::Value id = load("ids", name);
			if(!acc->check_password(name, jstr(b, "password")))
				throw Exception("wrong name or password");
			// An account made by joining the app (an operator's) is an ID
			// too, from its first login here; its age is not said yet
			if(!id.is_object()){
				id = json::object();
				id.set("logins", (int64_t)0);
				id.set("created", now_s());
				id.set("scopes", json::object());
				id.set("key", random_hex(32));
				id.set("adult", false);
			}
			if(acc->totp_on(name)){
				if(jstr(b, "totp").empty())
					throw Exception("totp");
				if(!acc->check_totp(name, jstr(b, "totp")))
					throw Exception("wrong TOTP code");
			}
			if(jint(id, "suspended_until") > now_s())
				throw Exception("this ID is suspended; its statement of "
						"reasons is on the Starport");
			id.set("logins", jint(id, "logins") + 1);
			put("ids", name, id);
			json::Value out = json::object();
			out.set("session", new_session(name));
			out.set("me", id_me(name));
			out.set("remind_email", jstr(load("operators", name),
					"email").empty() && remind_login(jint(id, "logins")));
			return out;
		}
		if(what == "reset_request"){
			const ss_ name = jstr(b, "name");
			const json::Value o = load("operators", name);
			if(!rate_ok("id_reset", name, 3, 86400) ||
					!rate_ok("id_reset_addr", r.address, 10, 86400))
				throw Exception("too many resets; try later");
			// Said the same whether or not there is an address, so a
			// name's e-mail cannot be probed
			if(!jstr(o, "email").empty() && can_mail()){
				json::Value id = load("ids", name);
				const ss_ code = random_hex(4);
				id.set("reset_code", code);
				id.set("reset_ts", now_s());
				put("ids", name, id);
				const ss_ sp = jstr(m_settings, "name");
				mail(name, jstr(o, "email"), sp+": a new password",
						"A new password for the Starport ID "+name+" on "+sp+
						" was asked for. The code is:\n\n    "+code+"\n\n"
						"If that was not you, nothing needs doing.\n");
			}
			return json::Value("if the ID has a recovery e-mail, a code "
					"went to it");
		}
		if(what == "reset"){
			const ss_ name = jstr(b, "name");
			json::Value id = load("ids", name);
			if(!rate_ok("id_reset_try", name, 10, 86400) ||
					jstr(id, "reset_code").empty() ||
					now_s() - jint(id, "reset_ts") > 86400 ||
					!same(jstr(id, "reset_code"), jstr(b, "code")))
				throw Exception("not the code, or it is over a day old");
			const ss_ err = acc->set_password(name, jstr(b, "password"));
			if(!err.empty())
				throw Exception(err);
			id.set("reset_code", "");
			put("ids", name, id);
			return json::Value(true);
		}
		// The rest are of a logged-in ID
		const ss_ name = session_name(jstr(b, "session"));
		if(name.empty())
			throw Exception("session");
		json::Value id = load("ids", name);
		if(!id.is_object())
			throw Exception("session");
		if(what == "me")
			return id_me(name);
		if(what == "logout"){
			store("sessions")->remove(hex(interface::sha256::calculate(
					jstr(b, "session"))));
			return json::Value(true);
		}
		if(what == "email")
			return cmd_set_email(name, jstr(b, "email"));
		if(what == "confirm_email")
			return cmd_confirm_email(name, jstr(b, "code"));
		if(what == "age"){
			const ss_ err = set_age(id, b);
			if(!err.empty())
				throw Exception(err);
			put("ids", name, id);
			return id_me(name);
		}
		if(what == "password"){
			if(!acc->check_password(name, jstr(b, "old")))
				throw Exception("the old password is wrong");
			const ss_ err = acc->set_password(name, jstr(b, "new"));
			if(!err.empty())
				throw Exception(err);
			return json::Value(true);
		}
		if(what == "totp"){
			const ss_ cmd = jstr(b, "cmd");
			json::Value out = json::object();
			if(cmd == "begin"){
				out.set("secret", acc->totp_begin(name));
				out.set("uri", acc->totp_uri(name, jstr(out, "secret")));
			} else if(cmd == "confirm" || cmd == "off"){
				const ss_ err = cmd == "confirm" ?
						acc->totp_confirm(name, jstr(b, "code")) :
						acc->totp_off(name, jstr(b, "code"));
				if(!err.empty())
					throw Exception(err);
			}
			out.set("on", acc->totp_on(name));
			return out;
		}
		if(what == "delete"){
			if(!acc->check_password(name, jstr(b, "password")))
				throw Exception("the password is wrong");
			// What moderation must keep of a suspended ID stays, as its
			// record and not as the account (10a)
			if(jint(id, "suspended_until") > now_s()){
				json::Value keep = json::object();
				keep.set("band", band(id));
				keep.set("suspended_until", jint(id, "suspended_until"));
				keep.set("deleted", now_s());
				put("moderation_ids", name, keep);
			}
			store("ids")->remove(name);
			store("operators")->remove(name);
			acc->delete_account(name);
			for(const ss_ &k : store("sessions")->list(""))
				if(jstr(load("sessions", k), "name") == name)
					store("sessions")->remove(k);
			return json::Value(true);
		}
		if(what == "token")
			return id_token(name, id, b);
		throw Exception("no such call");
	}

	// 10c: a token for one listing, signed with its secret, which its
	// server checks without asking Starport. The name used in a fleet is
	// asked the first time ("name" back, and the ID's own as a suggestion)
	json::Value id_token(const ss_ &name, json::Value id, const json::Value &b)
	{
		if(jint(id, "suspended_until") > now_s())
			throw Exception("this ID is suspended");
		if(!id.get("adult").is_true() && id.get("birth_year").is_undefined())
			throw Exception("say your age on the ID's page first");
		const json::Value l = load("listings", jstr(b, "listing"));
		if(!l.is_object())
			throw Exception("no such listing");
		// 10b: the age band against the listing's audience
		const ss_ aud = jstr(effective(l), "audience");
		const int64_t age = age_low(id);
		if((aud == "adult" && age < 18) || (aud == "teen" && age < 13))
			throw Exception("this server's audience is "+aud+": not for "
					"this ID's age");
		const ss_ scope = scope_of(l);
		json::Value scopes = id.get("scopes").is_object() ?
				id.get("scopes").deepcopy() : json::object();
		ss_ shown = jstr(scopes.get(scope), "name");
		if(shown.empty()){
			const ss_ want = jstr(b, "name");
			if(want.empty()){
				json::Value out = json::object();
				out.set("need_name", true);
				out.set("suggest", name);
				return out;
			}
			if(want.size() > 20 || want.find_first_not_of(
					"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
					"0123456789_-") != ss_::npos)
				throw Exception("a name is 1 to 20 letters, digits, _ or -");
			const ss_ taken_key = scope+"|"+want;
			const json::Value taken = load("scope_names", taken_key);
			if(taken.is_string() && taken.as_string() != name)
				throw Exception("that name is taken in this community");
			put("scope_names", taken_key, json::Value(name));
			json::Value s = json::object();
			s.set("name", want);
			scopes.set(scope, s);
			id.set("scopes", scopes);
			put("ids", name, id);
			shown = want;
		}
		// 10d: which ID a server's report of this identity is about
		put("subs", scope+"|"+sub_of(name, scope), json::Value(name));
		json::Value p = json::object();
		p.set("sub", sub_of(name, scope));
		p.set("name", shown);
		p.set("listing", jstr(l, "id"));
		p.set("exp", now_s() + 30 * 86400);
		if(aud == "adult")
			p.set("adult", true);
		const ss_ payload = base64url(p.stringify());
		json::Value out = json::object();
		out.set("token", payload+"."+hex(interface::sha256::hmac(
				unhex(jstr(l, "secret")), payload)));
		out.set("name", shown);
		out.set("exp", jint(p, "exp"));
		return out;
	}

	// -----------------------------------------------------------------------
	// Every tick: the verifier's results; once a day, what keeping data
	// costs; every six hours, the listings checked again

	void on_tick(const interface::TickEvent &)
	{
		if(!m_save)
			return;
		apply_verify_results();
		const int64_t t = now_s();
		if(t >= m_next_reverify){
			m_next_reverify = t + 6 * 3600;
			for(const ss_ &id : store("listings")->list("")){
				const json::Value l = load("listings", id);
				if(l.is_object() && t - jint(l, "last_announce") < 900)
					queue_verify(l);
			}
		}
		if(day_of(t) != m_last_day){
			m_last_day = day_of(t);
			daily();
		}
	}

	void daily()
	{
		const int64_t t = now_s();
		const int64_t keep = jint(m_settings, "retention_days", 7) * 86400;
		int cleared = 0;
		store("reports")->batch([&](){
			for(const ss_ &id : store("reports")->list("")){
				json::Value rep = load("reports", id);
				if(!jstr(rep, "address").empty() && t - jint(rep, "ts") > keep){
					rep.set("address", "");
					put("reports", id, rep);
					cleared++;
				}
			}
		});
		// Listings not heard from in 30 days go, unless moderation has a
		// record of them
		int gone = 0;
		for(const ss_ &id : store("listings")->list("")){
			const json::Value l = load("listings", id);
			if(t - jint(l, "last_announce") > 30 * 86400 &&
					jstr(l, "status") == "active" &&
					l.get("strikes").size() == 0){
				store("listings")->remove(id);
				gone++;
			}
		}
		// 10b: a year that has reached 18 is dropped for "18 or over"
		for(const ss_ &name : store("ids")->list("")){
			json::Value id = load("ids", name);
			if(!id.get("adult").is_true() && age_low(id) >= 18){
				id.set("adult", true);
				id.del_key("birth_year");
				id.del_key("consent");
				put("ids", name, id);
			}
		}
		for(const ss_ &k : store("sessions")->list(""))
			if(jint(load("sessions", k), "expires") < t)
				store("sessions")->remove(k);
		// A delisting for a time runs out
		for(const ss_ &id : store("listings")->list("")){
			json::Value l = load("listings", id);
			const int64_t until = jint(l, "status_until");
			if(until > 0 && until <= t){
				l.set("status", "active");
				l.set("status_until", (int64_t)0);
				put("listings", id, l);
			}
		}
		log_i(MODULE, "Daily: %d addresses cleared, %d listings gone", cleared,
				gone);
	}

	// -----------------------------------------------------------------------
	// The app: moderators, operators and the admin ([STARPORT] 1, 2a, 6)

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface *iface){
			iface->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
	}

	ss_ account_of(network::PeerInfo::Id peer)
	{
		ss_ name;
		accounts::access(m_server, [&](accounts::Interface *a){
			name = a->name_of(peer);
		});
		return name;
	}
	bool is_admin(const ss_ &name)
	{
		bool admin = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			admin = a->is_admin(name);
		});
		return admin;
	}
	bool is_moderator(const ss_ &name)
	{
		if(is_admin(name))
			return true;
		const json::Value &m = setting("moderators");
		for(unsigned i = 0; m.is_array() && i < m.size(); i++)
			if(m.at(i).is_string() && m.at(i).as_string() == name)
				return true;
		return false;
	}

	void on_req(const network::Packet &packet)
	{
		const json::Value req = json::load_string(packet.data.c_str());
		json::Value res = json::object();
		res.set("id", req.get("id"));
		const ss_ name = account_of(packet.sender);
		ss_ error;
		json::Value result;
		if(!m_save)
			error = "Starport is not ready";
		else if(name.empty())
			error = "join first";
		else if(!req.is_object())
			error = "not a request";
		else {
			try {
				result = handle(name, jstr(req, "cmd"), req);
			} catch(std::exception &e){
				error = e.what();
			}
		}
		if(error.empty()){
			res.set("ok", true);
			res.set("result", result);
		} else {
			res.set("ok", false);
			res.set("error", error);
		}
		network::access(m_server, [&](network::Interface *iface){
			iface->send(packet.sender, "sp:res", res.stringify());
		});
	}

	json::Value listing_summary(const json::Value &l)
	{
		json::Value s = json::object();
		for(const char *k : {"id", "name", "description", "host", "port",
				"app", "status", "owner", "verify", "players", "relabel",
				"fleet", "pool", "pool_mismatch",
				"status_until"})
			s.set(k, l.get(k));
		const json::Value e = effective(l);
		for(const char *k : {"kind", "audience", "access", "descriptors"})
			s.set(k, e.get(k));
		s.set("served", served_status(l));
		return s;
	}

	json::Value handle(const ss_ &name, const ss_ &cmd, const json::Value &q)
	{
		const bool mod = is_moderator(name);
		const bool admin = is_admin(name);
		if(cmd == "me")
			return cmd_me(name, mod, admin);
		if(cmd == "set_email")
			return cmd_set_email(name, jstr(q, "email"));
		if(cmd == "confirm_email")
			return cmd_confirm_email(name, jstr(q, "code"));
		if(cmd == "claim")
			return cmd_claim(name, q);
		if(cmd == "fleet_create" || cmd == "fleet_update" ||
				cmd == "fleet_new_code")
			return cmd_fleet(name, cmd, q);
		if(cmd == "fleet_remove_server")
			return cmd_fleet_remove_server(name, q);
		if(cmd.compare(0, 10, "blocklist_") == 0 || cmd == "blocklists")
			return cmd_blocklist(name, cmd, q);
		if(cmd == "appeal")
			return cmd_appeal(name, q);
		if(!mod)
			throw Exception("for moderators");
		if(cmd == "queue")
			return cmd_queue();
		if(cmd == "group")
			return cmd_group(jstr(q, "group"));
		if(cmd == "decide")
			return cmd_decide(name, q);
		if(cmd == "act")
			return cmd_act(name, q);
		if(cmd == "listings")
			return cmd_listings(jstr(q, "search"));
		if(cmd == "audit")
			return cmd_audit();
		if(cmd == "appeals")
			return cmd_appeals();
		if(cmd == "decide_appeal")
			return cmd_decide_appeal(name, q);
		if(cmd == "suspend_id"){
			suspend_id(name, jstr(q, "id"), jint(q, "days"),
					jstr(q, "reason", "other"), jstr(q, "text"));
			return json::Value(true);
		}
		if(!admin)
			throw Exception("for the admin");
		if(cmd == "settings")
			return m_settings;
		if(cmd == "set_settings")
			return cmd_set_settings(q);
		if(cmd == "trust_reporter")
			return cmd_trust_reporter(q);
		throw Exception("no such command: "+cmd);
	}

	json::Value cmd_me(const ss_ &name, bool mod, bool admin)
	{
		json::Value r = json::object();
		r.set("name", name);
		r.set("moderator", mod);
		r.set("admin", admin);
		const json::Value o = load("operators", name);
		r.set("email", o.is_object() ? jstr(o, "email") : ss_());
		r.set("email_pending", o.is_object() ? jstr(o, "email_pending") :
				ss_());
		r.set("email_confirmation", setting("email_confirmation").is_true());
		json::Value ls = json::array();
		for(const ss_ &id : store("listings")->list("")){
			const json::Value l = load("listings", id);
			if(jstr(l, "owner") == name)
				ls.append(listing_summary(l));
		}
		r.set("listings", ls);
		json::Value st = json::array();
		for(const ss_ &id : store("statements")->list("")){
			const json::Value s = load("statements", id);
			if(jstr(s, "owner") == name)
				st.append(s);
		}
		r.set("statements", st);
		json::Value fleets = json::array();
		for(const ss_ &id : store("fleets")->list("")){
			const json::Value f = load("fleets", id);
			if(jstr(f, "owner") == name)
				fleets.append(f);
		}
		r.set("fleets", fleets);
		r.set("starport", jstr(m_settings, "name"));
		return r;
	}

	// "set" when taken as given, "sent" when a code went to it
	json::Value cmd_set_email(const ss_ &name, const ss_ &email)
	{
		// Goes into a mail's header: one address, nothing that ends a line
		const size_t at = email.find('@');
		if(email.size() > 200 || at == ss_::npos || at == 0 ||
				at != email.rfind('@') || at + 1 == email.size() ||
				email.find_first_of(" \t\r\n<>,;\"()") != ss_::npos)
			throw Exception("an e-mail address");
		json::Value o = load("operators", name);
		if(!o.is_object())
			o = json::object();
		if(!setting("email_confirmation").is_true()){
			o.set("email", email);
			o.set("email_pending", "");
			put("operators", name, o);
			return json::Value("set");
		}
		const json::Value &smtp = setting("smtp");
		if(jstr(smtp, "url").empty() || jstr(smtp, "from").empty())
			throw Exception("this Starport cannot send mail: its admin sets "
					"smtp, or turns email_confirmation off");
		if(!interface::mail_supported())
			throw Exception("this Starport's libcurl cannot send mail (a "
					"minimal build): its admin installs a full one, or turns "
					"email_confirmation off");
		if(!rate_ok("mail", name, 3, 3600))
			throw Exception("three codes an hour; try later");
		const ss_ code = random_hex(4);
		o.set("email_pending", email);
		o.set("email_code", code);
		o.set("email_code_ts", now_s());
		put("operators", name, o);
		const ss_ sp = jstr(m_settings, "name");
		mail(name, email, sp+": confirming your e-mail address",
				"The account "+name+" on "+sp+" gave this address as its\n"
				"contact. To confirm it, enter this code there:\n"
				"\n"
				"    "+code+"\n"
				"\n"
				"If that was not you, nothing needs doing.\n");
		return json::Value("sent");
	}

	// Whether mail can go: the setting's server, and a libcurl that has SMTP
	bool can_mail()
	{
		const json::Value &smtp = setting("smtp");
		return !jstr(smtp, "url").empty() && !jstr(smtp, "from").empty() &&
				interface::mail_supported();
	}

	// A mail to an account's address, on a thread of its own holding
	// copies only: the mail server may be slow, and this module may be
	// gone before it answers. `to` is an address set_email let through:
	// nothing in it ends a header line
	void mail(const ss_ &account, const ss_ &to, const ss_ &subject,
			const ss_ &text)
	{
		const json::Value &smtp = setting("smtp");
		char date[64];
		const time_t t = time(nullptr);
		struct tm tm;
		gmtime_r(&t, &tm);
		strftime(date, sizeof date, "%a, %d %b %Y %H:%M:%S +0000", &tm);
		ss_ body;
		for(char c : text){
			if(c == '\n')
				body += "\r\n";
			else if(c != '\r')
				body += c;
		}
		ss_ subj;
		for(char c : subject)
			subj += c == '\r' || c == '\n' ? ' ' : c;
		const ss_ message = ss_("Date: ")+date+"\r\n"
				"From: "+jstr(smtp, "from")+"\r\n"
				"To: "+to+"\r\n"
				"Subject: "+subj+"\r\n"
				"Content-Type: text/plain; charset=utf-8\r\n"
				"\r\n"+body;
		const ss_ url = jstr(smtp, "url"), user = jstr(smtp, "user"),
				password = jstr(smtp, "password"), from = jstr(smtp, "from");
		std::thread([=](){
			try {
				interface::send_mail(url, user, password, from, to, message);
				log_i(MODULE, "Mailed %s: %s", cs(account), cs(subj));
			} catch(std::exception &e){
				log_w(MODULE, "Mail to %s: %s", cs(account), e.what());
			}
		}).detach();
	}

	json::Value cmd_confirm_email(const ss_ &name, const ss_ &code)
	{
		json::Value o = load("operators", name);
		if(!o.is_object() || jstr(o, "email_pending").empty())
			throw Exception("no address waiting for a code");
		if(now_s() - jint(o, "email_code_ts") > 86400)
			throw Exception("the code is over a day old; ask for another");
		if(!same(jstr(o, "email_code"), code))
			throw Exception("not the code");
		o.set("email", jstr(o, "email_pending"));
		o.set("email_pending", "");
		o.set("email_code", "");
		put("operators", name, o);
		return json::Value(true);
	}

	json::Value cmd_claim(const ss_ &name, const json::Value &q)
	{
		const json::Value o = load("operators", name);
		if(!o.is_object() || jstr(o, "email").empty())
			throw Exception("set your contact e-mail first");
		if(banned("account", name))
			throw Exception("this account may not claim listings");
		json::Value l = load("listings", jstr(q, "listing"));
		if(!l.is_object())
			throw Exception("no such listing");
		const ss_ code = hex(interface::sha256::hmac(unhex(jstr(l, "secret")),
				"claim")).substr(0, 16);
		if(!same(code, jstr(q, "code")))
			throw Exception("not its claim code");
		// A server with a new key: its old listing's record comes along
		const ss_ old = jstr(q, "replaces");
		if(!old.empty()){
			const json::Value ol = load("listings", old);
			if(!ol.is_object() || jstr(ol, "owner") != name)
				throw Exception("the listing replaced is not yours");
			for(const char *k : {"status", "status_until", "status_auto",
					"relabel", "strikes", "first_seen"})
				if(!ol.get(k).is_undefined())
					l.set(k, ol.get(k));
			store("listings")->remove(old);
			audit(name, jstr(l, "id"), "replace", "", "replaces "+old, false);
		}
		l.set("owner", name);
		put("listings", jstr(l, "id"), l);
		audit(name, jstr(l, "id"), "claim", "", "", false);
		return listing_summary(l);
	}

	// -- 10d. Bans shared: blocklists

	// A server's whole current set of reported bans: kept as its own, and
	// a ban new to it is a report about the ID for a moderator
	void take_bans(const json::Value &l, const json::Value &bans)
	{
		if(!bans.is_array())
			return;
		const ss_ scope = scope_of(l);
		const json::Value old = load("listing_bans", jstr(l, "id"));
		json::Value now = json::array();
		for(unsigned i = 0; i < bans.size() && i < 10000; i++){
			const json::Value &x = bans.at(i);
			const ss_ sub = jstr(x, "sub");
			const json::Value who = load("subs", scope+"|"+sub);
			if(!who.is_string())
				continue; // not an identity this Starport gave
			json::Value e = json::object();
			e.set("sub", sub);
			e.set("name", who.as_string());
			ss_ reason = jstr(x, "reason");
			e.set("reason", reason);
			now.append(e);
			bool was = false;
			for(unsigned j = 0; old.is_array() && j < old.size(); j++)
				was |= jstr(old.at(j), "sub") == sub;
			if(was)
				continue;
			if(!in_set(reason, REASONS))
				reason = "other";
			json::Value rep = json::object();
			const ss_ rid = random_hex(8);
			rep.set("id", rid);
			rep.set("listing", jstr(l, "id"));
			rep.set("reason", reason);
			rep.set("text", "banned on "+jstr(l, "name")+" ("+
					jstr(l, "id")+"), reported by the server");
			rep.set("key", "");
			rep.set("address", "");
			rep.set("ts", now_s());
			rep.set("trusted", false);
			rep.set("weight", 1.0);
			rep.set("state", "open");
			const ss_ gid = "id:"+who.as_string()+"|"+reason;
			rep.set("group", gid);
			put("reports", rid, rep);
			add_to_group(gid, jstr(l, "id"), reason, rid, "");
			json::Value g = load("groups", gid);
			g.set("id_name", who.as_string());
			put("groups", gid, g);
		}
		put("listing_bans", jstr(l, "id"), now);
	}

	// The IDs a list bans: its publishers' current bans
	std::set<ss_> list_bans(const json::Value &list)
	{
		std::set<ss_> names;
		const json::Value &pubs = list.get("publishers");
		for(const ss_ &lid : store("listing_bans")->list("")){
			const json::Value ol = load("listings", lid);
			bool published = false;
			for(unsigned i = 0; pubs.is_array() && i < pubs.size(); i++){
				const ss_ p = pubs.at(i).as_string();
				published |= p == scope_of(ol) || p == "listing:"+lid;
			}
			if(!published)
				continue;
			const json::Value bans = load("listing_bans", lid);
			for(unsigned i = 0; bans.is_array() && i < bans.size(); i++)
				names.insert(jstr(bans.at(i), "name"));
		}
		return names;
	}

	// What a listing's server keeps out: the bans of the lists it
	// subscribes to, each as the identity it has in that server's fleet
	json::Value blocked_for(const json::Value &l)
	{
		const ss_ scope = scope_of(l);
		std::set<ss_> names;
		for(const ss_ &id : store("blocklists")->list("")){
			const json::Value list = load("blocklists", id);
			const json::Value &subs = list.get("subscribers");
			bool sub = false;
			for(unsigned i = 0; subs.is_array() && i < subs.size(); i++){
				const ss_ s = subs.at(i).as_string();
				sub |= s == scope || s == "listing:"+jstr(l, "id");
			}
			if(sub)
				for(const ss_ &n : list_bans(list))
					names.insert(n);
		}
		json::Value out = json::array();
		for(const ss_ &n : names)
			out.append(sub_of(n, scope));
		return out;
	}

	// Whether `scope` ("fleet:<id>" or "listing:<id>") is the account's
	bool owns_scope(const ss_ &name, const ss_ &scope)
	{
		if(scope.compare(0, 6, "fleet:") == 0)
			return jstr(load("fleets", scope.substr(6)), "owner") == name;
		if(scope.compare(0, 8, "listing:") == 0)
			return jstr(load("listings", scope.substr(8)), "owner") == name;
		return false;
	}

	static json::Value without(const json::Value &arr, const ss_ &x)
	{
		json::Value out = json::array();
		for(unsigned i = 0; arr.is_array() && i < arr.size(); i++)
			if(arr.at(i).as_string() != x)
				out.append(arr.at(i));
		return out;
	}
	static json::Value with(const json::Value &arr, const ss_ &x)
	{
		json::Value out = without(arr, x);
		out.append(x);
		return out;
	}

	// Lists are public within the Starport: anyone subscribes their own
	// servers to any. Publishing to another's list is offered by the
	// server's owner and accepted by the list's
	json::Value cmd_blocklist(const ss_ &name, const ss_ &cmd,
			const json::Value &q)
	{
		if(cmd == "blocklists"){
			json::Value out = json::array();
			for(const ss_ &id : store("blocklists")->list("")){
				json::Value list = load("blocklists", id);
				list.set("bans", (int64_t)list_bans(list).size());
				out.append(list);
			}
			return out;
		}
		if(cmd == "blocklist_create"){
			const ss_ lname = jstr(q, "name");
			if(lname.empty() || lname.size() > 60)
				throw Exception("name: 1 to 60 characters");
			json::Value list = json::object();
			list.set("id", random_hex(6));
			list.set("name", lname);
			list.set("owner", name);
			list.set("publishers", json::array());
			list.set("offers", json::array());
			list.set("subscribers", json::array());
			put("blocklists", jstr(list, "id"), list);
			return list;
		}
		json::Value list = load("blocklists", jstr(q, "list"));
		if(!list.is_object())
			throw Exception("no such blocklist");
		const ss_ scope = jstr(q, "scope");
		const bool own_list = jstr(list, "owner") == name;
		if(cmd == "blocklist_accept" || cmd == "blocklist_drop"){
			if(!own_list)
				throw Exception("not your blocklist");
			list.set("offers", without(list.get("offers"), scope));
			if(cmd == "blocklist_accept")
				list.set("publishers", with(list.get("publishers"), scope));
			else
				list.set("publishers", without(list.get("publishers"), scope));
		} else {
			if(!owns_scope(name, scope))
				throw Exception("scope: fleet:<id> or listing:<id> of yours");
			if(cmd == "blocklist_publish"){
				if(own_list)
					list.set("publishers", with(list.get("publishers"),
							scope));
				else
					list.set("offers", with(list.get("offers"), scope));
			} else if(cmd == "blocklist_unpublish"){
				list.set("publishers", without(list.get("publishers"), scope));
				list.set("offers", without(list.get("offers"), scope));
			} else if(cmd == "blocklist_subscribe"){
				list.set("subscribers", q.get("on").is_false() ?
						without(list.get("subscribers"), scope) :
						with(list.get("subscribers"), scope));
			} else
				throw Exception("no such command: "+cmd);
		}
		put("blocklists", jstr(list, "id"), list);
		return list;
	}

	// A Starport moderator's suspension of an ID, with its statement (6)
	void suspend_id(const ss_ &by, const ss_ &idname, int64_t days,
			const ss_ &reason, const ss_ &text)
	{
		json::Value id = load("ids", idname);
		if(!id.is_object())
			throw Exception("no such ID");
		id.set("suspended_until", days > 0 ? now_s() + days * 86400 :
				(int64_t)4102444800LL);
		put("ids", idname, id);
		for(const ss_ &k : store("sessions")->list(""))
			if(jstr(load("sessions", k), "name") == idname)
				store("sessions")->remove(k);
		audit(by, "id:"+idname, "suspend", reason, text, false);
		json::Value fake = json::object();
		fake.set("id", "id:"+idname);
		fake.set("name", "Starport ID "+idname);
		fake.set("owner", idname);
		statement(fake, days > 0 ? "suspended for "+itos(days)+" days" :
				"suspended", reason, text, by);
	}

	// -- 2b. An operator's fleets: made, renamed, a new code

	json::Value cmd_fleet(const ss_ &name, const ss_ &cmd, const json::Value &q)
	{
		json::Value f;
		if(cmd == "fleet_create"){
			const json::Value o = load("operators", name);
			if(!o.is_object() || jstr(o, "email").empty())
				throw Exception("set your contact e-mail first");
			if(banned("account", name))
				throw Exception("this account may not make fleets");
			int n = 0;
			for(const ss_ &id : store("fleets")->list(""))
				n += jstr(load("fleets", id), "owner") == name;
			if(n >= 20)
				throw Exception("20 fleets an account");
			f = json::object();
			f.set("id", random_hex(6));
			f.set("owner", name);
			f.set("code", random_hex(8));
		} else {
			f = load("fleets", jstr(q, "fleet"));
			if(!f.is_object() || jstr(f, "owner") != name)
				throw Exception("no such fleet of yours");
			if(cmd == "fleet_new_code")
				f.set("code", random_hex(8));
		}
		if(cmd != "fleet_new_code"){
			const ss_ fname = jstr(q, "name");
			if(fname.empty() || fname.size() > 60)
				throw Exception("name: 1 to 60 characters");
			if(jstr(q, "description").size() > 500 || jstr(q, "link").size() > 200)
				throw Exception("description: at most 500 characters, link 200");
			f.set("name", fname);
			f.set("description", jstr(q, "description"));
			f.set("link", jstr(q, "link"));
		}
		put("fleets", jstr(f, "id"), f);
		audit(name, "", cmd, "", "fleet "+jstr(f, "id"), false);
		return f;
	}

	json::Value cmd_fleet_remove_server(const ss_ &name, const json::Value &q)
	{
		json::Value l = load("listings", jstr(q, "listing"));
		const json::Value f = load("fleets", jstr(l, "fleet"));
		if(!l.is_object() || jstr(f, "owner") != name)
			throw Exception("no such server in a fleet of yours");
		l.set("fleet_removed", jstr(l, "fleet"));
		l.set("fleet", "");
		l.set("pool", "");
		put("listings", jstr(l, "id"), l);
		return listing_summary(l);
	}

	json::Value cmd_appeal(const ss_ &name, const json::Value &q)
	{
		const json::Value s = load("statements", jstr(q, "statement"));
		if(!s.is_object() || jstr(s, "owner") != name)
			throw Exception("no such statement of yours");
		const ss_ text = jstr(q, "text");
		if(text.empty() || text.size() > 4000)
			throw Exception("say why, in at most 4000 characters");
		json::Value a = json::object();
		const ss_ id = random_hex(6);
		a.set("id", id);
		a.set("statement", jstr(s, "id"));
		a.set("listing", jstr(s, "listing"));
		a.set("by", name);
		a.set("acted_by", jstr(s, "by"));
		a.set("text", text);
		a.set("ts", now_s());
		a.set("state", "open");
		put("appeals", id, a);
		return json::Value(id);
	}

	json::Value cmd_queue()
	{
		struct Item { double priority; json::Value g; };
		std::vector<Item> items;
		const int64_t t = now_s();
		for(const ss_ &id : store("groups")->list("")){
			json::Value g = load("groups", id);
			if(jstr(g, "state") != "open")
				continue;
			const json::Value l = load("listings", jstr(g, "listing"));
			bool flagger = false;
			const json::Value &reps = g.get("reports");
			for(unsigned i = 0; i < reps.size(); i++)
				if(load("reports", reps.at(i).as_string()).get("trusted").is_true())
					flagger = true;
			// [STARPORT] 7: the reason's severity, the weight, a trusted
			// flagger, how long it has waited, how many it reaches
			const double p = severity(jstr(g, "reason")) +
					10.0 * jnum(g, "weight") + (flagger ? 50.0 : 0.0) +
					(double)(t - jint(g, "opened")) / 3600.0 +
					log(1.0 + (double)jint(l, "players"));
			g.set("priority", p);
			g.set("listing_name", jstr(l, "name"));
			g.set("count", (int64_t)reps.size());
			g.set("trusted_flagger", flagger);
			items.push_back({p, g});
		}
		std::sort(items.begin(), items.end(), [](const Item &a, const Item &b){
			return a.priority > b.priority;
		});
		json::Value out = json::array();
		for(const Item &i : items)
			out.append(i.g);
		return out;
	}

	json::Value cmd_group(const ss_ &gid)
	{
		json::Value g = load("groups", gid);
		if(!g.is_object())
			throw Exception("no such group");
		json::Value reps = json::array();
		const json::Value &ids = g.get("reports");
		for(unsigned i = 0; i < ids.size(); i++){
			json::Value rep = load("reports", ids.at(i).as_string());
			if(!rep.is_object())
				continue;
			// Who reported is not shown: their key's standing is
			rep.set("key", jstr(rep, "key").substr(0, 8));
			rep.set("address", "");
			reps.append(rep);
		}
		json::Value r = json::object();
		r.set("group", g);
		r.set("reports", reps);
		// An ID's: its age band and whether it is suspended, nothing more
		if(!jstr(g, "id_name").empty()){
			const json::Value id = load("ids", jstr(g, "id_name"));
			json::Value x = json::object();
			x.set("name", jstr(g, "id_name"));
			x.set("band", id.is_object() ? band(id) : "deleted");
			x.set("suspended_until", jint(id, "suspended_until"));
			r.set("id", x);
		}
		const json::Value l = load("listings", jstr(g, "listing"));
		if(l.is_object())
			r.set("listing", listing_summary(l));
		json::Value hist = json::array();
		for(const ss_ &id : store("audit")->list("")){
			const json::Value a = load("audit", id);
			if(jstr(a, "listing") == jstr(g, "listing"))
				hist.append(a);
		}
		r.set("history", hist);
		return r;
	}

	// A moderator's action on a listing ([STARPORT] 6): relabel, hide,
	// delist (for days, or until review), ban, or for plainly illegal
	// content delist at once and keep what the reports carried
	void apply_action(const ss_ &by, json::Value l, const json::Value &q,
			const ss_ &reason)
	{
		const ss_ type = jstr(q, "action");
		const ss_ text = jstr(q, "text");
		const ss_ id = jstr(l, "id");
		if(type == "relabel"){
			const json::Value &fields = q.get("fields");
			if(!fields.is_object())
				throw Exception("fields: what to set");
			json::Value rl = l.get("relabel").is_object() ?
					l.get("relabel").deepcopy() : json::object();
			for(json::Iterator it(fields); it.valid(); it.next())
				rl.set(it.key(), it.value());
			l.set("relabel", rl);
			if(jstr(l, "status") == "hidden" && l.get("status_auto").is_true())
				l.set("status", "active");
		} else if(type == "hide"){
			l.set("status", "hidden");
		} else if(type == "delist" || type == "csam"){
			l.set("status", "delisted");
			const int64_t days = jint(q, "days");
			l.set("status_until", days > 0 ? now_s() + days * 86400 :
					(int64_t)0);
			json::Value strikes = l.get("strikes").deepcopy();
			strikes.append(now_s());
			l.set("strikes", strikes);
			repeat_offender(l);
		} else if(type == "ban"){
			l.set("status", "banned");
			const int64_t days = jint(q, "days");
			const int64_t until = days > 0 ? now_s() + days * 86400 : 0;
			ban("listing", id, until, by);
			ban("address", jstr(l, "host"), until, by);
			if(q.get("ban_account").is_true() && !jstr(l, "owner").empty())
				ban("account", jstr(l, "owner"), until, by);
		} else if(type == "restore"){
			l.set("status", "active");
			l.set("status_until", (int64_t)0);
		} else
			throw Exception("action: relabel, hide, delist, csam, ban or "
					"restore");
		l.set("status_auto", false);
		put("listings", id, l);
		if(type == "csam"){
			// Kept apart from the retention's clearing, for the authorities
			// the instance's law says to tell
			json::Value keep = json::object();
			keep.set("listing", l);
			keep.set("ts", now_s());
			keep.set("by", by);
			put("preserved", id+"-"+itos(now_s()), keep);
		}
		audit(by, id, type, reason, text, false);
		statement(l, type, reason, text, by);
	}

	void ban(const ss_ &kind, const ss_ &what, int64_t until, const ss_ &by)
	{
		if(what.empty())
			return;
		json::Value b = json::object();
		b.set("until", until);
		b.set("by", by);
		b.set("ts", now_s());
		put("bans", kind+":"+what, b);
	}

	// An operator whose listings are delisted again and again may not
	// announce for a while ([STARPORT] 6)
	void repeat_offender(const json::Value &l)
	{
		const ss_ owner = jstr(l, "owner");
		if(owner.empty())
			return;
		int n = 0;
		const int64_t t = now_s();
		for(const ss_ &id : store("listings")->list("")){
			const json::Value o = load("listings", id);
			if(jstr(o, "owner") != owner)
				continue;
			const json::Value &s = o.get("strikes");
			for(unsigned i = 0; s.is_array() && i < s.size(); i++)
				if(t - s.at(i).as_integer() < 90 * 86400)
					n++;
		}
		if(n >= 3){
			ban("account", owner, t + 30 * 86400, "Starport");
			log_i(MODULE, "%s: delisted %d times in 90 days; barred for 30 days",
					cs(owner), n);
		}
	}

	json::Value cmd_decide(const ss_ &by, const json::Value &q)
	{
		json::Value g = load("groups", jstr(q, "group"));
		if(!g.is_object() || jstr(g, "state") != "open")
			throw Exception("no such open group");
		const ss_ decision = jstr(q, "decision");
		if(decision != "dismiss" && decision != "uphold")
			throw Exception("decision: dismiss or uphold");
		const ss_ reason = jstr(g, "reason");
		if(!jstr(g, "id_name").empty() && decision == "uphold")
			suspend_id(by, jstr(g, "id_name"), jint(q, "days"), reason,
					jstr(q, "text"));
		const sv_<ss_> members = jstr(g, "id_name").empty() ? members_of(g) :
				sv_<ss_>();
		if(decision == "uphold" && members.empty() &&
				jstr(g, "id_name").empty())
			throw Exception("the listing has gone");
		for(const ss_ &id : members){
			json::Value l = load("listings", id);
			if(!l.is_object())
				continue;
			if(decision == "uphold"){
				apply_action(by, l, q, reason);
			} else if(l.get("status_auto").is_true()){
				// What was done automatically is undone
				l.set("status", "active");
				l.set("status_auto", false);
				if(reason == "category")
					l.del_key("relabel");
				put("listings", id, l);
				audit(by, id, "restore", reason,
						"the automatic action undone: reports dismissed", false);
			} else
				audit(by, id, "dismiss", reason, jstr(q, "text"), false);
		}
		// The reporters' records
		const json::Value &reps = g.get("reports");
		const int64_t t = now_s();
		for(unsigned i = 0; i < reps.size(); i++){
			json::Value rep = load("reports", reps.at(i).as_string());
			if(!rep.is_object())
				continue;
			rep.set("state", decision == "uphold" ? "upheld" : "rejected");
			rep.set("outcome", decision == "uphold" ? "acted on: "+
					jstr(q, "action") : "no action");
			rep.set("decided_at", t);
			put("reports", jstr(rep, "id"), rep);
			const ss_ h = jstr(rep, "key");
			json::Value k = h.empty() ? json::Value() : load("keys", h);
			if(!k.is_object())
				continue;
			const char *f = decision == "uphold" ? "upheld" : "rejected";
			k.set(f, jint(k, f) + 1);
			// [STARPORT] 6: a reporter whose reports are mostly rejected is
			// not heard for a while
			if(jint(k, "rejected") >= 5 && jint(k, "rejected") >
					3 * jint(k, "upheld"))
				k.set("muted_until", t + 30 * 86400);
			put("keys", h, k);
		}
		g.set("state", "closed");
		g.set("decided", decision);
		g.set("decided_by", by);
		g.set("decided_at", t);
		put("groups", jstr(g, "id"), g);
		return json::Value(true);
	}

	json::Value cmd_act(const ss_ &by, const json::Value &q)
	{
		if(!jstr(q, "fleet").empty()){
			const ss_ reason = jstr(q, "reason");
			if(!in_set(reason, REASONS))
				throw Exception("reason: one of the report reasons");
			json::Value g = json::object();
			g.set("fleet", jstr(q, "fleet"));
			const sv_<ss_> members = members_of(g);
			if(members.empty())
				throw Exception("no servers in that fleet");
			for(const ss_ &id : members)
				apply_action(by, load("listings", id), q, reason);
			return json::Value((int64_t)members.size());
		}
		json::Value l = load("listings", jstr(q, "listing"));
		if(!l.is_object())
			throw Exception("no such listing");
		const ss_ reason = jstr(q, "reason");
		if(!in_set(reason, REASONS))
			throw Exception("reason: one of the report reasons");
		apply_action(by, l, q, reason);
		return listing_summary(load("listings", jstr(q, "listing")));
	}

	json::Value cmd_listings(const ss_ &search)
	{
		json::Value out = json::array();
		ss_ s = search;
		std::transform(s.begin(), s.end(), s.begin(), ::tolower);
		for(const ss_ &id : store("listings")->list("")){
			const json::Value l = load("listings", id);
			ss_ hay = jstr(l, "name")+" "+jstr(l, "id")+" "+jstr(l, "owner")+
					" "+jstr(l, "host");
			std::transform(hay.begin(), hay.end(), hay.begin(), ::tolower);
			if(s.empty() || hay.find(s) != ss_::npos)
				out.append(listing_summary(l));
			if(out.size() >= 200)
				break;
		}
		return out;
	}

	json::Value cmd_audit()
	{
		json::Value out = json::array();
		sv_<ss_> keys = store("audit")->list("");
		for(size_t i = keys.size(); i > 0 && out.size() < 300; i--)
			out.append(load("audit", keys[i - 1]));
		return out;
	}

	json::Value cmd_appeals()
	{
		json::Value out = json::array();
		for(const ss_ &id : store("appeals")->list("")){
			json::Value a = load("appeals", id);
			if(jstr(a, "state") != "open")
				continue;
			a.set("statement_text", load("statements", jstr(a, "statement")));
			out.append(a);
		}
		return out;
	}

	json::Value cmd_decide_appeal(const ss_ &by, const json::Value &q)
	{
		json::Value a = load("appeals", jstr(q, "appeal"));
		if(!a.is_object() || jstr(a, "state") != "open")
			throw Exception("no such open appeal");
		if(jstr(a, "acted_by") == by && !jstr(a, "acted_by").empty())
			throw Exception("another moderator than the one who acted decides");
		const ss_ outcome = jstr(q, "outcome");
		if(outcome != "reverse" && outcome != "keep")
			throw Exception("outcome: reverse or keep");
		// An ID's suspension (10d): lifted
		const ss_ lid = jstr(a, "listing");
		if(outcome == "reverse" && lid.compare(0, 3, "id:") == 0){
			json::Value id = load("ids", lid.substr(3));
			if(id.is_object()){
				id.set("suspended_until", (int64_t)0);
				put("ids", lid.substr(3), id);
			}
			audit(by, lid, "restore", "appeal", jstr(q, "text"), false);
		}
		if(outcome == "reverse"){
			json::Value l = load("listings", jstr(a, "listing"));
			if(l.is_object()){
				l.set("status", "active");
				l.set("status_until", (int64_t)0);
				l.del_key("relabel");
				put("listings", jstr(l, "id"), l);
				store("bans")->remove("listing:"+jstr(l, "id"));
				audit(by, jstr(l, "id"), "restore", "appeal", jstr(q, "text"),
						false);
				statement(l, "restored", "appeal", jstr(q, "text"), by);
			}
		}
		a.set("state", "decided");
		a.set("outcome", outcome);
		a.set("decided_by", by);
		a.set("answer", jstr(q, "text"));
		put("appeals", jstr(a, "id"), a);
		return json::Value(true);
	}

	// The key that made a report becomes a trusted flagger's ([STARPORT]
	// 6), and nobody had to see its hash
	json::Value cmd_trust_reporter(const json::Value &q)
	{
		const json::Value rep = load("reports", jstr(q, "report"));
		const ss_ h = jstr(rep, "key");
		if(h.empty())
			throw Exception("no such report, or it was made without a key");
		if(trusted(h))
			return json::Value(false);
		json::Value next = m_settings.deepcopy();
		json::Value t = setting("trusted_flaggers").deepcopy();
		if(!t.is_array())
			t = json::array();
		t.append(h);
		next.set("trusted_flaggers", t);
		m_settings = next;
		put("settings", "settings", m_settings);
		return json::Value(true);
	}

	json::Value cmd_set_settings(const json::Value &q)
	{
		const json::Value &s = q.get("settings");
		if(!s.is_object())
			throw Exception("settings: an object");
		json::Value next = m_settings.deepcopy();
		for(json::Iterator it(s); it.valid(); it.next()){
			const ss_ k = it.key();
			if(default_settings().get(k).is_undefined())
				throw Exception("no such setting: "+k);
			next.set(k, it.value());
		}
		m_settings = next;
		put("settings", "settings", m_settings);
		return m_settings;
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
