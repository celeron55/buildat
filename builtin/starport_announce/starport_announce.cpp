// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// **A server listed on Starports** ([STARPORT] 2, doc/plan/starport_plan.md):
// what an app that wants to be found depends on. Nothing is announced
// unless the server's admin wrote <user>/apps/<app>/starport.json, which
// names the Starports and says what the server is (the categories, [STARPORT]
// 3); then, to each, an announce at the start and every few minutes, and
// the answer to its challenge.
//
// - A listing is an id and a secret the Starport gives at the first
//   announce, kept in starport_state.json beside the config; later
//   announces carry them.
// - The challenge: the Starport asks /api/starport/challenge on this
//   server's own port (network:http_request) with a nonce, and the answer
//   is HMAC-SHA256(secret, nonce): the server at the address holds the
//   listing's secret.
// - The claim code, HMAC(secret, "claim"), cut short, is what the operator
//   takes to their Starport account to claim the listing ([STARPORT] 2a):
//   in the log and in starport_claim.txt, which only the server's admin
//   can read.
// simplified: a shared secret and HMAC, not a public key; Ed25519 when a
// library for it is in the tree. No stop announce: a Starport lets a
// listing go when its announces stop.
#include "core/log.h"
#include "core/json.h"
#include "core/version.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/http.h"
#include "interface/sha256.h"
#include "network/api.h"
#include <fstream>
#include <sstream>
#include <thread>
#include <mutex>
#include <condition_variable>
#define MODULE "starport_announce"

using interface::Event;

namespace starport_announce {

// How often a listing says it is still there; a Starport lets it go after
// it has missed a few
static const int ANNOUNCE_INTERVAL_S = 300;

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	if(!f.good())
		return "";
	std::ostringstream os;
	os<<f.rdbuf();
	return os.str();
}

static void write_file(const ss_ &path, const ss_ &data)
{
	std::ofstream f(path, std::ios::binary | std::ios::trunc);
	f<<data;
}

// "a=1&b=2" -> a value; percent-decoded, '+' a space
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

