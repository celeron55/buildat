// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// **Aitta** ([AITTA_MVP], doc/plan/aitta_plan.md): a registry of buildat
// apps, as an app. An author joins it (builtin/accounts: a local account
// or a Starport ID, as the server's admin set up its logins) and binds an
// author name to their key; `bin/buildat aitta publish` uploads a signed
// release; Aitta checks it and lists it. Everything listed is unreviewed.
// The admin can delist.
//
// The HTTP API, under /api/aitta/ on the server's port, JSON out, a
// refusal {"ok": false, "error": ...} with status 200:
//   GET  list                       the listed releases
//   GET  release?id=author/name/version  one, with its changelog's text
//                                   ([PACKAGE_SUBJECT]: what a Hearth
//                                   posts as the release's thread)
//   GET  archive/<sha256>.zip|.sig  a release's two files
//   POST upload_begin?size=N        body: the release's .sig. Its key must
//                                   be bound to an author, and the
//                                   signature good for the hash it names.
//   POST upload_part?sha256=&offset=  body: the next bytes, 60000 at most
//   POST upload_end?sha256=         the checks, and the listing
// And a browser's pages ([FRONT_PAGES]), the web client at /app:
//   GET  /                          each package's latest release
//   GET  /p/<author>/<name>         a package's listed releases
//   GET  /brand/<file>              the pages' font and logo
// In the app, "ai:req" carries a JSON {id, cmd, ...} from a joined client
// and "ai:res" the answer {id, ok, result | error}.
//
// The records are in the save "aitta": stores authors (author -> its key
// and account), keys (key -> author), owners (account -> author),
// releases ("author/name/version" -> the manifest's fields, sha256, size,
// key, time, delisted), changelogs (the same key -> {text}), settings. The archives are files, by hash, in
// <user>/apps/<app>/archives.
#include "core/log.h"
#include "core/json.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/sha256.h"
#include "interface/aitta.h"
#include "interface/zip.h"
#include "interface/bignum.h"
#include "interface/web_brand.h"
#include "client_file/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "accounts/api.h"
#include <ctime>
#include <map>
#include <set>
#include <algorithm>
#include <fstream>
#include <sstream>
#define MODULE "main"

using interface::Event;

static int64_t now_s(){ return (int64_t)time(nullptr); }

static ss_ jstr(const json::Value &v, const char *k)
{
	const json::Value &x = v.get(k);
	return x.is_string() ? x.as_string() : "";
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
			return part.substr(eq + 1); // simplified: hex, digits and a release id here
		at = amp + 1;
	}
	return "";
}

static bool is_hex(const ss_ &s, size_t len)
{
	if(s.size() != len)
		return false;
	for(char c : s)
		if(!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
			return false;
	return true;
}

// An author name: what a manifest's "author" may be
static bool plain_name(const ss_ &s)
{
	if(s.empty() || s.size() > 40)
		return false;
	for(char c : s)
		if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
			return false;
	return true;
}

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	std::ostringstream os;
	os<<f.rdbuf();
	return os.str();
}

static bool write_file(const ss_ &path, const ss_ &data)
{
	std::ofstream f(path, std::ios::binary);
	f<<data;
	return f.good();
}

// The licences the official instance takes ([AITTA] decision 2): free
// ones. An instance changes the list in its settings.
static json::Value default_settings()
{
	json::Value s = json::object();
	json::Value l = json::array();
	for(const char *n : {"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause",
			"ISC", "Zlib", "MPL-2.0", "GPL-2.0", "GPL-3.0", "LGPL-2.1",
			"LGPL-3.0", "AGPL-3.0", "Unlicense", "CC0-1.0", "CC-BY-3.0",
			"CC-BY-4.0", "CC-BY-SA-3.0", "CC-BY-SA-4.0"})
		l.append(n);
	s.set("licences", l);
	s.set("max_size", (int64_t)50 * 1000 * 1000);
	// Seconds before a package's next release is listed (http_list)
	s.set("update_delay", (int64_t)0);
	// [FRONT_PAGES]: seconds a release is listed before the page at /
	// shows it, so it can be delisted first
	s.set("page_delay", (int64_t)3600);
	return s;
}

