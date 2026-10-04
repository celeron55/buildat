// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "accounts/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "starport_announce/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/sha256.h"
#include "interface/sha1.h"
#include "interface/os.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/utility.hpp>
#include <random>
#include <set>
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

// **TOTP** ([STARPORT] 10a, RFC 6238): HMAC-SHA1, 30 s steps, 6 digits.
// For a server's own admins and moderators, and anyone who wants it; a
// Starport ID is an account of the Starport's server and has it the same.
static ss_ hmac_sha1(ss_ key, const ss_ &msg)
{
	if(key.size() > 64)
		key = interface::sha1::calculate(key);
	key.resize(64, '\0');
	ss_ ipad(64, '\0'), opad(64, '\0');
	for(int i = 0; i < 64; i++){
		ipad[i] = key[i] ^ 0x36;
		opad[i] = key[i] ^ 0x5c;
	}
	return interface::sha1::calculate(opad +
			interface::sha1::calculate(ipad + msg));
}

static ss_ hotp(const ss_ &secret, uint64_t counter, int digits = 6)
{
	ss_ msg(8, '\0');
	for(int i = 7; i >= 0; i--, counter >>= 8)
		msg[i] = (char)(counter & 0xff);
	const ss_ h = hmac_sha1(secret, msg);
	const int o = h[19] & 0x0f;
	uint32_t v = ((uint32_t)(h[o] & 0x7f) << 24) |
			((uint32_t)(unsigned char)h[o + 1] << 16) |
			((uint32_t)(unsigned char)h[o + 2] << 8) |
			(uint32_t)(unsigned char)h[o + 3];
	uint32_t mod = 1;
	for(int i = 0; i < digits; i++)
		mod *= 10;
	char buf[16];
	snprintf(buf, sizeof buf, "%0*u", digits, v % mod);
	return buf;
}

// What authenticator apps take: RFC 4648 base32, no padding
static ss_ base32(const ss_ &data)
{
	static const char *A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
	ss_ out;
	uint32_t buf = 0;
	int bits = 0;
	for(unsigned char c : data){
		buf = (buf << 8) | c;
		bits += 8;
		while(bits >= 5){
			out += A[(buf >> (bits - 5)) & 31];
			bits -= 5;
		}
	}
	if(bits > 0)
		out += A[(buf << (5 - bits)) & 31];
	return out;
}

// RFC 6238's SHA-1 vector at T = 59 s, and RFC 4648's base32. Run at every
// start, as the PBKDF2 one is: a wrong TOTP locks people out.
static void totp_self_check()
{
	if(hotp("12345678901234567890", 59 / 30, 8) != "94287082" ||
			base32("foobar") != "MZXW6YTBOI")
		throw Exception("accounts: TOTP self-check failed");
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

// A name no new account takes: "client<digits>" is what an app calls a
// peer that has not logged in (apps/vanilla's player_name_of), and an
// account of that name was the same player to it ([SECURITY_RUN_1]).
// One already made keeps logging in.
static bool reserved_name(const ss_ &name)
{
	if(name.size() < 7 || upper(name.substr(0, 6)) != "CLIENT")
		return false;
	for(size_t i = 6; i < name.size(); i++)
		if(!isdigit((unsigned char)name[i]))
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
	// [STARPORT] 10c: a Starport ID logs in here
	uint8_t starport = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(local, setup, open_registration, starport);
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
	// [STARPORT] 10: the TOTP code, and a Starport ID's token for this
	// server in place of a name and a password
	ss_ totp;
	ss_ starport;
	// [ACCOUNT_CREATE]: this login is allowed to make the account if the name
	// does not exist; a plain login (0) refuses an unknown name instead
	uint8_t create = 0;
	template<class Archive>
	void serialize(Archive &archive){
		// A leading version byte: add version-gated fields below it rather
		// than breaking the wire format again (voxel_cereal.h pattern)
		uint8_t version = 1;
		archive(version);
		archive(name, password, code, token, keep, totp, starport, create);
	}
};

// accounts:totp: begin (a new secret, pending), confirm (its first code
// turns it on), off (a code turns it off)
struct TotpRequest
{
	ss_ cmd;
	ss_ code;
	template<class Archive>
	void serialize(Archive &archive){
		archive(cmd, code);
	}
};
struct TotpResult
{
	ss_ error;
	ss_ secret; // base32, while one is pending
	ss_ uri;    // otpauth://, for an app's own QR reader or a link
	uint8_t on = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(error, secret, uri, on);
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
	// 10g: logs in only by its Starport ID (no password anyone knows), so
	// not while the Starport is away
	uint8_t id_only = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(name, privs, here, id_only);
	}
};