struct Listing {
	ss_ id;
	ss_ secret; // raw bytes, as the Starport gave them (hex in the file)
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	ss_ m_dir;
	json::Value m_config;
	std::mutex m_mutex;
	// By the Starport's url
	sm_<ss_, Listing> m_listings;
	std::thread m_thread;
	std::condition_variable m_wake;
	bool m_stop = false;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			m_stop = true;
		}
		m_wake.notify_all();
		if(m_thread.joinable())
			m_thread.join();
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:http_request"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:http_request", on_http_request,
				network::HttpRequest)
	}

	void on_start()
	{
		m_dir = m_server->get_config().get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id();
		const ss_ path = m_dir+"/starport.json";
		const ss_ text = read_file(path);
		if(text.empty()){
			log_v(MODULE, "No %s: not announced to any Starport", cs(path));
			return;
		}
		json::json_error_t err;
		m_config = json::load_string(text.c_str(), &err);
		if(!m_config.is_object() || !m_config.get("starports").is_array()){
			log_w(MODULE, "%s: not an object with \"starports\" (line %d: %s);"
					" not announced", cs(path), err.line, err.text);
			return;
		}
		load_state();
		log_i(MODULE, "Announcing to %u Starport(s)",
				m_config.get("starports").size());
		m_thread = std::thread([this](){ run(); });
	}

	void load_state()
	{
		const ss_ text = read_file(m_dir+"/starport_state.json");
		if(text.empty())
			return;
		const json::Value v = json::load_string(text.c_str());
		if(!v.is_object())
			return;
		for(json::Iterator it(v); it.valid(); it.next()){
			const json::Value &l = it.value();
			if(!l.get("id").is_string() || !l.get("secret").is_string())
				continue;
			Listing listing;
			listing.id = l.get("id").as_string();
			listing.secret = unhex(l.get("secret").as_string());
			m_listings[it.key()] = listing;
		}
	}

	static ss_ unhex(const ss_ &h)
	{
		ss_ out;
		for(size_t i = 0; i + 1 < h.size(); i += 2)
			out += (char)strtol(h.substr(i, 2).c_str(), nullptr, 16);
		return out;
	}

	// Under the lock
	void save_state()
	{
		json::Value v = json::object();
		ss_ claims;
		for(auto &pair : m_listings){
			json::Value l = json::object();
			l.set("id", pair.second.id);
			l.set("secret", interface::sha256::hex(pair.second.secret));
			v.set(pair.first, l);
			claims += pair.first+"  listing "+pair.second.id+"  claim code "+
					claim_code(pair.second)+"\n";
		}
		write_file(m_dir+"/starport_state.json", v.stringify());
		write_file(m_dir+"/starport_claim.txt",
				"# What an operator gives a Starport to claim this server's\n"
				"# listing on their account ([STARPORT] 2a). Keep it to the\n"
				"# server's admins: whoever has it can claim the listing.\n"+
				claims);
	}

	static ss_ claim_code(const Listing &l)
	{
		return interface::sha256::hex(
				interface::sha256::hmac(l.secret, "claim")).substr(0, 16);
	}

	void run()
	{
		for(;;){
			const json::Value &urls = m_config.get("starports");
			for(unsigned i = 0; i < urls.size(); i++){
				if(urls.at(i).is_string())
					announce(urls.at(i).as_string());
			}
			std::unique_lock<std::mutex> lock(m_mutex);
			m_wake.wait_for(lock, std::chrono::seconds(ANNOUNCE_INTERVAL_S),
					[this](){ return m_stop; });
			if(m_stop)
				return;
		}
	}

	size_t player_count()
	{
		size_t n = 0;
		network::access(m_server, [&](network::Interface *iface){
			n = iface->list_peers().size();
		});
		return n;
	}

	void announce(const ss_ &url)
	{
		json::Value body = json::object();
		// What the server says it is: the config as it is, less the list of
		// Starports, which is this server's business
		for(json::Iterator it(m_config); it.valid(); it.next()){
			if(it.key() != "starports")
				body.set(it.key(), it.value());
		}
		body.set("app", m_server->get_app_id());
		body.set("version", ss_(BUILDAT_VERSION));
		body.set("port", (int64_t)atoi(m_server->get_config().get<ss_>("network_port").c_str()));
		body.set("players", (int64_t)player_count());
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			auto it = m_listings.find(url);
			if(it != m_listings.end()){
				body.set("id", it->second.id);
				body.set("secret", interface::sha256::hex(it->second.secret));
			}
		}
		ss_ answer;
		try {
			answer = interface::http_post(url+"/api/announce", body.stringify());
		} catch(std::exception &e){
			log_w(MODULE, "Announce to %s: %s", cs(url), e.what());
			return;
		}
		const json::Value v = json::load_string(answer.c_str());
		if(!v.is_object() || !v.get("ok").is_true()){
			log_w(MODULE, "Announce to %s refused: %s", cs(url),
					v.is_object() && v.get("error").is_string() ?
					v.get("error").as_cstring() : cs(answer.substr(0, 200)));
			return;
		}
		if(v.get("id").is_string() && v.get("secret").is_string()){
			std::lock_guard<std::mutex> lock(m_mutex);
			Listing &l = m_listings[url];
			const bool fresh = l.id != v.get("id").as_string();
			l.id = v.get("id").as_string();
			l.secret = unhex(v.get("secret").as_string());
			save_state();
			if(fresh)
				log_i(MODULE, "Listed on %s as %s; the claim code for the "
						"operator's account is %s (also in %s)", cs(url),
						cs(l.id), cs(claim_code(l)),
						cs(m_dir+"/starport_claim.txt"));
		}
		log_v(MODULE, "Announced to %s: %s", cs(url),
				v.get("status").is_string() ? v.get("status").as_cstring() : "");
	}

	void on_http_request(const network::HttpRequest &r)
	{
		if(r.path != "/api/starport/challenge")
			return;
		const ss_ id = query_value(r.query, "listing");
		const ss_ nonce = query_value(r.query, "nonce");
		ss_ response;
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			for(auto &pair : m_listings){
				if(pair.second.id == id && !id.empty())
					response = interface::sha256::hex(
							interface::sha256::hmac(pair.second.secret, nonce));
			}
		}
		const int status = response.empty() || nonce.empty() ? 404 : 200;
		json::Value v = json::object();
		if(status == 200)
			v.set("response", response);
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, status, "application/json", v.stringify());
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_starport_announce(
			interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
