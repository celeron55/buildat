// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "accounts/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/sha256.h"
#include "interface/os.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/utility.hpp>
#include <random>
#include <sstream>
#include <map>
#define MODULE "accounts"

using interface::Event;

namespace accounts {

static const int PBKDF2_ITERATIONS = 10000;
// Failed logins on one connection before it has to reconnect
static const int MAX_LOGIN_FAILURES = 5;
static const size_t MIN_PASSWORD = 6;

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
// would lock everybody out, silently.
static void check_pbkdf2()
{
	const ss_ a = interface::sha256::hex(pbkdf2_sha256("password", "salt", 1));
	const ss_ b = interface::sha256::hex(pbkdf2_sha256("password", "salt", 2));
	if(a != "120fb6cffcf8b32c43e7225256c4f837"
			"a86548c92ccc35480805987cb70be17b" ||
			b != "ae4d0c95af6b46d32d0adff928f06dd0"
			"2a303f8ef3c251dfd6e2d85a95474c43")
		throw Exception("accounts: PBKDF2-HMAC-SHA256 self-check failed");
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

// Who may make an account, which only an admin changes
struct AccessSettings
{
	uint8_t open_registration = 0;

	template<class Archive>
	void serialize(Archive &archive){
		archive(open_registration);
	}
};

// A one-time invite: the admin who made it. privs is kept empty.
struct Invite
{
	sv_<ss_> privs;
	ss_ by;

	template<class Archive>
	void serialize(Archive &archive){
		archive(privs, by);
	}
};

// A name banned, the address it last joined from, and who banned it
struct Ban
{
	ss_ address;
	ss_ by;

	template<class Archive>
	void serialize(Archive &archive){
		archive(address, by);
	}
};

// Failed logins of one name or one address: a wait that doubles with each,
// up to a minute, and after FAIL_LOCK of them in the window a lock of the
// window's length
struct Failures
{
	int count = 0;
	int64_t first_us = 0;
	int64_t wait_until_us = 0;
};
static const int64_t FAIL_WINDOW_US = 600LL * 1000000;
static const int FAIL_LOCK = 10;

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

// Luanti's rule for a player name, which every game here keeps
static bool valid_name(const ss_ &name)
{
	if(name.empty() || name.size() > 20)
		return false;
	for(char c : name)
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	return true;
}

struct Hello
{
	uint8_t local = 0;      // no password asked
	// The join asks for the setup code (the server has no admin), or says
	// a new name needs an invite (registration is not open)
	uint8_t setup = 0;
	uint8_t open_registration = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(local, setup, open_registration);
	}
};

struct LoginRequest
{
	ss_ name;
	ss_ password;
	ss_ code; // the setup code, or an invite code
	// [ACC_KEEP]: a token from a login that asked to be kept, in place of
	// the password; and whether this login asks for one
	ss_ token;
	uint8_t keep = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(name, password, code, token, keep);
	}
};

// **A kept login** ([ACC_KEEP]), stored as token/<the token's sha256>: the
// account, when it ends, and the account's password hash then, so that a
// new password or a deleted account ends it too
struct KeptLogin
{
	ss_ name;
	int64_t expires_us = 0;
	ss_ hash;
	template<class Archive>
	void serialize(Archive &archive){
		archive(name, expires_us, hash);
	}
};
static const int64_t KEEP_US = 90LL * 24 * 3600 * 1000000;

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
	// name, address
	sv_<std::pair<ss_, ss_>> bans;
	template<class Archive>
	void serialize(Archive &archive){
		archive(users, invites, access, bans);
	}
};

