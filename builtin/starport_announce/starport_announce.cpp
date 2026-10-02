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
#include <algorithm>
#include <fstream>
#include <sstream>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <set>
#include <memory>
#include "interface/tcpsocket.h"
#ifdef _WIN32
	#include "ports/windows_sockets.h"
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
	// starport.json as last read, and its text; under m_mutex (the thread
	// announces from it)
	json::Value m_config;
	ss_ m_config_text;
	std::mutex m_mutex;
	// 10g: the Starports to delist from, for the thread; each Starport's
	// last answer and the blocklists it says this server follows
	sv_<ss_> m_delist;
	sm_<ss_, ss_> m_status;
	sm_<ss_, sv_<ss_>> m_subscribed;
	int64_t m_next_read_us = 0;
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
		// What a wrong default would send announces to the wrong port for
		if(normalize_url("host") != "http://host:29595" ||
				normalize_url("http://host/") != "http://host:29595" ||
				normalize_url("http://host:80") != "http://host:80" ||
				normalize_url("https://host") != "https://host" ||
				normalize_url("http://[::1]") != "http://[::1]:29595")
			throw Exception("starport_announce: normalize_url self-check");
		auto said = [](const ss_ &a){
			json::Value b = json::object();
			if(!public_address(a, 29500, b))
				return ss_("bad");
			const json::Value &h = b.get("address");
			return (h.is_string() ? h.as_string() : ss_())+" "+
					itos(b.get("port").as_integer())+
					(b.get("tls").is_true() ? " tls" : "");
		};
		if(said("") != " 29500" ||
				said("https://fp.example.org/") != "fp.example.org 443 tls" ||
				said("https://fp.example.org:8443") != "fp.example.org 8443 tls" ||
				said("fp.example.org:30000") != "fp.example.org 30000" ||
				said("[::1]:30000") != "::1 30000" ||
				said("fp.example.org/x?y") != "bad" ||
				said("fp.example.org:99999") != "bad")
			throw Exception("starport_announce: public_address self-check");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *n : {"starport:relay_open", "starport:relay_send",
				"starport:relay_close", "starport:config_get",
				"starport:config_set"})
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
		EVENT_TYPEN("network:packet_received/starport:config_get",
				on_config_get, network::Packet)
		EVENT_TYPEN("network:packet_received/starport:config_set",
				on_config_set, network::Packet)
	}

	void on_start()
	{
		m_dir = m_server->get_config().get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id();
		load_state();
		read_config();
		m_start_announcing = true;
	}

	ss_ config_path(){ return m_dir+"/starport.json"; }

	json::Value config()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return m_config.deepcopy();
	}

	// **A Starport's address with no port is on 29595** (10g), Starport's
	// own default, so a Starport and a server of another app share an
	// address: "host" and "http://host" are http://host:29595. https:// is
	// a proxy's, on 443 as ever.
	static ss_ normalize_url(ss_ u)
	{
		while(!u.empty() && u.back() == '/')
			u.pop_back();
		if(u.find("://") == ss_::npos)
			u = "http://"+u;
		if(u.compare(0, 7, "http://") == 0){
			const ss_ hostport = u.substr(7);
			const bool v6 = !hostport.empty() && hostport[0] == '[';
			const size_t close = v6 ? hostport.find(']') : 0;
			if(hostport.find(':', v6 ? close : 0) == ss_::npos)
				u += ":29595";
		}
		return u;
	}

	// **Where players reach this server**, starport.json's "address": ""
	// for the address the announce comes from and the server's own port;
	// "host[:port]"; or "https://host[:port]" behind a proxy with TLS, on
	// 443 unless said, which a client joins by a secure WebSocket. Sets the
	// announce's address, port and tls; false for one that is not an
	// address.
	static bool public_address(ss_ a, int64_t own_port, json::Value &body)
	{
		bool tls = false;
		if(a.compare(0, 8, "https://") == 0){
			tls = true;
			a = a.substr(8);
		} else if(a.compare(0, 7, "http://") == 0){
			a = a.substr(7);
		}
		while(!a.empty() && a.back() == '/')
			a.pop_back();
		int64_t port = tls ? 443 : own_port;
		const size_t colon = a.rfind(':');
		const bool v6 = !a.empty() && a[0] == '[';
		if(colon != ss_::npos && (!v6 || colon > a.find(']'))){
			const ss_ p = a.substr(colon + 1);
			if(p.empty() || p.size() > 5 ||
					p.find_first_not_of("0123456789") != ss_::npos)
				return false;
			port = atoi(p.c_str());
			a = a.substr(0, colon);
		}
		if(v6 && a.size() > 2 && a.back() == ']')
			a = a.substr(1, a.size() - 2);
		if(a.size() > 253 || port < 1 || port > 65535 ||
				a.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
				"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:") != ss_::npos)
			return false;
		if(!a.empty())
			body.set("address", a);
		body.set("port", port);
		body.set("tls", tls);
		return true;
	}

	static sv_<ss_> urls_of(const json::Value &c)
	{
		sv_<ss_> out;
		const json::Value &u = c.get("starports");
		for(unsigned i = 0; u.is_array() && i < u.size(); i++)
			if(u.at(i).is_string())
				out.push_back(normalize_url(u.at(i).as_string()));
		return out;
	}
	static bool is_on(const json::Value &c)
	{
		return c.is_object() && !c.get("enabled").is_false();
	}

	// **starport.json, watched** (10g): the admin's page writes it, and so
	// may a hand or a script; a change is taken in without a restart. A
	// Starport no longer announced to -- removed, or Starport turned off --
	// is told so at once.
	void read_config()
	{
		const ss_ text = read_file(config_path());
		ss_ old_text;
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			old_text = m_config_text;
		}
		if(text == old_text)
			return;
		json::Value c;
		if(!text.empty()){
			json::json_error_t err;
			c = json::load_string(text.c_str(), &err);
			if(!c.is_object() || !c.get("starports").is_array()){
				log_w(MODULE, "%s: not an object with \"starports\" (line %d:"
						" %s); kept as it was", cs(config_path()), err.line,
						err.text);
				std::lock_guard<std::mutex> lock(m_mutex);
				m_config_text = text;
				return;
			}
		}
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			const sv_<ss_> was = is_on(m_config) ? urls_of(m_config) :
					sv_<ss_>();
			const sv_<ss_> now = is_on(c) ? urls_of(c) : sv_<ss_>();
			for(const ss_ &u : was)
				if(std::find(now.begin(), now.end(), u) == now.end())
					m_delist.push_back(u);
			m_config = c;
			m_config_text = text;
		}
		if(is_on(c))
			log_i(MODULE, "Announcing to %u Starport(s)", c.get("starports").size());
		else
			log_v(MODULE, "%s: not announced to any Starport",
					cs(config_path()));
		m_wake.notify_all();
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
		const json::Value c = config();
		if(is_on(c))
			for(const ss_ &u : urls_of(c))
				allowed |= u == url;
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
		const int64_t now = interface::os::time_us();
		if(!m_dir.empty() && now >= m_next_read_us){
			m_next_read_us = now + 2000000;
			read_config();
		}
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
			sv_<ss_> delist;
			json::Value c;
			{
				std::lock_guard<std::mutex> lock(m_mutex);
				delist.swap(m_delist);
				c = m_config.deepcopy();
			}
			for(const ss_ &url : delist)
				withdraw(url);
			// A change announced just after the last announce is refused as
			// too soon; that one is tried again shortly, not in 5 minutes
			bool soon = false;
			if(is_on(c))
				for(const ss_ &url : urls_of(c))
					soon |= !announce(url, c);
			std::unique_lock<std::mutex> lock(m_mutex);
			const ss_ text = m_config_text;
			m_wake.wait_for(lock, std::chrono::seconds(soon ? 25 :
					ANNOUNCE_INTERVAL_S),
					[&](){ return m_stop || !m_delist.empty() ||
					m_config_text != text || m_announce_now; });
			m_announce_now = false;
			if(m_stop)
				return;
		}
	}

	// 10g: off that Starport's list at once, not after its timeout
	void withdraw(const ss_ &url)
	{
		json::Value body = json::object();
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			auto it = m_listings.find(url);
			if(it == m_listings.end())
				return;
			body.set("id", it->second.id);
			body.set("secret", interface::sha256::hex(it->second.secret));
			m_status[url] = "withdrawn";
			m_blocked.erase(url);
		}
		try {
			interface::http_post(url+"/api/delist", body.stringify());
			log_i(MODULE, "Withdrawn from %s", cs(url));
		} catch(std::exception &e){
			log_w(MODULE, "Withdrawing from %s: %s", cs(url), e.what());
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

	// False when the Starport said it was too soon (try again shortly)
	bool announce(const ss_ &url, const json::Value &cfg)
	{
		json::Value body = json::object();
		// What the server says it is: the config as it is, less the list of
		// Starports, which is this server's business, and the settings
		// that are this server's own
		for(json::Iterator it(cfg); it.valid(); it.next()){
			const ss_ k = it.key();
			if(k != "starports" && k != "ids" && k != "enabled")
				body.set(k, it.value());
		}
		// How people log in, as the listing says it (10c, 10g)
		body.set("login", ids_mode_of(cfg) == "off" ? "local" : "both");
		body.set("access", access_of(cfg));
		body.set("app", m_server->get_app_id());
		body.set("version", ss_(BUILDAT_VERSION));
		const json::Value &addr = cfg.get("address");
		if(!public_address(addr.is_string() ? addr.as_string() : "",
				atoi(m_server->get_config().get<ss_>("network_port").c_str()),
				body)){
			std::lock_guard<std::mutex> lock(m_mutex);
			m_status[url] = "not announced: the address is not host, "
					"host:port or https://host[:port]";
			return true;
		}
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
			std::lock_guard<std::mutex> lock(m_mutex);
			m_status[url] = ss_("unreachable: ")+e.what();
			return true;
		}
		const json::Value v = json::load_string(answer.c_str());
		if(!v.is_object() || !v.get("ok").is_true()){
			const ss_ why = v.is_object() && v.get("error").is_string() ?
					v.get("error").as_string() : answer.substr(0, 200);
			log_w(MODULE, "Announce to %s refused: %s", cs(url), cs(why));
			std::lock_guard<std::mutex> lock(m_mutex);
			m_status[url] = "refused: "+why;
			return why != "announced too often";
		}
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			m_status[url] = v.get("status").is_string() ?
					v.get("status").as_string() : ss_("announced");
			sv_<ss_> subs;
			const json::Value &sl = v.get("subscribed");
			for(unsigned i = 0; sl.is_array() && i < sl.size(); i++)
				if(sl.at(i).is_string())
					subs.push_back(sl.at(i).as_string());
			m_subscribed[url] = subs;
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
		return true;
	}

	// -- [STARPORT] 10c

	// The host of a Starport's url
	static ss_ host_of(const ss_ &url)
	{
		const size_t s = url.find("://");
		ss_ host = s == ss_::npos ? url : url.substr(s + 3);
		return host.substr(0, host.find_first_of(":/"));
	}

	// **Access, from the Accounts page** (10g): local accounts open is
	// open; invite only, with Starport IDs taken, is starport; else
	// invite. A shared password or an account made elsewhere is the
	// config's own word ("access": "password" or "external").
	ss_ access_of(const json::Value &c)
	{
		const json::Value &a = c.get("access");
		if(a.is_string() && (a.as_string() == "password" ||
				a.as_string() == "external"))
			return a.as_string();
		bool open = false;
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *acc){
				open = acc->registration_open();
			});
		if(open)
			return "open";
		return ids_mode_of(c) != "off" ? "starport" : "invite";
	}

	// "ids", or what an older file's "login" meant
	static ss_ ids_mode_of(const json::Value &c)
	{
		if(!is_on(c))
			return "off";
		const json::Value &ids = c.get("ids");
		if(ids.is_string() && (ids.as_string() == "anyone" ||
				ids.as_string() == "approved"))
			return ids.as_string();
		if(ids.is_string())
			return "off";
		const json::Value &login = c.get("login");
		return login.is_string() && (login.as_string() == "starport" ||
				login.as_string() == "both") ? "anyone" : "off";
	}

	ss_ ids_mode()
	{
		return ids_mode_of(config());
	}

	bool accepts_ids()
	{
		return ids_mode() != "off";
	}

	// starport.json written whole, then read back as any edit is
	ss_ write_config(const json::Value &c)
	{
		if(!c.is_object() || !c.get("starports").is_array())
			return "starport.json: an object with \"starports\"";
		interface::fs::create_directories(m_dir);
		write_file(config_path()+".tmp", c.stringify());
		if(!interface::fs::rename(config_path()+".tmp", config_path()))
			return "could not write "+config_path();
		read_config();
		return "";
	}

	ss_ set_ids_mode(const ss_ &mode)
	{
		if(mode != "off" && mode != "anyone" && mode != "approved")
			return "Starport IDs: off, anyone or approved";
		json::Value c = config();
		if(!c.is_object()){
			if(mode == "off")
				return "";
			return "No Starport set up: set one up on the Starport page first";
		}
		c.set("ids", mode);
		c.del_key("login");
		return write_config(c);
	}

	bool m_announce_now = false;
	void announce_soon()
	{
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			m_announce_now = true;
		}
		m_wake.notify_all();
	}

	bool is_blocked(const ss_ &host, const ss_ &sub)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		for(auto &pair : m_blocked)
			if(host_of(pair.first) == host && pair.second.count(sub))
				return true;
		return false;
	}

	// -- The admin's Starport page (10g)

	bool peer_is_admin(network::PeerInfo::Id peer)
	{
		bool admin = false;
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *a){
				admin = a->is_admin(a->name_of(peer));
			});
		return admin;
	}

	void send_config(network::PeerInfo::Id peer, const ss_ &message)
	{
		json::Value out = json::object();
		const json::Value c = config();
		out.set("config", c.is_object() ? c : json::object());
		out.set("path", config_path());
		out.set("access_now", access_of(c));
		out.set("message", message);
		json::Value rows = json::array();
		for(const ss_ &url : urls_of(c)){
			json::Value r = json::object();
			r.set("url", url);
			{
				std::lock_guard<std::mutex> lock(m_mutex);
				auto it = m_listings.find(url);
				if(it != m_listings.end()){
					r.set("listing", it->second.id);
					r.set("claim", claim_code(it->second));
				}
				r.set("status", m_status[url]);
				json::Value subs = json::array();
				for(const ss_ &n : m_subscribed[url])
					subs.append(n);
				r.set("subscribed", subs);
			}
			// What removing it would cut off: the accounts of its IDs
			int64_t linked = 0;
			if(m_server->has_module("accounts"))
				accounts::access(m_server, [&](accounts::Interface *a){
					linked = a->linked_count(host_of(url));
				});
			r.set("linked", linked);
			rows.append(r);
		}
		out.set("starports", rows);
		relay_send_packet(peer, "starport:config", out.stringify());
	}

	void on_config_get(const network::Packet &p)
	{
		if(peer_is_admin(p.sender))
			send_config(p.sender, "");
	}

	void on_config_set(const network::Packet &p)
	{
		if(!peer_is_admin(p.sender))
			return;
		json::json_error_t err;
		const json::Value c = json::load_string(p.data.c_str(), &err);
		send_config(p.sender, write_config(c));
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
