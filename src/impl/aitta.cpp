// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/aitta.h"
#include "interface/bignum.h"
#include "interface/compress.h"
#include "interface/fs.h"
#include "interface/sha256.h"
#include "interface/zip.h"
#include "core/log.h"
#include "zlib.h"
#include <mbedtls/ecdsa.h>
#include <mbedtls/ecp.h>
#include <cstring>
#include <fstream>
#include <sstream>
#define MODULE "aitta"

namespace interface {
namespace aitta {

static const char *KEY_HEADER = "aitta-key-1 ";
static const char *SIG_FORMAT = "aitta-release-1";

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	if(!f.good())
		throw Exception("cannot read "+path);
	std::ostringstream os;
	os<<f.rdbuf();
	return os.str();
}

static void write_file(const ss_ &path, const ss_ &data)
{
	std::ofstream f(path, std::ios::binary);
	f<<data;
	if(!f.good())
		throw Exception("cannot write "+path);
}

static ss_ unhex(const ss_ &h)
{
	if(h.size() % 2)
		throw Exception("odd-length hex");
	ss_ out;
	for(size_t i = 0; i < h.size(); i += 2){
		auto nib = [&](char c) -> int {
			if(c >= '0' && c <= '9') return c - '0';
			if(c >= 'a' && c <= 'f') return c - 'a' + 10;
			if(c >= 'A' && c <= 'F') return c - 'A' + 10;
			throw Exception("not hex");
		};
		out += (char)(nib(h[i]) * 16 + nib(h[i + 1]));
	}
	return out;
}

static int rng(void*, unsigned char *out, size_t len)
{
	const ss_ r = bignum::random_bytes(len);
	memcpy(out, r.data(), len);
	return 0;
}

// What is signed: the format and the data's hash, so that a signature
// over something else is never one over a release
static ss_ digest(const ss_ &data)
{
	return sha256::calculate(ss_(SIG_FORMAT)+"\n"+
			sha256::hex(sha256::calculate(data)));
}

struct Keypair {
	mbedtls_ecp_keypair kp;
	Keypair(){ mbedtls_ecp_keypair_init(&kp); }
	~Keypair(){ mbedtls_ecp_keypair_free(&kp); }
	ss_ public_hex(){
		unsigned char buf[100];
		size_t n = 0;
		if(mbedtls_ecp_write_public_key(&kp, MBEDTLS_ECP_PF_UNCOMPRESSED,
				&n, buf, sizeof buf) != 0)
			throw Exception("cannot write the public key");
		return sha256::hex(ss_((char*)buf, n));
	}
};

static void load_key(Keypair &k, const ss_ &key_file_text)
{
	const ss_ head = KEY_HEADER;
	ss_ t = key_file_text;
	while(!t.empty() && (t.back() == '\n' || t.back() == '\r' || t.back() == ' '))
		t.pop_back();
	if(t.compare(0, head.size(), head) != 0)
		throw Exception("not an aitta key (no \""+head+"\")");
	const ss_ d = unhex(t.substr(head.size()));
	if(mbedtls_ecp_read_key(MBEDTLS_ECP_DP_SECP256R1, &k.kp,
			(const unsigned char*)d.data(), d.size()) != 0 ||
			mbedtls_ecp_keypair_calc_public(&k.kp, rng, nullptr) != 0)
		throw Exception("a bad aitta key");
}

void keygen(ss_ &key_file_text, ss_ &public_hex)
{
	Keypair k;
	if(mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, &k.kp, rng, nullptr) != 0)
		throw Exception("cannot make a key");
	unsigned char d[32];
	size_t n = 0;
	if(mbedtls_ecp_write_key_ext(&k.kp, &n, d, sizeof d) != 0)
		throw Exception("cannot write the key");
	key_file_text = ss_(KEY_HEADER)+sha256::hex(ss_((char*)d, n))+"\n";
	public_hex = k.public_hex();
}

ss_ public_of(const ss_ &key_file_text)
{
	Keypair k;
	load_key(k, key_file_text);
	return k.public_hex();
}

ss_ sign(const ss_ &key_file_text, const ss_ &data)
{
	Keypair k;
	load_key(k, key_file_text);
	mbedtls_ecdsa_context ctx;
	mbedtls_ecdsa_init(&ctx);
	const ss_ h = digest(data);
	unsigned char sig[MBEDTLS_ECDSA_MAX_LEN];
	size_t n = 0;
	int r = mbedtls_ecdsa_from_keypair(&ctx, &k.kp);
	if(r == 0)
		r = mbedtls_ecdsa_write_signature(&ctx, MBEDTLS_MD_SHA256,
				(const unsigned char*)h.data(), h.size(), sig, sizeof sig, &n,
				rng, nullptr);
	mbedtls_ecdsa_free(&ctx);
	if(r != 0)
		throw Exception("cannot sign");
	return sha256::hex(ss_((char*)sig, n));
}