struct Peer
{
	ss_ name; // empty until joined
	ss_ address;
	int failures = 0;
};

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	AccessSettings m_access;
	ss_ m_setup_code;
	bool m_launched = false;
	std::map<PeerId, Peer> m_peers;
	std::map<ss_, Failures> m_name_failures;
	std::map<ss_, Failures> m_address_failures;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		if(m_save){
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->close(m_save);
			});
		}
	}

	void init()
	{
		check_pbkdf2();
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *name : {"accounts:get_hello", "accounts:login",
				"accounts:admin", "accounts:passwd", "accounts:logout"})
			m_server->sub_event(this,
					Event::t(ss_("network:packet_received/")+name));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("network:packet_received/accounts:get_hello",
				on_get_hello, network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:login", on_login,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:admin", on_admin,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:passwd", on_passwd,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:logout", on_logout,
				network::Packet)
	}

	// One key of what the launcher asked for through the server's -u
	// ([LAUNCH_GRID]), read as a packet would be
	ss_ launch_param(const ss_ &key_name)
	{
		const ss_ u = m_server->get_config().get<ss_>("untrusted_launch");
		const ss_ key = key_name + "=";
		size_t at = u.find(key);
		if(at == ss_::npos || !(at == 0 || u[at - 1] == '\n'))
			return "";
		ss_ v = u.substr(at + key.size());
		v = v.substr(0, v.find('\n'));
		for(char c : v)
			if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
				return "";
		return v;
	}

	void on_start()
	{
		m_launched = launch_param("launcher") == "1";
		if(m_store)
			return;
		storage::access(m_server, [&](storage::Interface *istorage){
			m_save = istorage->open("_server");
			if(!m_save)
				m_save = istorage->create("_server");
		});
		if(!m_save){
			m_server->shutdown(1, "accounts: no server store");
			return;
		}
		m_store = m_save->store("accounts");
		load_access();
	}

	void send(PeerId peer, const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, data);
		});
	}

	// Peers

	void on_client_connected(const network::NewClient &client)
	{
		Peer peer;
		peer.address = client.info.address;
		m_peers[client.info.id] = peer;
	}

	void on_client_disconnected(const network::OldClient &client)
	{
		auto it = m_peers.find(client.info.id);
		if(it == m_peers.end())
			return;
		const bool joined = !it->second.name.empty();
		m_peers.erase(it);
		if(joined)
			send_users_to_admins();
	}

	// The interface

	ss_ name_of(PeerId peer)
	{
		auto it = m_peers.find(peer);
		return it == m_peers.end() ? "" : it->second.name;
	}

	PeerId find_peer(const ss_ &name)
	{
		for(auto &pair : m_peers)
			if(!name.empty() && pair.second.name == name)
				return pair.first;
		return 0;
	}

	ss_ address_of(PeerId peer)
	{
		auto it = m_peers.find(peer);
		return it == m_peers.end() ? "" : it->second.address;
	}

	bool is_admin(const ss_ &name)
	{
		Account account;
		return !name.empty() && get_account(name, account) &&
				account.has("admin");
	}

	bool exists(const ss_ &name)
	{
		Account account;
		return !name.empty() && get_account(name, account);
	}

	sv_<ss_> account_names()
	{
		sv_<ss_> out;
		if(m_store)
			for(const ss_ &key : m_store->list("auth/"))
				out.push_back(key.substr(5));
		return out;
	}

	bool is_local(PeerId peer)
	{
		auto it = m_peers.find(peer);
		return m_launched && it != m_peers.end() &&
				(it->second.address == "127.0.0.1" ||
				it->second.address == "::1");
	}

	bool launched()
	{
		return m_launched;
	}

	void kick(PeerId peer, const ss_ &why)
	{
		auto it = m_peers.find(peer);
		if(it == m_peers.end())
			return;
		log_i(MODULE, "%s kicked: %s", cs(it->second.name), cs(why));
		send(peer, "accounts:kicked", pack(why));
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->disconnect(peer);
		});
	}

	ss_ ban(const ss_ &name, const ss_ &by)
	{
		if(!m_store)
			return "No accounts yet";
		if(!valid_name(name))
			return "No such name";
		if(is_admin(name))
			return "An admin is not banned";
		Ban b;
		b.by = by;
		ss_ data;
		if(m_store->get("ban/"+name, data))
			unpack(data, b);
		const PeerId peer = find_peer(name);
		if(peer)
			b.address = address_of(peer);
		m_store->set("ban/"+name, pack(b));
		if(!b.address.empty())
			m_store->set("banaddr/"+b.address, name);
		log_i(MODULE, "%s banned %s (%s)", cs(by), cs(name), cs(b.address));
		if(peer)
			kick(peer, "banned by "+by);
		send_users_to_admins();
		return "";
	}

	ss_ unban(const ss_ &name_or_address)
	{
		if(!m_store)
			return "No accounts yet";
		ss_ data;
		bool found = false;
		if(m_store->get("ban/"+name_or_address, data)){
			Ban b;
			if(unpack(data, b) && !b.address.empty())
				m_store->remove("banaddr/"+b.address);
			m_store->remove("ban/"+name_or_address);
			found = true;
		}
		if(m_store->get("banaddr/"+name_or_address, data)){
			m_store->remove("banaddr/"+name_or_address);
			m_store->remove("ban/"+data);
			found = true;
		}
		if(!found)
			return "No ban of "+name_or_address;
		log_i(MODULE, "%s was unbanned", cs(name_or_address));
		send_users_to_admins();
		return "";
	}

	sv_<std::pair<ss_, ss_>> bans()
	{
		sv_<std::pair<ss_, ss_>> out;
		if(!m_store)
			return out;
		for(const ss_ &key : m_store->list("ban/")){
			ss_ data;
			Ban b;
			if(m_store->get(key, data) && unpack(data, b))
				out.push_back(std::make_pair(key.substr(4), b.address));
		}
		return out;
	}

	sv_<ss_> ban_list()
	{
		sv_<ss_> out;
		for(auto &b : bans())
			out.push_back(b.second.empty() ? b.first : b.first+"|"+b.second);
		return out;
	}

	// Why a name or an address may not join, or ""
	ss_ banned(const ss_ &name, const ss_ &address)
	{
		ss_ data;
		if(m_store->get("ban/"+name, data))
			return "You are banned from this server";
		if(!address.empty() && m_store->get("banaddr/"+address, data))
			return "This address is banned from this server";
		return "";
	}

	// Accounts

	bool get_account(const ss_ &name, Account &account)
	{
		ss_ data;
		return m_store && m_store->get("auth/"+name, data) &&
				unpack(data, account);
	}

	void set_account(const ss_ &name, const Account &account)
	{
		m_store->set("auth/"+name, pack(account));
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

	void save_access()
	{
		m_store->set("access/settings", pack(m_access));
	}

	void load_access()
	{
		ss_ data;
		if(!(m_store->get("access/settings", data) &&
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
		for(const ss_ &key : m_store->list("auth/")){
			Account account;
			if(get_account(key.substr(5), account) && account.has("admin"))
				n++;
		}
		return n;
	}

	// A server with no admin is claimed with a code from its log: on a
	// public server the first to connect would otherwise be its admin
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

	// The join

	void send_hello(PeerId peer)
	{
		Hello h;
		h.local = is_local(peer);
		h.setup = !h.local && !m_setup_code.empty();
		h.open_registration = m_access.open_registration;
		send(peer, "accounts:hello", pack(h));
	}

	void on_get_hello(const network::Packet &packet)
	{
		if(m_peers.count(packet.sender))
			send_hello(packet.sender);
	}

	// simplified: the password arrives in the clear on a native client's
	// connection, because the transport is not encrypted yet ([TRANSPORT]);
	// the join dialog says so. The web client behind an https proxy has TLS.
	void on_login(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end() || !m_store)
			return;
		Peer &peer = pit->second;
		LoginRequest cred;
		// The error, or "", and the token of a login asked to be kept
		ss_ token;
		auto reply = [&](const ss_ &error){
			send(packet.sender, "accounts:login_result",
					pack(std::make_pair(error, token)));
		};
		// The local user is on the machine the saves are on: a password
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
		if(password.size() > 100 || code.size() > 100 || cred.token.size() > 100)
			return reply("The password is too long");
		if(find_peer(name))
			return reply(name+" is already here");
		if(!local){
			const ss_ why = banned(name, peer.address);
			if(!why.empty()){
				log_i(MODULE, "Login of %s from %s refused: banned", cs(name),
						cs(peer.address));
				return reply(why);
			}
		}

		// A name and an address that failed wait before they are tried
		// again
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
		if(!cred.token.empty()){
			KeptLogin kept;
			ss_ data;
			const ss_ key = "token/"+interface::sha256::hex(
					interface::sha256::calculate(cred.token));
			if(!(m_store->get(key, data) && unpack(data, kept)) ||
					kept.name != name || kept.expires_us < now ||
					!get_account(name, account) || kept.hash != account.hash){
				m_store->remove(key);
				return fail("The saved login has ended: log in again");
			}
		} else if(get_account(name, account)){
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
					if(!(m_store->get("invite/"+code, data) &&
							unpack(data, invite)))
						return fail("No such invite code");
					m_store->remove("invite/"+code);
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
		if(cred.keep && !local && cred.token.empty()){
			token = random_code(32);
			KeptLogin kept;
			kept.name = name;
			kept.expires_us = now + KEEP_US;
			kept.hash = account.hash;
			m_store->set("token/"+interface::sha256::hex(
					interface::sha256::calculate(token)), pack(kept));
			log_i(MODULE, "%s is kept logged in", cs(name));
		}
		log_i(MODULE, "%s joined from %s", cs(name), cs(peer.address));
		peer.name = name;
		reply("");
		m_server->emit_event("accounts:login", new Login(packet.sender, name));
		send_users_to_admins();
	}

	// The admin's

	void send_users(PeerId peer)
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
		info.bans = bans();
		send(peer, "accounts:users", pack(info));
	}

	void send_users_to_admins()
	{
		if(!m_store)
			return;
		for(auto &pair : m_peers)
			if(is_admin(pair.second.name))
				send_users(pair.first);
	}

	void privs_changed(const ss_ &name)
	{
		const PeerId peer = find_peer(name);
		if(peer)
			m_server->emit_event("accounts:privs", new Login(peer, name));
	}

	void on_admin(const network::Packet &packet)
	{
		AdminRequest r;
		auto pit = m_peers.find(packet.sender);
		if(!m_store || pit == m_peers.end() || !is_admin(pit->second.name) ||
				!unpack(packet.data, r))
			return;
		const ss_ by = pit->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "accounts:admin_result", pack(text));
		};
		Account account;
		const bool exists = !r.name.empty() && get_account(r.name, account);
		const PeerId target = exists ? find_peer(r.name) : 0;
		if(r.cmd == "list"){
			return send_users(packet.sender);
		} else if(r.cmd == "priv"){
			if(!exists || r.arg != "admin")
				return result("No such account or privilege");
			if(!r.on && account.has("admin") && admin_count() <= 1)
				return result("The last admin keeps admin");
			account.privs = r.on ? sv_<ss_>{"admin"} : sv_<ss_>{};
			set_account(r.name, account);
			privs_changed(r.name);
			log_i(MODULE, "%s %s admin %s", cs(by), r.on ? "granted" : "revoked",
					cs(r.name));
			result(r.name+(r.on ? " is an admin" : " is no longer an admin"));
		} else if(r.cmd == "kick"){
			if(!target)
				return result(r.name+" is not here");
			kick(target, "kicked by "+by);
			result(r.name+" was kicked");
		} else if(r.cmd == "ban"){
			const ss_ why = ban(r.name, by);
			result(why.empty() ? r.name+" was banned" : why);
		} else if(r.cmd == "unban"){
			const ss_ why = unban(r.name);
			result(why.empty() ? r.name+" was unbanned" : why);
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
			set_account(r.name, new_account(r.arg, {}));
			log_i(MODULE, "%s added the account %s", cs(by), cs(r.name));
			result("The account "+r.name+" was added");
		} else if(r.cmd == "invite"){
			Invite invite;
			invite.by = by;
			const ss_ code = random_code(10);
			m_store->set("invite/"+code, pack(invite));
			log_i(MODULE, "%s made an invite", cs(by));
			result("Invite code: "+code);
		} else if(r.cmd == "uninvite"){
			m_store->remove("invite/"+upper(r.name));
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

	// A user's own password: the old one and the new one
	void on_passwd(const network::Packet &packet)
	{
		std::pair<ss_, ss_> pw;
		auto it = m_peers.find(packet.sender);
		if(!m_store || it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, pw))
			return;
		const ss_ name = it->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "accounts:passwd_result", pack(text));
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

	// A kept login ended by its user ([ACC_KEEP]): the token, which must be
	// this peer's account's
	void on_logout(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		ss_ tok;
		if(!m_store || it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, tok))
			return;
		const ss_ key = "token/"+interface::sha256::hex(
				interface::sha256::calculate(tok));
		KeptLogin kept;
		ss_ data;
		if(m_store->get(key, data) && unpack(data, kept) &&
				kept.name == it->second.name){
			m_store->remove(key);
			log_i(MODULE, "%s logged out", cs(kept.name));
		}
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_accounts(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