struct UsersInfo
{
	sv_<UserRow> users;
	sv_<std::pair<ss_, Invite>> invites;
	AccessSettings access;
	// name, address
	sv_<std::pair<ss_, ss_>> bans;
	// 10g: Starport IDs off, anyone or approved; the IDs waiting
	ss_ starport_ids;
	sv_<ss_> approvals;
	template<class Archive>
	void serialize(Archive &archive){
		archive(users, invites, access, bans, starport_ids, approvals);
	}
};

struct Peer
{
	ss_ name; // empty until joined
	ss_ address;
	bool web = false;
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
	// The token the launcher started this server with (main.cpp takes it
	// out of the environment), and the peers that showed it: the
	// launcher's own client, which is this server's owner and admin.
	// Without a token -- a server started by hand with launcher=1, which
	// the tests do -- a loopback peer is local, as it was.
	ss_ m_owner_token;
	std::set<PeerId> m_owners;
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

	// The failure counter is what stops a password being guessed, so it
	// is checked at every start as the PBKDF2 and TOTP vectors are. It
	// drives note_failure/failure_wait with a clock of its own (both take
	// `now`), so it is deterministic and touches no real account.
	void rate_limit_self_check()
	{
		const int64_t s = 1000000; // one second in us
		std::map<ss_, Failures> m;
		// An unknown key waits for nothing
		if(failure_wait(m, "a", 0) != 0)
			throw Exception("accounts: rate-limit self-check: a fresh key");
		// The wait doubles to a minute, then FAIL_LOCK of them in the
		// window locks it for the window's length
		const int64_t want[] = {1, 2, 4, 8, 16, 32, 60, 60, 60, 600};
		for(int i = 0; i < FAIL_LOCK; i++){
			note_failure(m, "a", 0);
			if(failure_wait(m, "a", 0) != want[i] * s)
				throw Exception("accounts: rate-limit self-check: the wait "
						"after "+itos(i + 1)+" failures is "+
						itos((int)(failure_wait(m, "a", 0) / s))+" s, not "+
						itos((int)want[i]));
		}
		// Locked at FAIL_LOCK: still waiting just before the window ends,
		// cleared once both the window has passed and the wait is over
		if(failure_wait(m, "a", 599 * s) <= 0)
			throw Exception("accounts: rate-limit self-check: unlocked early");
		if(failure_wait(m, "a", 601 * s) != 0)
			throw Exception("accounts: rate-limit self-check: still locked "
					"after the window");
		// A failure outside the window starts the count over, not doubling
		// from where an old one left off
		std::map<ss_, Failures> m2;
		note_failure(m2, "b", 0);
		note_failure(m2, "b", 601 * s);
		if(failure_wait(m2, "b", 601 * s) != 1 * s)
			throw Exception("accounts: rate-limit self-check: the window did "
					"not reset the count");
	}

	void init()
	{
		check_pbkdf2();
		totp_self_check();
		rate_limit_self_check();
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *name : {"accounts:owner_token",
				"accounts:get_hello", "accounts:login",
				"accounts:admin", "accounts:passwd", "accounts:logout",
				"accounts:totp", "accounts:link_starport"})
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
		EVENT_TYPEN("network:packet_received/accounts:owner_token",
				on_owner_token, network::Packet)
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
		EVENT_TYPEN("network:packet_received/accounts:totp", on_totp,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:link_starport",
				on_link_starport, network::Packet)
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
		m_owner_token = m_server->get_config().get<ss_>("owner_token");
		// **Answers go ahead of a game's bulk** ([NET_CHANNELS]; user,
		// 2026-09-30: a new invite never showed, behind a world streaming to
		// a slow link). Each is the whole of what it says, so a newer one
		// replacing an unsent one loses nothing: the users list, what an
		// admin's request came to, a login's and a password's answers.
		network::access(m_server, [&](network::Interface *inetwork){
			for(const char *name : {"accounts:hello", "accounts:login_result",
					"accounts:users", "accounts:admin_result",
					"accounts:passwd_result", "accounts:totp_result",
					"accounts:link_result"})
				inetwork->declare(name,
						network::Interface::Channel::LatestOnly);
		});
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
		peer.web = client.info.web;
		m_peers[client.info.id] = peer;
	}

	void on_client_disconnected(const network::OldClient &client)
	{
		m_owners.erase(client.info.id);
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

	sv_<PeerId> find_peers(const ss_ &name)
	{
		sv_<PeerId> out;
		for(auto &pair : m_peers)
			if(!name.empty() && pair.second.name == name)
				out.push_back(pair.first);
		return out;
	}

	bool m_multiple_logins = false;
	void set_multiple_logins(bool on)
	{
		m_multiple_logins = on;
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

	// The launcher's own client, which connects by TCP or the pipe and
	// never by a WebSocket: a WebSocket from 127.0.0.1 is whatever page
	// the user's browser has open, and the WebSocket upgrade takes any
	// Origin ([SECURITY_RUN_1])
	bool is_local(PeerId peer)
	{
		auto it = m_peers.find(peer);
		if(!m_launched || it == m_peers.end() || it->second.web)
			return false;
		if(!m_owner_token.empty())
			return m_owners.count(peer) != 0;
		return it->second.address == "127.0.0.1" ||
				it->second.address == "::1";
	}

	// Another user or program on this machine reaches 127.0.0.1 too, and
	// once the owner opens the game to the LAN everyone there does: what
	// makes a peer the owner is the token, compared in constant time
	void on_owner_token(const network::Packet &packet)
	{
		if(m_owner_token.empty() || !m_peers.count(packet.sender))
			return;
		const ss_ &got = packet.data;
		unsigned diff = got.size() ^ m_owner_token.size();
		for(size_t i = 0; i < m_owner_token.size(); i++)
			diff |= (unsigned char)m_owner_token[i] ^
					(unsigned char)(i < got.size() ? got[i] : 0);
		if(diff != 0){
			log_w(MODULE, "Peer %i sent a wrong owner token",
					(int)packet.sender);
			return;
		}
		m_owners.insert(packet.sender);
		log_i(MODULE, "Peer %i is this server's owner", (int)packet.sender);
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
		// **An address only where anyone can make an account** (user,
		// 2026-09-30): there a banned player comes back under a new name.
		// On an invite-only server the account is enough, and an address
		// ban would keep out others behind the same one.
		// Each connection's address, where the name is here more than once
		const sv_<PeerId> peers = find_peers(name);
		if(!peers.empty() && m_access.open_registration)
			b.address = address_of(peers[0]);
		m_store->set("ban/"+name, pack(b));
		if(m_access.open_registration)
			for(PeerId p : peers)
				m_store->set("banaddr/"+address_of(p), name);
		log_i(MODULE, "%s banned %s (%s)", cs(by), cs(name), cs(b.address));
		for(PeerId p : peers)
			kick(p, "banned by "+by);
		send_users_to_admins();
		return "";
	}

	ss_ unban(const ss_ &name_or_address, const ss_ &only_by)
	{
		if(!m_store)
			return "No accounts yet";
		ss_ data;
		bool found = false;
		if(!only_by.empty()){
			// Whose ban it is, by the name it is under
			ss_ name = name_or_address;
			ss_ bd;
			if(!m_store->get("ban/"+name, bd) &&
					m_store->get("banaddr/"+name_or_address, data))
				name = data;
			Ban b;
			if(m_store->get("ban/"+name, bd) && unpack(bd, b) &&
					b.by != only_by)
				return "Banned by "+b.by+"; an admin lifts it";
		}
		if(m_store->get("ban/"+name_or_address, data)){
			Ban b;
			if(unpack(data, b) && !b.address.empty())
				m_store->remove("banaddr/"+b.address);
			m_store->remove("ban/"+name_or_address);
			// Off the Starports at the next announce, too (10d)
			m_store->remove("ban_report/"+name_or_address);
			found = true;
		}
		if(m_store->get("banaddr/"+name_or_address, data)){
			m_store->remove("banaddr/"+name_or_address);
			m_store->remove("ban/"+data);
			m_store->remove("ban_report/"+data);
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
		if(m_access.open_registration && !address.empty() &&
				m_store->get("banaddr/"+address, data))
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
		starport_announce::access(m_server,
				[&](starport_announce::Interface *s){
			h.starport = s->accepts_ids() ? 1 : 0;
		});
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
			// The name joined as: a Starport ID's is the token's
			send(packet.sender, "accounts:login_result",
					pack(std::make_pair(std::make_pair(error, token),
					error.empty() ? cred.name : ss_())));
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
		// [STARPORT] 10c: a Starport ID's token in place of a password; the
		// name is the one the player picked on the Starport for this
		// community, and the account is the one linked to the ID
		starport_announce::IdLogin id;
		if(!cred.starport.empty()){
			ss_ why = "This server does not take Starport IDs";
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				why = s->verify_id_token(cred.starport, &id);
			});
			if(!why.empty()){
				log_i(MODULE, "Starport ID login from %s refused: %s",
						cs(peer.address), cs(why));
				return reply(why);
			}
			// 10g: an ID linked to an account logs in as that account,
			// whatever name it picked for the community
			ss_ linked;
			cred.name = m_store->get("starport/"+id.starport+"/"+id.sub,
					linked) ? linked : id.name;
			cred.password.clear();
			cred.token.clear();
		}
		const ss_ &name = cred.name;
		const ss_ &password = cred.password;
		const ss_ code = upper(cred.code);
		if(!valid_name(name))
			return reply("A name is 1 to 20 letters, digits, _ or -");
		if(password.size() > 100 || code.size() > 100 || cred.token.size() > 100)
			return reply("The password is too long");
		if(find_peer(name) && !m_multiple_logins)
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
		// A Starport ID's refusal that is no failure, logged as one is
		auto refused = [&](const ss_ &why){
			log_i(MODULE, "Starport ID login of %s from %s refused: %s",
					cs(name), cs(peer.address), cs(why));
			reply(why);
		};

		Account account;
		if(!id.sub.empty()){
			const ss_ link = "starport/"+id.starport+"/"+id.sub;
			ss_ linked;
			ss_ mode = "off";
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				mode = s->ids_mode();
			});
			if(m_store->get(link, linked)){
				if(!get_account(name, account))
					return refused("This Starport ID's account here is gone; "
							"ask an admin");
			} else {
				if(exists(name))
					return refused("The name "+name+" is taken on this server "
							"by an account of its own: pick another for "
							"this community on the Starport, or, if the "
							"account is yours, log in with its password and "
							"link your ID to it (My account..., Link a "
							"Starport ID...)");
				// No admin yet: as with a local account, only the setup
				// code makes a new one, and makes it the admin (10g)
				if(!m_setup_code.empty() && code != m_setup_code)
					return fail(code.empty() ? "This server has no admin "
							"yet: the first account needs the setup code from "
							"the server's log" : "Wrong setup code");
				// A password nobody knows: this account logs in by its ID
				account = new_account(random_code(32), {});
				set_account(name, account);
				m_store->set(link, name);
				m_store->set("starport_of/"+name, link);
				// 10g: approved only, the new ID waits for an admin
				if(mode == "approved" && m_setup_code.empty())
					m_store->set("approval/"+name, "");
				log_i(MODULE, "New account %s for a Starport ID of %s%s",
						cs(name), cs(id.starport), mode == "approved" ?
						" (waiting for approval)" : "");
				send_users_to_admins();
			}
			ss_ pending;
			if(m_store->get("approval/"+name, pending))
				return refused("Your Starport ID waits for an admin of this "
						"server to let it in");
			// The first admin by ID, as by a local login (10g)
			if(!m_setup_code.empty() && !code.empty()){
				if(code != m_setup_code)
					return fail("Wrong setup code");
				account.privs = {"admin"};
				set_account(name, account);
				log_i(MODULE, "%s claimed the server with the setup code",
						cs(name));
			}
		} else if(!cred.token.empty()){
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
			if(!local && totp_on(name)){
				// Said so, not counted: the client asks for the code
				if(cred.totp.empty())
					return reply("TOTP: enter the code from your "
							"authenticator app");
				if(!check_totp(name, cred.totp))
					return fail("TOTP: wrong code");
			}
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
			// [ACCOUNT_CREATE]: a plain login does not make an account; a
			// mistyped name is refused as unknown. Local still auto-creates.
			if(!local && !cred.create)
				return reply("There is no account named \""+name+"\". Use "
						"\"Create a new account\" to make one.");
			if(reserved_name(name))
				return reply("\""+name+"\" is kept for a client that has "
						"not logged in; choose another name");
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
		// 10g: a blocklist's ban of the ID is a ban of its account here,
		// password and kept login too -- not of an admin's or a
		// moderator's, which a blocklist must not lock out
		if(id.sub.empty() && !local && !account.has("admin") &&
				!account.has("moderator") && id_blocked(name)){
			log_i(MODULE, "Login of %s refused: its Starport ID is on a "
					"blocklist", cs(name));
			return reply("Banned by a blocklist this server follows");
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
			ss_ x;
			row.id_only = m_store->get("starport_of/"+row.name, x) &&
					!m_store->get("own_password/"+row.name, x);
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
		info.starport_ids = "off";
		starport_announce::access(m_server,
				[&](starport_announce::Interface *s){
			info.starport_ids = s->ids_mode();
		});
		for(const ss_ &key : m_store->list("approval/"))
			info.approvals.push_back(key.substr(9));
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
		for(PeerId peer : find_peers(name))
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
		// Every connection of the name ([FP_TWO_CLIENTS])
		const sv_<PeerId> targets = exists ? find_peers(r.name) : sv_<PeerId>();
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
			for(PeerId t : targets)
				kick(t, "kicked by "+by);
			result(r.name+" was kicked");
		} else if(r.cmd == "ban"){
			ss_ why = ban(r.name, by);
			// [STARPORT] 10d: the reason, and whether it goes to the
			// Starports (an account of a Starport ID only)
			if(why.empty() && r.on){
				const ss_ rep = report_ban(r.name, r.arg.substr(0, 40));
				why = rep.empty() ? "" : r.name+" was banned; "+rep;
			}
			result(why.empty() ? r.name+" was banned" : why);
		} else if(r.cmd == "unban"){
			const ss_ why = unban(r.name, "");
			result(why.empty() ? r.name+" was unbanned" : why);
		} else if(r.cmd == "password"){
			if(!exists)
				return result("No account "+r.name);
			if(r.arg.size() < MIN_PASSWORD || r.arg.size() > 100)
				return result("A password is "+itos((int)MIN_PASSWORD)+
						" to 100 characters");
			set_account(r.name, new_account(r.arg, account.privs));
			// A password someone knows: the account no longer logs in by
			// its Starport ID only (10g)
			m_store->set("own_password/"+r.name, "");
			for(PeerId t : targets)
				if(t != packet.sender)
					kick(t, "the password was reset by "+by);
			log_i(MODULE, "%s reset the password of %s", cs(by), cs(r.name));
			result("The password of "+r.name+" was reset");
		} else if(r.cmd == "delete"){
			if(!exists)
				return result("No account "+r.name);
			if(r.name == by)
				return result("An admin does not delete their own account");
			if(account.has("admin") && admin_count() <= 1)
				return result("The last admin is not deleted");
			for(PeerId t : targets)
				kick(t, "the account was deleted by "+by);
			m_store->remove("auth/"+r.name);
			// Its Starport ID's link, and what waited for approval (10g)
			ss_ link;
			if(m_store->get("starport_of/"+r.name, link))
				m_store->remove(link);
			m_store->remove("starport_of/"+r.name);
			m_store->remove("approval/"+r.name);
			m_store->remove("ban_report/"+r.name);
			m_store->remove("own_password/"+r.name);
			log_i(MODULE, "%s deleted the account %s", cs(by), cs(r.name));
			result("The account "+r.name+" was deleted");
		} else if(r.cmd == "add"){
			if(!valid_name(r.name) || reserved_name(r.name))
				return result("A name is 1 to 20 letters, digits, _ or -, "
						"and not client<digits>");
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
		} else if(r.cmd == "setting" && r.name == "starport_ids"){
			ss_ why = "This server has no Starport module";
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				// "anyone", or "anyone https://host": the address the
				// admin reached the server by, from the page
				const size_t sp = r.arg.find(' ');
				why = s->set_ids_mode(r.arg.substr(0, sp), sp == ss_::npos ?
						"" : r.arg.substr(sp + 1));
			});
			// Everyone: a joined client's My account links an ID by it
			for(auto &pair : m_peers)
				send_hello(pair.first);
			result(why);
		} else if(r.cmd == "approve" || r.cmd == "turn_away"){
			ss_ pending;
			if(!m_store->get("approval/"+r.name, pending))
				return result("No ID of "+r.name+" waits");
			m_store->remove("approval/"+r.name);
			if(r.cmd == "turn_away"){
				ss_ link;
				if(m_store->get("starport_of/"+r.name, link))
					m_store->remove(link);
				m_store->remove("starport_of/"+r.name);
				m_store->remove("auth/"+r.name);
			}
			log_i(MODULE, "%s: %s's Starport ID %s", cs(by), cs(r.name),
					r.cmd == "approve" ? "let in" : "turned away");
			result(r.cmd == "approve" ? r.name+" may join" :
					r.name+" was turned away");
		} else if(r.cmd == "setting"){
			if(r.name != "open_registration")
				return result("No such setting");
			m_access.open_registration = r.on;
			save_access();
			// A listing's access is derived from it (10g)
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				s->announce_soon();
			});
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
		m_store->set("own_password/"+name, "");
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

	// **Linking a Starport ID to one's own account** (10g): its logins land
	// on this account from then on, as a player moving between Starports
	// does. The data is the ID's token for this server.
	void on_link_starport(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(!m_store || it == m_peers.end() || it->second.name.empty())
			return;
		const ss_ name = it->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "accounts:link_result", pack(text));
		};
		starport_announce::IdLogin id;
		ss_ why = "This server does not take Starport IDs";
		starport_announce::access(m_server,
				[&](starport_announce::Interface *s){
			why = s->verify_id_token(packet.data, &id);
		});
		if(!why.empty())
			return result(why);
		const ss_ link = "starport/"+id.starport+"/"+id.sub;
		ss_ linked;
		if(m_store->get(link, linked))
			return result(linked == name ? "Already linked" :
					"That Starport ID is another account's here");
		ss_ old;
		if(m_store->get("starport_of/"+name, old))
			m_store->remove(old);
		else
			// An account of its own being linked: its password is known
			m_store->set("own_password/"+name, "");
		m_store->set(link, name);
		m_store->set("starport_of/"+name, link);
		log_i(MODULE, "%s linked a Starport ID of %s", cs(name),
				cs(id.starport));
		result("");
	}

	// -- TOTP ([STARPORT] 10a)

	ss_ totp_secret(const ss_ &name, const char *kind = "totp/")
	{
		ss_ data;
		return m_store && m_store->get(kind+name, data) ? data : ss_();
	}

	bool totp_on(const ss_ &name)
	{
		return !totp_secret(name).empty();
	}

	// The step each name last used, so a code is good once
	std::map<ss_, uint64_t> m_totp_last;

	bool check_totp(const ss_ &name, const ss_ &code)
	{
		const ss_ secret = totp_secret(name);
		if(secret.empty() || code.size() != 6)
			return false;
		const uint64_t now = (uint64_t)(interface::os::time_us() / 1000000) /
				30;
		// One step either way, for a clock a little off
		for(uint64_t c = now - 1; c <= now + 1; c++){
			if(hotp(secret, c) == code && c > m_totp_last[name]){
				m_totp_last[name] = c;
				return true;
			}
		}
		return false;
	}

	// A new secret, pending until its first code: base32
	ss_ totp_begin(const ss_ &name)
	{
		std::random_device rd;
		ss_ secret(20, '\0');
		for(char &c : secret)
			c = (char)(rd() & 0xff);
		m_store->set("totp_pending/"+name, secret);
		return base32(secret);
	}

	ss_ totp_confirm(const ss_ &name, const ss_ &code)
	{
		const ss_ secret = totp_secret(name, "totp_pending/");
		if(secret.empty())
			return "Nothing to confirm: begin again";
		m_store->set("totp/"+name, secret);
		if(!check_totp(name, code)){
			m_store->remove("totp/"+name);
			return "Wrong code: check the app's time and try again";
		}
		m_store->remove("totp_pending/"+name);
		log_i(MODULE, "%s turned TOTP on", cs(name));
		return "";
	}

	ss_ totp_off(const ss_ &name, const ss_ &code)
	{
		if(!totp_on(name))
			return "";
		if(!check_totp(name, code))
			return "Wrong code";
		m_store->remove("totp/"+name);
		log_i(MODULE, "%s turned TOTP off", cs(name));
		return "";
	}

	ss_ totp_uri(const ss_ &name, const ss_ &secret_b32)
	{
		ss_ issuer = m_server->get_app_id();
		return "otpauth://totp/"+issuer+":"+name+"?secret="+secret_b32+
				"&issuer="+issuer;
	}

	void on_totp(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		TotpRequest req;
		if(!m_store || it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, req))
			return;
		const ss_ name = it->second.name;
		TotpResult r;
		if(req.cmd == "begin"){
			r.secret = totp_begin(name);
			r.uri = totp_uri(name, r.secret);
		} else if(req.cmd == "confirm"){
			r.error = totp_confirm(name, req.code);
			// Still pending: the key again, to try once more
			const ss_ pending = totp_secret(name, "totp_pending/");
			if(!r.error.empty() && !pending.empty()){
				r.secret = base32(pending);
				r.uri = totp_uri(name, r.secret);
			}
		} else if(req.cmd == "off"){
			r.error = totp_off(name, req.code);
		} else if(req.cmd != "status"){
			r.error = "No such TOTP command";
		}
		r.on = totp_on(name) ? 1 : 0;
		send(packet.sender, "accounts:totp_result", pack(r));
	}

	// -- What a Starport (apps/starport) asks of its own server's accounts
	// ([STARPORT] 10): a Starport ID is an account here

	// [STARPORT] 10d: a ban to report to the Starport the account's ID is
	// of; "" when it will be, else why not
	ss_ report_ban(const ss_ &name, const ss_ &reason)
	{
		ss_ link;
		if(!m_store->get("starport_of/"+name, link))
			return "not reported: not a Starport ID's account";
		m_store->set("ban_report/"+name, reason.empty() ? ss_("other") :
				reason);
		return "";
	}

	bool id_blocked(const ss_ &name)
	{
		ss_ link;
		if(!m_store->get("starport_of/"+name, link))
			return false;
		const size_t a = link.find('/'), b = link.rfind('/');
		if(a == ss_::npos || b <= a)
			return false;
		bool blocked = false;
		starport_announce::access(m_server,
				[&](starport_announce::Interface *s){
			blocked = s->is_blocked(link.substr(a + 1, b - a - 1),
					link.substr(b + 1));
		});
		return blocked;
	}

	bool registration_open()
	{
		return m_access.open_registration != 0;
	}

	size_t linked_count(const ss_ &host)
	{
		return m_store ? m_store->list("starport/"+host+"/").size() : 0;
	}

	sv_<ss_> reported_bans()
	{
		sv_<ss_> out;
		if(!m_store)
			return out;
		for(const ss_ &key : m_store->list("ban_report/")){
			const ss_ name = key.substr(11);
			ss_ link, reason;
			if(!m_store->get("starport_of/"+name, link) ||
					!m_store->get(key, reason))
				continue;
			// starport/<host>/<sub>
			const size_t a = link.find('/'), b = link.rfind('/');
			if(a == ss_::npos || b <= a)
				continue;
			out.push_back(link.substr(a + 1, b - a - 1)+"|"+
					link.substr(b + 1)+"|"+reason);
		}
		return out;
	}

	ss_ create_account(const ss_ &name, const ss_ &password)
	{
		if(!m_store)
			return "Not ready";
		if(!valid_name(name) || reserved_name(name))
			return "A name is 1 to 20 letters, digits, _ or -, and not "
					"client<digits>";
		if(exists(name))
			return "That name is taken";
		if(password.size() < MIN_PASSWORD || password.size() > 100)
			return "A password is "+itos((int)MIN_PASSWORD)+
					" to 100 characters";
		set_account(name, new_account(password, {}));
		log_i(MODULE, "New account %s (Starport ID)", cs(name));
		return "";
	}

	bool check_password(const ss_ &name, const ss_ &password)
	{
		Account account;
		return get_account(name, account) && password.size() <= 100 &&
				pbkdf2_sha256(password, account.salt, PBKDF2_ITERATIONS) ==
				account.hash;
	}

	ss_ set_password(const ss_ &name, const ss_ &password)
	{
		Account account;
		if(!get_account(name, account))
			return "No such account";
		if(password.size() < MIN_PASSWORD || password.size() > 100)
			return "A password is "+itos((int)MIN_PASSWORD)+
					" to 100 characters";
		set_account(name, new_account(password, account.privs));
		return "";
	}

	ss_ delete_account(const ss_ &name)
	{
		if(!exists(name))
			return "No such account";
		m_store->remove("auth/"+name);
		m_store->remove("totp/"+name);
		m_store->remove("totp_pending/"+name);
		log_i(MODULE, "Account %s deleted", cs(name));
		return "";
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