bool verify(const ss_ &public_hex, const ss_ &data, const ss_ &signature_hex)
{
	ss_ q, sig;
	try {
		q = unhex(public_hex);
		sig = unhex(signature_hex);
	} catch(std::exception &){
		return false;
	}
	Keypair k;
	mbedtls_ecp_group grp;
	mbedtls_ecp_point pt;
	mbedtls_ecp_group_init(&grp);
	mbedtls_ecp_point_init(&pt);
	mbedtls_ecdsa_context ctx;
	mbedtls_ecdsa_init(&ctx);
	const ss_ h = digest(data);
	bool ok = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) == 0 &&
			mbedtls_ecp_point_read_binary(&grp, &pt,
				(const unsigned char*)q.data(), q.size()) == 0 &&
			mbedtls_ecp_set_public_key(MBEDTLS_ECP_DP_SECP256R1, &k.kp, &pt) == 0 &&
			mbedtls_ecdsa_from_keypair(&ctx, &k.kp) == 0 &&
			mbedtls_ecdsa_read_signature(&ctx,
				(const unsigned char*)h.data(), h.size(),
				(const unsigned char*)sig.data(), sig.size()) == 0;
	mbedtls_ecdsa_free(&ctx);
	mbedtls_ecp_point_free(&pt);
	mbedtls_ecp_group_free(&grp);
	return ok;
}

// A name a path is made of: a directory under <user>/installed
static bool plain_name(const ss_ &s, bool dots)
{
	if(s.empty() || s.size() > 40 || s == "." || s == "..")
		return false;
	for(char c : s){
		const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
				c == '_' || (dots && ((c >= 'A' && c <= 'Z') || c == '.' ||
					c == '-' || c == '+'));
		if(!ok)
			return false;
	}
	return true;
}

ss_ check_manifest(const json::Value &m)
{
	if(!m.is_object())
		return "meta.json is not an object";
	auto str = [&](const char *k) -> ss_ {
		const json::Value &v = m.get(k);
		return v.is_string() ? v.as_string() : "";
	};
	if(!plain_name(str("author"), false))
		return "\"author\": 1 to 40 of a-z, 0-9 and _";
	if(!plain_name(str("name"), false))
		return "\"name\": 1 to 40 of a-z, 0-9 and _";
	if(!plain_name(str("version"), true))
		return "\"version\": 1 to 40 of letters, digits, . - + and _";
	const json::Value &api = m.get("engine_api");
	if(!api.is_integer() || api.as_integer() < 1)
		return "\"engine_api\": the engine API it is written against, 1 or more";
	if(api.as_integer() > ENGINE_API)
		return "it needs engine API "+itos((int)api.as_integer())+
				" and this engine has "+itos(ENGINE_API);
	if(str("license_code").empty() || str("license_media").empty())
		return "\"license_code\" and \"license_media\": its licences";
	if(str("description").size() > 300)
		return "\"description\": 300 characters at most";
	return "";
}

// A zip of every file under dir, deflated, '/' separated; names that start
// with '.' are left out (.git and the like)
static void collect(const ss_ &dir, const ss_ &prefix, sv_<ss_> &out)
{
	for(const fs::Node &n : fs::list_directory(dir)){
		if(n.name.empty() || n.name[0] == '.')
			continue;
		if(n.is_directory)
			collect(dir+"/"+n.name, prefix+n.name+"/", out);
		else
			out.push_back(prefix+n.name);
	}
}

static void le(ss_ &o, uint32_t v, int bytes)
{
	for(int i = 0; i < bytes; i++)
		o += (char)((v >> (8 * i)) & 0xff);
}