struct Upload {
	json::Value sig;
	ss_ author;
	size_t size = 0;
	ss_ data;
	int64_t started = 0;
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	storage::Save *m_save = nullptr;
	json::Value m_settings;
	ss_ m_archives;
	ss_ m_tmp;
	sm_<ss_, Upload> m_uploads; // by sha256

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("network:packet_received/ai:req"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:http_request", on_http, network::HttpRequest)
		EVENT_TYPEN("network:packet_received/ai:req", on_req, network::Packet)
	}

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
	ss_ get(const char *store_name, const ss_ &key)
	{
		ss_ v;
		store(store_name)->get(key, v);
		return v;
	}

	void on_start()
	{
		// One user's clients at once, as in floorplanner
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_multiple_logins(true);
		});
		storage::access(m_server, [&](storage::Interface *s){
			m_save = s->open("aitta");
			if(!m_save)
				m_save = s->create("aitta");
		});
		if(!m_save)
			throw Exception("aitta: cannot open or create the save");
		m_settings = load("settings", "settings");
		if(!m_settings.is_object()){
			m_settings = default_settings();
			put("settings", "settings", m_settings);
		}
		const interface::ServerConfig &c = m_server->get_config();
		const ss_ app = m_server->get_app_id();
		m_archives = c.get<ss_>("user_path")+"/apps/"+app+"/archives";
		m_tmp = c.get<ss_>("cache_path")+"/apps/"+app+"/tmp";
		interface::fs::create_directories(m_archives);
		interface::fs::create_directories(m_tmp);
		// [FRONT_PAGES]: a browser's pages; the web client is at /app
		network::access(m_server, [&](network::Interface *iface){
			iface->claim_http_path("/");
			iface->claim_http_path("/p/");
			iface->claim_http_path("/brand/");
		});
		log_i(MODULE, "Aitta: %zu releases", store("releases")->list("").size());
	}

	// -----------------------------------------------------------------------
	// The HTTP API

	void respond(const network::HttpRequest &r, int status,
			const ss_ &type, const ss_ &body)
	{
		// Any page may read it: no cookies, and the web client fetches the
		// list, .sig and .zip from its own origin ([WEB_ID_TRUST] (c))
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, status, type, body,
					"Access-Control-Allow-Origin: *\r\n");
		});
	}
	void respond(const network::HttpRequest &r, const json::Value &v)
	{
		respond(r, 200, "application/json", v.stringify());
	}
	void refuse(const network::HttpRequest &r, const ss_ &why)
	{
		json::Value v = json::object();
		v.set("ok", false);
		v.set("error", why);
		respond(r, v);
	}
	void ok(const network::HttpRequest &r, const ss_ &what = "")
	{
		json::Value v = json::object();
		v.set("ok", true);
		if(!what.empty())
			v.set("result", what);
		respond(r, v);
	}

	void on_http(const network::HttpRequest &r)
	{
		const ss_ base = "/api/aitta/";
		if(r.path == "/" || r.path.compare(0, 3, "/p/") == 0 ||
				r.path.compare(0, 7, "/brand/") == 0)
			return html_page(r);
		if(r.path.compare(0, base.size(), base) != 0)
			return;
		if(!m_save)
			return refuse(r, "Aitta is not ready");
		const ss_ call = r.path.substr(base.size());
		try {
			if(call == "list")
				return http_list(r);
			if(call == "release")
				return http_release(r);
			if(call.compare(0, 8, "archive/") == 0)
				return http_archive(r, call.substr(8));
			if(r.method != "POST")
				return refuse(r, "no such call");
			if(call == "upload_begin")
				return http_upload_begin(r);
			if(call == "upload_part")
				return http_upload_part(r);
			if(call == "upload_end")
				return http_upload_end(r);
		} catch(std::exception &e){
			return refuse(r, e.what());
		}
		refuse(r, "no such call");
	}

	json::Value releases(bool with_delisted)
	{
		json::Value list = json::array();
		for(const ss_ &k : store("releases")->list("")){
			json::Value rel = load("releases", k);
			if(!with_delisted && rel.get("delisted").is_true())
				continue;
			list.append(rel);
		}
		return list;
	}

	// A release is listed once it is "update_delay" seconds old (the
	// instance's setting, 0 if not set), so a compromised key's release
	// can be reported and delisted before it reaches everybody. A
	// package's first listed release is listed at once: it updates nothing.
	void http_list(const network::HttpRequest &r)
	{
		json::Value v = json::object();
		v.set("ok", true);
		v.set("releases", listed_releases());
		respond(r, v);
	}

	json::Value listed_releases()
	{
		const json::Value &d = m_settings.get("update_delay");
		const int64_t delay = d.is_number() ? (int64_t)d.as_number() : 0;
		const json::Value all = releases(false);
		auto pkg = [&](unsigned i){
			return jstr(all.at(i), "author")+"/"+jstr(all.at(i), "name");
		};
		auto time = [&](unsigned i){
			return (int64_t)all.at(i).get("time").as_number();
		};
		std::map<ss_, unsigned> first;
		for(unsigned i = 0; i < all.size(); i++)
			if(!first.count(pkg(i)) || time(i) < time(first[pkg(i)]))
				first[pkg(i)] = i;
		json::Value list = json::array();
		for(unsigned i = 0; i < all.size(); i++)
			if(first[pkg(i)] == i || now_s() - time(i) >= delay)
				list.append(all.at(i));
		return list;
	}

	// -----------------------------------------------------------------------
	// [FRONT_PAGES]: what a browser is shown, read-only, from what list
	// hands out: / lists each package's latest release, /p/<author>/<name>
	// a package's every listed one

	static ss_ date(int64_t t)
	{
		const time_t tt = (time_t)t;
		struct tm tm;
		gmtime_r(&tt, &tm);
		char b[16];
		strftime(b, sizeof b, "%Y-%m-%d", &tm);
		return b;
	}

	static ss_ release_box(const json::Value &rel, bool latest)
	{
		using interface::web_brand::html;
		const ss_ pkg = jstr(rel, "author")+"/"+jstr(rel, "name");
		const ss_ sha = jstr(rel, "sha256");
		const int64_t size = (int64_t)rel.get("size").as_number();
		ss_ b = "<div class=\"box\"><b>"+(latest ? "<a href=\"/p/"+html(pkg)+
				"\">"+html(pkg)+"</a>" : html(pkg))+"</b> "+
				html(jstr(rel, "version"))+" <span class=\"meta\">"+
				html(jstr(rel, "kind"))+", for "+html(jstr(rel, "audience"))+
				", "+date((int64_t)rel.get("time")
				.as_number())+", "+(size < 1000 ? itos(size)+" bytes" : size < 1000000 ?
				itos(size / 1000)+" kB" :
				itos(size / 1000000)+" MB")+", unreviewed</span>";
		if(!jstr(rel, "description").empty())
			b += "<br>"+html(jstr(rel, "description"));
		b += "<br><span class=\"meta\">Licence: code "+
				html(jstr(rel, "license_code"))+", media "+
				html(jstr(rel, "license_media"))+"<br>Signed by the key <code>"+
				html(jstr(rel, "key"))+"</code></span><br>"
				"<a href=\"/api/aitta/archive/"+html(sha)+".zip\">.zip</a> "
				"<a href=\"/api/aitta/archive/"+html(sha)+".sig\">.sig</a>";
		// Its discussion at its home Hearth, as the client's "Discuss"
		const ss_ home = jstr(rel, "home_hearth");
		if(home.compare(0, 8, "https://") == 0 ||
				home.compare(0, 7, "http://") == 0)
			b += " <a href=\""+html(home.back() == '/' ? home.substr(0,
					home.size() - 1) : home)+"/p/"+html(pkg)+"\" "
					"rel=\"nofollow noopener\">Discuss</a>";
		return b+"</div>\n";
	}

	void html_page(const network::HttpRequest &r)
	{
		auto send = [&](int status, const ss_ &type, const ss_ &body,
				const ss_ &headers = ""){
			network::access(m_server, [&](network::Interface *iface){
				iface->http_respond(r.peer, status, type, body, headers);
			});
		};
		ss_ data, type;
		if(r.path.compare(0, 7, "/brand/") == 0){
			if(interface::web_brand::file(m_server->get_config().get<ss_>(
					"share_path"), r.path.substr(7), data, type))
				return send(200, type, data, "Cache-Control: max-age=86400\r\n");
			return send(404, "text/plain", "Not found\n");
		}
		const ss_ html_type = "text/html; charset=utf-8";
		if(!m_save)
			return send(503, html_type, interface::web_brand::page("Aitta",
					"Aitta", "<p>Starting.</p>"));
		const json::Value all = listed_releases();
		// Only what suits a teen, listed "page_delay" seconds (an older
		// save has none: an hour), with no way to show more
		const json::Value &pd = m_settings.get("page_delay");
		const int64_t delay = pd.is_number() ? (int64_t)pd.as_number() : 3600;
		sv_<json::Value> rels;
		for(unsigned i = 0; i < all.size(); i++){
			const json::Value &rel = all.at(i);
			const ss_ a = jstr(rel, "audience");
			if((a == "everyone" || a == "teen") &&
					now_s() - (int64_t)rel.get("time").as_number() >= delay)
				rels.push_back(rel);
		}
		// Newest first; a package's latest is its first
		std::sort(rels.begin(), rels.end(), [](const json::Value &a,
				const json::Value &b){
			return a.get("time").as_number() > b.get("time").as_number();
		});
		auto pkg = [](const json::Value &rel){
			return jstr(rel, "author")+"/"+jstr(rel, "name");
		};
		using interface::web_brand::html;
		ss_ c;
		if(r.path.compare(0, 3, "/p/") == 0){
			const ss_ want = r.path.substr(3);
			for(const json::Value &rel : rels)
				if(pkg(rel) == want)
					c += release_box(rel, false);
			if(c.empty())
				return send(404, html_type, interface::web_brand::page(
						"Not found", "Aitta", "<p>No package of that name is "
						"listed here. <a href=\"/\">The list</a>.</p>"));
			return send(200, html_type, interface::web_brand::page(want+
					" - Aitta", "Aitta", "<h1>"+html(want)+"</h1><p class=\""
					"meta\">Every listed release, the newest first.</p>\n"+c));
		}
		std::set<ss_> seen;
		for(const json::Value &rel : rels)
			if(seen.insert(pkg(rel)).second)
				c += release_box(rel, true);
		ss_ body = "<h1>Aitta</h1><p>A registry of Buildat apps and "
				"extensions: their authors sign each release with their own "
				"key, and Aitta lists it. Nothing here is reviewed. An app "
				"runs in the server's box, where it reaches only its own "
				"saves.</p><p>To install one, open the Buildat client and "
				"pick <b>Apps from Aitta</b>; it checks the signature before "
				"it installs.</p>\n";
		body += c.empty() ? "<p>Nothing is published here yet.</p>\n" :
				"<h2>Packages</h2>\n"+c;
		send(200, html_type, interface::web_brand::page("Aitta", "Aitta",
				body));
	}

	void http_release(const network::HttpRequest &r)
	{
		const ss_ id = query_value(r.query, "id");
		const json::Value rel = load("releases", id);
		if(!rel.is_object() || rel.get("delisted").is_true())
			return refuse(r, "no such release");
		json::Value v = json::object();
		v.set("ok", true);
		v.set("release", rel);
		const json::Value c = load("changelogs", id);
		v.set("changelog", c.is_object() ? jstr(c, "text") : ss_());
		respond(r, v);
	}

	// A delisted release's files are not served either
	bool listed_hash(const ss_ &sha)
	{
		for(const ss_ &k : store("releases")->list("")){
			json::Value rel = load("releases", k);
			if(jstr(rel, "sha256") == sha)
				return !rel.get("delisted").is_true();
		}
		return false;
	}

	void http_archive(const network::HttpRequest &r, const ss_ &file)
	{
		const size_t dot = file.find('.');
		const ss_ sha = file.substr(0, dot), ext = dot == ss_::npos ? "" :
				file.substr(dot);
		if(!is_hex(sha, 64) || (ext != ".zip" && ext != ".sig") ||
				!listed_hash(sha))
			return respond(r, 404, "text/plain", "Not found\n");
		respond(r, 200, ext == ".zip" ? "application/zip" : "application/json",
				read_file(m_archives+"/"+sha+ext));
	}

	void http_upload_begin(const network::HttpRequest &r)
	{
		const json::Value sig = json::load_string(r.body.c_str());
		const ss_ sha = jstr(sig, "sha256"), key = jstr(sig, "key");
		const int64_t size = atoll(query_value(r.query, "size").c_str());
		if(jstr(sig, "format") != "aitta-release-1" || !is_hex(sha, 64))
			return refuse(r, "the body is not a release's .sig");
		const ss_ author = get("keys", key);
		if(author.empty())
			return refuse(r, "this key is not bound to an author here: "
					"join Aitta and bind it first");
		if(!interface::aitta::verify_hash(key, sha, jstr(sig, "signature")))
			return refuse(r, "the signature does not match the hash");
		const json::Value &max = m_settings.get("max_size");
		if(size <= 0 || (max.is_number() && size > max.as_number()))
			return refuse(r, "the archive's size is 1 byte to "+
					itos((int64_t)max.as_number())+" bytes here");
		if(interface::fs::path_exists(m_archives+"/"+sha+".zip"))
			return refuse(r, "this archive is here already");
		// simplified: at most four uploads at once and ten minutes each,
		// in memory; an upload server's worth of resumable uploads is the
		// upgrade, when releases grow past what one request a piece carries
		for(auto it = m_uploads.begin(); it != m_uploads.end();){
			if(now_s() - it->second.started > 600)
				it = m_uploads.erase(it);
			else
				it++;
		}
		if(m_uploads.size() >= 4 && !m_uploads.count(sha))
			return refuse(r, "busy: try again in a while");
		Upload &u = m_uploads[sha];
		u = Upload();
		u.sig = sig;
		u.author = author;
		u.size = (size_t)size;
		u.started = now_s();
		ok(r);
	}

	void http_upload_part(const network::HttpRequest &r)
	{
		auto it = m_uploads.find(query_value(r.query, "sha256"));
		if(it == m_uploads.end())
			return refuse(r, "no upload of that hash: upload_begin first");
		Upload &u = it->second;
		if((size_t)atoll(query_value(r.query, "offset").c_str()) != u.data.size())
			return refuse(r, "the next piece is at offset "+
					itos((int64_t)u.data.size()));
		if(u.data.size() + r.body.size() > u.size)
			return refuse(r, "more than the size given");
		u.data += r.body;
		ok(r);
	}

	void http_upload_end(const network::HttpRequest &r)
	{
		const ss_ sha = query_value(r.query, "sha256");
		auto it = m_uploads.find(sha);
		if(it == m_uploads.end())
			return refuse(r, "no upload of that hash");
		Upload u = it->second;
		m_uploads.erase(it);
		if(u.data.size() != u.size)
			return refuse(r, "the archive is not whole");
		if(interface::sha256::hex(interface::sha256::calculate(u.data)) != sha)
			return refuse(r, "the archive is not the one the .sig is for");
		// The manifest, out of the archive
		// Beside where it goes, so the move is a rename; unpacked under
		// the cache
		const ss_ zip = m_archives+"/"+sha+".part";
		const ss_ dir = m_tmp+"/"+sha;
		if(!write_file(zip, u.data))
			return refuse(r, "cannot store the archive");
		json::Value m;
		try {
			interface::fs::create_directories(dir);
			interface::zip_extract(zip, dir);
			m = json::load_string(read_file(dir+"/meta.json").c_str());
		} catch(std::exception &e){
			interface::fs::remove_all(dir);
			interface::fs::remove_all(zip);
			return refuse(r, ss_("the archive: ")+e.what());
		}
		const bool changelog_there = jstr(m, "changelog").empty() ||
				interface::fs::path_exists(dir+"/"+jstr(m, "changelog"));
		// Its text kept for the release's thread ([PACKAGE_SUBJECT]), the
		// first 64 KiB: a Hearth message holds less than that anyway
		ss_ changelog;
		if(!jstr(m, "changelog").empty() && changelog_there)
			changelog = read_file(dir+"/"+jstr(m, "changelog")).substr(0,
					64 * 1024);
		interface::fs::remove_all(dir);
		auto drop = [&](const ss_ &why){
			interface::fs::remove_all(zip);
			refuse(r, why);
		};
		const ss_ why = interface::aitta::check_manifest(m);
		if(!why.empty())
			return drop("meta.json: "+why);
		if(!changelog_there)
			return drop("meta.json: \"changelog\": "+jstr(m, "changelog")+
					" is not in the archive");
		if(jstr(m, "author") != u.author)
			return drop("the key is bound to the author \""+u.author+
					"\", and the manifest says \""+jstr(m, "author")+"\"");
		for(const char *k : {"license_code", "license_media"})
			if(!licence_ok(jstr(m, k)))
				return drop(ss_(k)+" \""+jstr(m, k)+"\" is not one this "
						"instance takes");
		const ss_ id = jstr(m, "author")+"/"+jstr(m, "name")+"/"+
				jstr(m, "version");
		if(!load("releases", id).is_undefined())
			return drop(id+" is here already");
		if(!interface::fs::rename(zip, m_archives+"/"+sha+".zip") ||
				!write_file(m_archives+"/"+sha+".sig", u.sig.stringify()+"\n"))
			return drop("cannot store the archive");
		json::Value rel = json::object();
		for(const char *k : {"author", "name", "version", "description",
				"license_code", "license_media", "home_hearth", "changelog",
				"audience"})
			rel.set(k, jstr(m, k));
		rel.set("engine_api", m.get("engine_api"));
		rel.set("kind", interface::aitta::kind_of(m));
		rel.set("sha256", sha);
		rel.set("size", (int64_t)u.size);
		rel.set("key", jstr(u.sig, "key"));
		rel.set("time", now_s());
		rel.set("delisted", false);
		put("releases", id, rel);
		if(!changelog.empty()){
			json::Value c = json::object();
			c.set("text", changelog);
			put("changelogs", id, c);
		}
		log_i(MODULE, "Listed %s (%zu bytes) from %s", cs(id), u.size,
				cs(r.address));
		ok(r, id);
	}

	// "GPL-3.0-only", "GPL-3.0-or-later" and "GPL-3.0+" are GPL-3.0's
	bool licence_ok(ss_ l)
	{
		for(const char *suffix : {"-only", "-or-later", "+"}){
			const ss_ s = suffix;
			if(l.size() > s.size() && l.compare(l.size() - s.size(), s.size(), s) == 0)
				l = l.substr(0, l.size() - s.size());
		}
		const json::Value &list = m_settings.get("licences");
		for(unsigned i = 0; list.is_array() && i < list.size(); i++)
			if(list.at(i).is_string() && list.at(i).as_string() == l)
				return true;
		return false;
	}

	// -----------------------------------------------------------------------
	// The app: an author binds a key; the admin delists and sets settings

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
		if(!m_save)
			error = "Aitta is not ready";
		else if(name.empty())
			error = "join first";
		else {
			try {
				result = handle(name, admin, jstr(q, "cmd"), q);
			} catch(std::exception &e){
				error = e.what();
			}
		}
		res.set("ok", error.empty());
		if(error.empty())
			res.set("result", result);
		else
			res.set("error", error);
		network::access(m_server, [&](network::Interface *iface){
			iface->send(packet.sender, "ai:res", res.stringify());
		});
	}

	json::Value handle(const ss_ &name, bool admin, const ss_ &cmd,
			const json::Value &q)
	{
		if(cmd == "me"){
			json::Value v = json::object();
			v.set("account", name);
			v.set("admin", admin);
			const ss_ author = get("owners", name);
			v.set("author", author);
			v.set("key", author.empty() ? "" : jstr(load("authors", author), "key"));
			v.set("releases", releases(admin));
			return v;
		}
		if(cmd == "bind"){
			const ss_ author = jstr(q, "author"), key = jstr(q, "key");
			if(!get("owners", name).empty())
				throw Exception("this account has its author name already");
			if(!plain_name(author))
				throw Exception("an author name is 1 to 40 of a-z, 0-9 and _");
			if(!get("authors", author).empty())
				throw Exception("the author name \""+author+"\" is taken");
			// An uncompressed P-256 point: 04, then x and y
			if(!is_hex(key, 130) || key.compare(0, 2, "04") != 0)
				throw Exception("the key is what `bin/buildat aitta keygen` "
						"printed: 130 hex digits");
			if(!get("keys", key).empty())
				throw Exception("this key is bound already");
			json::Value a = json::object();
			a.set("author", author);
			a.set("key", key);
			a.set("account", name);
			a.set("time", now_s());
			put("authors", author, a);
			store("keys")->set(key, author);
			store("owners")->set(name, author);
			log_i(MODULE, "%s bound the author name %s to a key", cs(name),
					cs(author));
			return json::Value(true);
		}
		if(cmd == "delist" || cmd == "relist"){
			if(!admin)
				throw Exception("only the admin delists");
			const ss_ id = jstr(q, "release");
			json::Value rel = load("releases", id);
			if(!rel.is_object())
				throw Exception("no release "+id);
			rel.set("delisted", cmd == "delist");
			put("releases", id, rel);
			log_i(MODULE, "%s: %s %s", cs(name), cs(cmd), cs(id));
			return json::Value(true);
		}
		// Settings by name, each one default_settings has
		if(cmd == "set_settings"){
			if(!admin)
				throw Exception("only the admin sets settings");
			const json::Value &s = q.get("settings");
			if(!s.is_object())
				throw Exception("settings: an object");
			json::Value next = m_settings.deepcopy();
			for(json::Iterator it(s); it.valid(); it.next()){
				if(default_settings().get(it.key()).is_undefined())
					throw Exception("no such setting: "+it.key());
				next.set(it.key(), it.value());
			}
			m_settings = next;
			put("settings", "settings", m_settings);
			log_i(MODULE, "%s set %s", cs(name), cs(s.stringify()));
			return m_settings;
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
