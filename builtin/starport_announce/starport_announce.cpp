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
#include "interface/os.h"
#include "interface/http.h"
#include "interface/sha256.h"
#include "network/api.h"
#include "starport_announce/api.h"
#include "accounts/api.h"
#include <fstream>
#include <sstream>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <set>
#include <memory>
#include "interface/tcpsocket.h"
#ifdef _WIN32
	#include <winsock2.h>
#else
	#include <sys/socket.h>
#endif
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

// base64url without padding, as a Starport's token has it
static ss_ unbase64url(const ss_ &in)
{
	ss_ out;
	uint32_t buf = 0;
	int bits = 0;
	for(char c : in){
		int v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ?
				c - 'a' + 26 : c >= '0' && c <= '9' ? c - '0' + 52 :
				c == '-' ? 62 : c == '_' ? 63 : -1;
		if(v < 0)
			return "";
		buf = (buf << 6) | v;
		bits += 6;
		if(bits >= 8){
			bits -= 8;
			out += (char)((buf >> bits) & 0xff);
		}
	}
	return out;
}

// **A relay to a Starport** ([STARPORT] 10c): the web client has no HTTPS of
// its own, so its server carries its TLS connection to a Starport, as bytes
// it cannot read, to the Starports this server announces to only (anything
// else would make every server an open proxy)
struct Relay
{
	network::PeerInfo::Id peer = 0;
	std::unique_ptr<interface::TCPSocket> sock;
	std::thread thread;
	std::mutex mutex;
	ss_ inbox;    // from the Starport, for the client
	ss_ pending;  // from the client, before the connection is up
	bool connected = false;
	bool closed = false;
	bool stop = false;
	ss_ why;
	size_t total = 0;
	int64_t last_us = 0;
};
static const size_t RELAY_MAX_BYTES = 4 * 1024 * 1024;
static const int64_t RELAY_IDLE_US = 30 * 1000000LL;

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	ss_ m_dir;
	json::Value m_config;
	std::mutex m_mutex;
	// By the Starport's url
	sm_<ss_, Listing> m_listings;
	// 10d: the identities of the blocklists this server subscribes to, by
	// the Starport's url, as its last announce's answer said them
	sm_<ss_, std::set<ss_>> m_blocked;
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
		// A thread left joinable ends the process
		while(!m_relays.empty())
			end_relay(m_relays.begin()->first);
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
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *n : {"starport:relay_open", "starport:relay_send",
				"starport:relay_close"})
			m_server->sub_event(this,
					Event::t(ss_("network:packet_received/")+n));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:tick", on_tick)
		EVENT_TYPEN("network:http_request", on_http_request,
				network::HttpRequest)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("network:packet_received/starport:relay_open",
				on_relay_open, network::Packet)
		EVENT_TYPEN("network:packet_received/starport:relay_send",
				on_relay_send, network::Packet)
		EVENT_TYPEN("network:packet_received/starport:relay_close",
				on_relay_close, network::Packet)
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
		m_start_announcing = true;
	}

	// The first announce waits for the first tick: every module has
	// started by then, builtin/accounts and its reported bans (10d) too
	bool m_start_announcing = false;
	// -- The relay (10c)

	sm_<network::PeerInfo::Id, std::unique_ptr<Relay>> m_relays;

	void relay_send_packet(network::PeerInfo::Id peer, const ss_ &name,
			const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *iface){
			iface->send(peer, name, data);
		});
	}

	void end_relay(network::PeerInfo::Id peer)
	{
		auto it = m_relays.find(peer);
		if(it == m_relays.end())
			return;
		Relay *r = it->second.get();
		{
			std::lock_guard<std::mutex> lock(r->mutex);
			r->stop = true;
		}
		if(r->thread.joinable())
			r->thread.join();
		m_relays.erase(it);
	}

	void on_client_disconnected(const network::OldClient &c)
	{
		end_relay(c.info.id);
	}

	void on_relay_open(const network::Packet &p)
	{
		end_relay(p.sender);
		const ss_ url = p.data;
		bool allowed = false;
		const json::Value &urls = m_config.get("starports");
		for(unsigned i = 0; urls.is_array() && i < urls.size(); i++)
			allowed |= urls.at(i).is_string() && urls.at(i).as_string() == url;
		if(!allowed){
			relay_send_packet(p.sender, "starport:relay_closed",
					"not a Starport this server is on");
			return;
		}
		const size_t s = url.find("://");
		const ss_ scheme = url.substr(0, s);
		ss_ hostport = url.substr(s + 3);
		hostport = hostport.substr(0, hostport.find('/'));
		ss_ host = hostport, port = scheme == "https" ? "443" : "80";
		const size_t colon = hostport.rfind(':');
		if(colon != ss_::npos && hostport.find(']') == ss_::npos){
			host = hostport.substr(0, colon);
			port = hostport.substr(colon + 1);
		}
		std::unique_ptr<Relay> r(new Relay());
		r->peer = p.sender;
		r->last_us = interface::os::time_us();
		Relay *rp = r.get();
		r->thread = std::thread([rp, host, port](){
			std::unique_ptr<interface::TCPSocket> sock(
					interface::createTCPSocket());
			if(!sock->connect_fd(host, port)){
				std::lock_guard<std::mutex> lock(rp->mutex);
				rp->closed = true;
				rp->why = "could not connect to "+host+":"+port;
				return;
			}
			{
				std::lock_guard<std::mutex> lock(rp->mutex);
				rp->sock = std::move(sock);
				rp->connected = true;
				if(!rp->pending.empty())
					rp->sock->send_fd(rp->pending);
				rp->pending.clear();
			}
			for(;;){
				{
					std::lock_guard<std::mutex> lock(rp->mutex);
					if(rp->stop)
						break;
				}
				if(!rp->sock->wait_data(100000))
					continue;
				char buf[16384];
				const int n = (int)recv(rp->sock->fd(), buf, sizeof buf, 0);
				std::lock_guard<std::mutex> lock(rp->mutex);
				if(n <= 0){
					rp->closed = true;
					rp->why = "closed by the Starport";
					break;
				}
				rp->inbox.append(buf, n);
				rp->total += n;
				if(rp->total > RELAY_MAX_BYTES){
					rp->closed = true;
					rp->why = "too much";
					break;
				}
			}
			std::lock_guard<std::mutex> lock(rp->mutex);
			if(rp->sock)
				rp->sock->close_fd();
		});
		m_relays[p.sender] = std::move(r);
	}

	void on_relay_send(const network::Packet &p)
	{
		auto it = m_relays.find(p.sender);
		if(it == m_relays.end())
			return;
		Relay *r = it->second.get();
		std::lock_guard<std::mutex> lock(r->mutex);
		r->total += p.data.size();
		r->last_us = interface::os::time_us();
		if(r->connected && r->sock)
			r->sock->send_fd(p.data);
		else
			r->pending += p.data;
	}

	void on_relay_close(const network::Packet &p)
	{
		end_relay(p.sender);
	}

	void flush_relays()
	{
		sv_<network::PeerInfo::Id> done;
		const int64_t now = interface::os::time_us();
		for(auto &pair : m_relays){
			Relay *r = pair.second.get();
			ss_ data, why;
			bool closed;
			{
				std::lock_guard<std::mutex> lock(r->mutex);
				data.swap(r->inbox);
				closed = r->closed;
				why = r->why;
				if(!data.empty())
					r->last_us = now;
				if(!closed && now - r->last_us > RELAY_IDLE_US){
					closed = true;
					why = "idle";
				}
			}
			if(!data.empty())
				relay_send_packet(r->peer, "starport:relay_data", data);
			if(closed){
				relay_send_packet(r->peer, "starport:relay_closed", why);
				done.push_back(pair.first);
			}
		}
		for(auto peer : done)
			end_relay(peer);
	}

	void on_tick()
	{
		flush_relays();
		if(!m_start_announcing)
			return;
		m_start_announcing = false;
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
		// 10d: the whole of the bans reported to this Starport, so a ban
		// taken back is gone from it too
		const ss_ host = host_of(url);
		json::Value bans = json::array();
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *a){
				for(const ss_ &line : a->reported_bans()){
					const size_t p1 = line.find('|');
					const size_t p2 = line.find('|', p1 + 1);
					if(p2 == ss_::npos || line.substr(0, p1) != host)
						continue;
					json::Value b = json::object();
					b.set("sub", line.substr(p1 + 1, p2 - p1 - 1));
					b.set("reason", line.substr(p2 + 1));
					bans.append(b);
				}
			});
		body.set("bans", bans);
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
		if(v.get("blocked").is_array()){
			std::set<ss_> blocked;
			for(unsigned i = 0; i < v.get("blocked").size(); i++)
				if(v.get("blocked").at(i).is_string())
					blocked.insert(v.get("blocked").at(i).as_string());
			std::lock_guard<std::mutex> lock(m_mutex);
			m_blocked[url] = blocked;
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

	// -- [STARPORT] 10c

	// The host of a Starport's url
	static ss_ host_of(const ss_ &url)
	{
		const size_t s = url.find("://");
		ss_ host = s == ss_::npos ? url : url.substr(s + 3);
		return host.substr(0, host.find_first_of(":/"));
	}

	bool accepts_ids()
	{
		const ss_ login = m_config.get("login").is_string() ?
				m_config.get("login").as_string() : "local";
		return login == "starport" || login == "both";
	}

	ss_ verify_id_token(const ss_ &token, IdLogin *out)
	{
		if(!accepts_ids())
			return "This server does not take Starport IDs";
		const size_t dot = token.find('.');
		if(dot == ss_::npos || token.size() > 2000)
			return "Not a Starport ID token";
		const ss_ payload = token.substr(0, dot);
		const ss_ sig = token.substr(dot + 1);
		ss_ host;
		ss_ listing;
		bool blocked = false;
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			for(auto &pair : m_listings){
				const ss_ want = interface::sha256::hex(
						interface::sha256::hmac(pair.second.secret, payload));
				if(want.size() == sig.size() && want == sig){
					host = pair.first;
					listing = pair.second.id;
				}
			}
		}
		if(host.empty())
			return "The token is not from a Starport this server is on";
		const json::Value p = json::load_string(unbase64url(payload).c_str());
		if(!p.is_object() || !p.get("sub").is_string() ||
				!p.get("name").is_string())
			return "A malformed token";
		if(p.get("listing").is_string() &&
				p.get("listing").as_string() != listing)
			return "The token is for another server";
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			blocked = m_blocked[host].count(p.get("sub").as_string()) > 0;
		}
		if(blocked)
			return "Banned by a blocklist this server follows";
		const json::Value &exp = p.get("exp");
		if(!exp.is_number() || exp.as_number() < (double)time(nullptr))
			return "The token has expired: log in to the Starport again";
		host = host_of(host);
		out->sub = p.get("sub").as_string();
		out->name = p.get("name").as_string();
		out->starport = host;
		out->adult = p.get("adult").is_true();
		return "";
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
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