static ss_ zip_directory(const ss_ &dir)
{
	sv_<ss_> names;
	collect(dir, "", names);
	ss_ out, central;
	for(const ss_ &name : names){
		const ss_ data = read_file(dir+"/"+name);
		std::ostringstream os(std::ios::binary);
		compress_deflate_raw(data, os);
		const ss_ packed = os.str();
		const uint32_t crc = crc32(0, (const Bytef*)data.data(), data.size());
		const uint32_t offset = out.size();
		// simplified: no zip64, so 4 GB at most; an app is nowhere near
		if(out.size() + packed.size() > 0xffffffffu)
			throw Exception("the archive would pass 4 GB");
		ss_ common;
		le(common, 20, 2); le(common, 0, 2); le(common, 8, 2); // deflate
		le(common, 0, 2); le(common, 0x21, 2); // a fixed time and date
		le(common, crc, 4); le(common, packed.size(), 4);
		le(common, data.size(), 4); le(common, name.size(), 2);
		le(common, 0, 2);
		out += "PK\x03\x04"+common+name+packed;
		central += ss_("PK\x01\x02")+'\x14'+'\x00'+common;
		le(central, 0, 2); le(central, 0, 2); le(central, 0, 2);
		le(central, 0, 4); le(central, offset, 4);
		central += name;
	}
	const uint32_t at = out.size();
	out += central;
	out += "PK\x05\x06";
	le(out, 0, 4); le(out, names.size(), 2); le(out, names.size(), 2);
	le(out, central.size(), 4); le(out, at, 4); le(out, 0, 2);
	return out;
}

ss_ pack(const ss_ &app_dir, const ss_ &key_path, const ss_ &out_dir)
{
	json::json_error_t e;
	const json::Value m = json::load_file((app_dir+"/meta.json").c_str(), &e);
	const ss_ why = check_manifest(m);
	if(!why.empty())
		throw Exception(app_dir+"/meta.json: "+why);
	const ss_ key = read_file(key_path);
	const ss_ zip = zip_directory(app_dir);
	const ss_ base = out_dir+"/"+m.get("author").as_string()+"-"+
			m.get("name").as_string()+"-"+m.get("version").as_string();
	json::Value sig = json::object();
	sig.set("format", SIG_FORMAT);
	sig.set("sha256", sha256::hex(sha256::calculate(zip)));
	sig.set("key", public_of(key));
	sig.set("signature", sign(key, zip));
	fs::create_directories(out_dir);
	write_file(base+".zip", zip);
	write_file(base+".sig", sig.stringify()+"\n");
	return base+".zip";
}

ss_ install(const ss_ &zip_path, const ss_ &sig_path, const ss_ &user_path)
{
	const ss_ zip = read_file(zip_path);
	json::json_error_t e;
	const json::Value sig = json::load_file(sig_path.c_str(), &e);
	auto sstr = [&](const char *k) -> ss_ {
		const json::Value &v = sig.get(k);
		return v.is_string() ? v.as_string() : "";
	};
	if(sstr("format") != SIG_FORMAT)
		throw Exception("not a release's .sig ("+ss_(SIG_FORMAT)+")");
	if(sstr("sha256") != sha256::hex(sha256::calculate(zip)))
		throw Exception("the archive is not the one the .sig is for");
	if(!verify(sstr("key"), zip, sstr("signature")))
		throw Exception("the signature does not match the archive");

	// Unpacked beside where it goes, and moved into place once its
	// manifest has been read: nothing half there under its own name
	const ss_ installed = user_path+"/installed";
	const ss_ incoming = installed+"/.incoming-"+
			sha256::hex(bignum::random_bytes(8));
	fs::create_directories(incoming);
	try {
		zip_extract(zip_path, incoming);
		const json::Value m = json::load_file((incoming+"/meta.json").c_str(), &e);
		const ss_ why = check_manifest(m);
		if(!why.empty())
			throw Exception("meta.json: "+why);
		const ss_ app = installed+"/"+m.get("author").as_string()+"/"+
				m.get("name").as_string();
		const ss_ dir = app+"/"+m.get("version").as_string();
		if(fs::path_exists(dir))
			throw Exception("already installed: "+dir);
		// The first install's key is the app's: a later version signed by
		// another is someone else's (trust on first install)
		fs::create_directories(app);
		const ss_ key_file = app+"/key";
		if(fs::path_exists(key_file)){
			ss_ known = read_file(key_file);
			while(!known.empty() && (known.back() == '\n' || known.back() == '\r'))
				known.pop_back();
			if(known != sstr("key"))
				throw Exception("signed by another key than the installed "
						"versions of "+m.get("author").as_string()+"/"+
						m.get("name").as_string());
		} else {
			write_file(key_file, sstr("key")+"\n");
		}
		if(!fs::rename(incoming, dir))
			throw Exception("cannot move it into "+dir);
		// Inside, where the app's boxed server can read it to pin a save
		write_file(dir+"/.aitta_sha256", sstr("sha256")+"\n");
		return dir;
	} catch(...){
		fs::remove_all(incoming);
		throw;
	}
}

}
}
// vim: set noet ts=4 sw=4:
