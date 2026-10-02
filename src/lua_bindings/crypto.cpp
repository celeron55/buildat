// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Hashes and big integer arithmetic for Lua: the primitives that are too slow
// or too fiddly to write in Lua. What is built on them -- an SRP login, say --
// is written in Lua.
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/sha1.h"
#include "interface/sha256.h"
#include "interface/bignum.h"
#include <mbedtls/ssl.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/gcm.h>
#include <mbedtls/pkcs5.h>
#include <mbedtls/error.h>
#include <qrcodegen.h>
#include <algorithm>
#include <cstring>
#include <map>
#include <memory>
#define MODULE "lua_bindings"

namespace lua_bindings {

// sha1(data: string) -> 20 bytes
static int l_sha1(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	ss_ digest = interface::sha1::calculate(data);
	lua_pushlstring(L, digest.c_str(), digest.size());
	return 1;
}

// sha256(data: string) -> 32 bytes
static int l_sha256(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	ss_ digest = interface::sha256::calculate(data);
	lua_pushlstring(L, digest.c_str(), digest.size());
	return 1;
}

// hex(data: string) -> string
static int l_hex(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	ss_ hex = interface::sha256::hex(data);
	lua_pushlstring(L, hex.c_str(), hex.size());
	return 1;
}

// Bignum primitives; numbers are big-endian byte strings. The composition on
// top of these -- SRP's hashing and padding, say -- belongs in Lua.

// bignum_add(a, b) -> a + b
static int l_bignum_add(lua_State *L)
{
	ss_ r = interface::bignum::add(lua_checkcppstring(L, 1),
			lua_checkcppstring(L, 2));
	lua_pushlstring(L, r.c_str(), r.size());
	return 1;
}

// bignum_mul(a, b) -> a * b
static int l_bignum_mul(lua_State *L)
{
	ss_ r = interface::bignum::mul(lua_checkcppstring(L, 1),
			lua_checkcppstring(L, 2));
	lua_pushlstring(L, r.c_str(), r.size());
	return 1;
}

// bignum_mod(a, m) -> a mod m
static int l_bignum_mod(lua_State *L)
{
	try {
		ss_ r = interface::bignum::mod(lua_checkcppstring(L, 1),
				lua_checkcppstring(L, 2));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_mod(): %s", e.what());
	}
	return 1;
}

// bignum_sub_mod(a, b, m) -> (a - b) mod m
static int l_bignum_sub_mod(lua_State *L)
{
	try {
		ss_ r = interface::bignum::sub_mod(lua_checkcppstring(L, 1),
				lua_checkcppstring(L, 2), lua_checkcppstring(L, 3));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_sub_mod(): %s", e.what());
	}
	return 1;
}

// bignum_mul_mod(a, b, m) -> (a * b) mod m
static int l_bignum_mul_mod(lua_State *L)
{
	try {
		ss_ r = interface::bignum::mul_mod(lua_checkcppstring(L, 1),
				lua_checkcppstring(L, 2), lua_checkcppstring(L, 3));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_mul_mod(): %s", e.what());
	}
	return 1;
}

// bignum_mod_exp(base, exponent, m) -> base^exponent mod m
static int l_bignum_mod_exp(lua_State *L)
{
	try {
		ss_ r = interface::bignum::mod_exp(lua_checkcppstring(L, 1),
				lua_checkcppstring(L, 2), lua_checkcppstring(L, 3));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_mod_exp(): %s", e.what());
	}
	return 1;
}

// random_bytes(n) -> n bytes from the platform's cryptographic random source
static int l_random_bytes(lua_State *L)
{
	int n = luaL_checkint(L, 1);
	if(n < 1 || n > 1024)
		return luaL_error(L, "random_bytes(): 1...1024 bytes, got %i", n);
	try {
		ss_ r = interface::bignum::random_bytes(n);
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "random_bytes(): %s", e.what());
	}
	return 1;
}

// -- [STARPORT] 10f: Mbed TLS, for the trusted side (client/extensions/network,
// client/extensions/starport); not in the sandbox

// seal(password, plain) -> a blob: a salt, PBKDF2-HMAC-SHA256 of the
// password (100000 rounds) as an AES-256-GCM key, the IV, the ciphertext
// and the tag. For the Starport ID tokens a client keeps (10c), opened by
// the password when the Starport cannot be reached.
static const int SEAL_ROUNDS = 100000;

static bool seal_key(const ss_ &password, const ss_ &salt, unsigned char *key)
{
	return mbedtls_pkcs5_pbkdf2_hmac_ext(MBEDTLS_MD_SHA256,
			(const unsigned char*)password.data(), password.size(),
			(const unsigned char*)salt.data(), salt.size(), SEAL_ROUNDS, 32,
			key) == 0;
}

static int l_seal(lua_State *L)
{
	const ss_ password = lua_checkcppstring(L, 1);
	const ss_ plain = lua_checkcppstring(L, 2);
	const ss_ salt = interface::bignum::random_bytes(16);
	const ss_ iv = interface::bignum::random_bytes(12);
	unsigned char key[32];
	if(!seal_key(password, salt, key))
		return luaL_error(L, "seal: PBKDF2 failed");
	ss_ out(plain.size(), '\0');
	unsigned char tag[16];
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int r = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 256);
	if(r == 0)
		r = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, plain.size(),
				(const unsigned char*)iv.data(), iv.size(), nullptr, 0,
				(const unsigned char*)plain.data(), (unsigned char*)&out[0],
				16, tag);
	mbedtls_gcm_free(&gcm);
	if(r != 0)
		return luaL_error(L, "seal: AES-GCM failed");
	const ss_ blob = salt+iv+out+ss_((const char*)tag, 16);
	lua_pushlstring(L, blob.data(), blob.size());
	return 1;
}

// unseal(password, blob) -> the plain text, or nil: a wrong password and a
// changed blob alike
static int l_unseal(lua_State *L)
{
	const ss_ password = lua_checkcppstring(L, 1);
	const ss_ blob = lua_checkcppstring(L, 2);
	if(blob.size() < 16 + 12 + 16)
		return 0;
	const ss_ salt = blob.substr(0, 16), iv = blob.substr(16, 12);
	const ss_ ct = blob.substr(28, blob.size() - 44);
	const ss_ tag = blob.substr(blob.size() - 16);
	unsigned char key[32];
	if(!seal_key(password, salt, key))
		return 0;
	ss_ out(ct.size(), '\0');
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int r = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 256);
	if(r == 0)
		r = mbedtls_gcm_auth_decrypt(&gcm, ct.size(),
				(const unsigned char*)iv.data(), iv.size(), nullptr, 0,
				(const unsigned char*)tag.data(), tag.size(),
				(const unsigned char*)ct.data(), (unsigned char*)&out[0]);
	mbedtls_gcm_free(&gcm);
	if(r != 0)
		return 0;
	lua_pushlstring(L, out.data(), out.size());
	return 1;
}

// **A TLS client over buffers** (10c): the web client's channel to a
// Starport goes through its server as bytes in packets, so the TLS is
// here, end to end, and the server relays what it cannot read. Lua moves
// the bytes; this keeps the state.
struct TlsSession
{
	mbedtls_ssl_context ssl;
	mbedtls_ssl_config conf;
	mbedtls_x509_crt ca;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_entropy_context entropy;
	ss_ in;  // ciphertext received, not yet read by TLS
	ss_ out; // ciphertext to send
	ss_ error;
	bool open = false;
	TlsSession(){
		mbedtls_ssl_init(&ssl);
		mbedtls_ssl_config_init(&conf);
		mbedtls_x509_crt_init(&ca);
		mbedtls_ctr_drbg_init(&drbg);
		mbedtls_entropy_init(&entropy);
	}
	~TlsSession(){
		mbedtls_ssl_free(&ssl);
		mbedtls_ssl_config_free(&conf);
		mbedtls_x509_crt_free(&ca);
		mbedtls_ctr_drbg_free(&drbg);
		mbedtls_entropy_free(&entropy);
	}
};
static std::map<int, std::unique_ptr<TlsSession>> g_tls;
static int g_tls_next = 1;

static int tls_send_cb(void *ctx, const unsigned char *buf, size_t len)
{
	((TlsSession*)ctx)->out.append((const char*)buf, len);
	return (int)len;
}
static int tls_recv_cb(void *ctx, unsigned char *buf, size_t len)
{
	TlsSession *t = (TlsSession*)ctx;
	if(t->in.empty())
		return MBEDTLS_ERR_SSL_WANT_READ;
	const size_t n = std::min(len, t->in.size());
	memcpy(buf, t->in.data(), n);
	t->in.erase(0, n);
	return (int)n;
}
static ss_ tls_error(int r)
{
	char buf[200];
	mbedtls_strerror(r, buf, sizeof buf);
	return buf;
}

// tls_new(host, ca_pem) -> a handle, or nil and why not. The certificate
// is checked against the PEM roots and the host's name.
static int l_tls_new(lua_State *L)
{
	const ss_ host = lua_checkcppstring(L, 1);
	const ss_ ca_pem = lua_checkcppstring(L, 2);
	std::unique_ptr<TlsSession> t(new TlsSession());
	int r = mbedtls_ctr_drbg_seed(&t->drbg, mbedtls_entropy_func, &t->entropy,
			nullptr, 0);
	if(r == 0)
		r = mbedtls_x509_crt_parse(&t->ca,
				(const unsigned char*)ca_pem.c_str(), ca_pem.size() + 1);
	// A bundle with a certificate it cannot read still has the rest
	if(r > 0)
		r = 0;
	if(r == 0)
		r = mbedtls_ssl_config_defaults(&t->conf, MBEDTLS_SSL_IS_CLIENT,
				MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
	if(r == 0){
		mbedtls_ssl_conf_authmode(&t->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
		mbedtls_ssl_conf_ca_chain(&t->conf, &t->ca, nullptr);
		mbedtls_ssl_conf_rng(&t->conf, mbedtls_ctr_drbg_random, &t->drbg);
		r = mbedtls_ssl_setup(&t->ssl, &t->conf);
	}
	if(r == 0)
		r = mbedtls_ssl_set_hostname(&t->ssl, host.c_str());
	if(r != 0){
		lua_pushnil(L);
		lua_pushstring(L, ("tls_new: "+tls_error(r)).c_str());
		return 2;
	}
	mbedtls_ssl_set_bio(&t->ssl, t.get(), tls_send_cb, tls_recv_cb, nullptr);
	const int h = g_tls_next++;
	g_tls[h] = std::move(t);
	lua_pushinteger(L, h);
	return 1;
}

// tls_step(handle, ciphertext_in, plain_out) -> ciphertext_out, plain_in,
// state: "handshake", "open", "closed" or "error: ..."
static int l_tls_step(lua_State *L)
{
	const int h = luaL_checkinteger(L, 1);
	auto it = g_tls.find(h);
	if(it == g_tls.end())
		return luaL_error(L, "tls_step: no such session");
	TlsSession *t = it->second.get();
	t->in += lua_isstring(L, 2) ? lua_tocppstring(L, 2) : ss_();
	const ss_ plain_out = lua_isstring(L, 3) ? lua_tocppstring(L, 3) : ss_();
	ss_ plain_in;
	ss_ state = "handshake";
	if(t->error.empty() && !t->open){
		const int r = mbedtls_ssl_handshake(&t->ssl);
		if(r == 0)
			t->open = true;
		else if(r != MBEDTLS_ERR_SSL_WANT_READ &&
				r != MBEDTLS_ERR_SSL_WANT_WRITE)
			t->error = tls_error(r);
	}
	if(t->error.empty() && t->open){
		size_t at = 0;
		while(at < plain_out.size()){
			const int r = mbedtls_ssl_write(&t->ssl,
					(const unsigned char*)plain_out.data() + at,
					plain_out.size() - at);
			if(r < 0){
				t->error = tls_error(r);
				break;
			}
			at += r;
		}
		for(;;){
			unsigned char buf[4096];
			const int r = mbedtls_ssl_read(&t->ssl, buf, sizeof buf);
			if(r > 0){
				plain_in.append((const char*)buf, r);
				continue;
			}
			if(r == 0 || r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
				state = "closed";
			else if(r != MBEDTLS_ERR_SSL_WANT_READ &&
					r != MBEDTLS_ERR_SSL_WANT_WRITE &&
					r != MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET)
				t->error = tls_error(r);
			if(r != MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET)
				break;
		}
		if(state != "closed")
			state = "open";
	}
	if(!t->error.empty())
		state = "error: "+t->error;
	lua_pushlstring(L, t->out.data(), t->out.size());
	t->out.clear();
	lua_pushlstring(L, plain_in.data(), plain_in.size());
	lua_pushstring(L, state.c_str());
	return 3;
}

static int l_tls_free(lua_State *L)
{
	g_tls.erase((int)luaL_checkinteger(L, 1));
	return 0;
}

// qr_code(text) -> the modules' bits as a string of '0' and '1', a row at a
// time from the top, and the side; or nil. A TOTP secret's otpauth:// link,
// shown to an authenticator app's camera ([STARPORT] 10a). Safe: it reads
// nothing and writes nothing.
static int l_qr_code(lua_State *L)
{
	const ss_ text = lua_checkcppstring(L, 1);
	uint8_t qr[qrcodegen_BUFFER_LEN_MAX];
	uint8_t tmp[qrcodegen_BUFFER_LEN_MAX];
	if(text.size() > 1000 || !qrcodegen_encodeText(text.c_str(), tmp, qr,
			qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX,
			qrcodegen_Mask_AUTO, true))
		return 0;
	const int n = qrcodegen_getSize(qr);
	ss_ bits;
	bits.reserve(n * n);
	for(int y = 0; y < n; y++)
		for(int x = 0; x < n; x++)
			bits += qrcodegen_getModule(qr, x, y) ? '1' : '0';
	lua_pushlstring(L, bits.data(), bits.size());
	lua_pushinteger(L, n);
	return 2;
}

void init_crypto(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(sha1)
	DEF_BUILDAT_FUNC(sha256)
	DEF_BUILDAT_FUNC(hex)
	DEF_BUILDAT_FUNC(bignum_add)
	DEF_BUILDAT_FUNC(bignum_mul)
	DEF_BUILDAT_FUNC(bignum_mod)
	DEF_BUILDAT_FUNC(bignum_sub_mod)
	DEF_BUILDAT_FUNC(bignum_mul_mod)
	DEF_BUILDAT_FUNC(bignum_mod_exp)
	DEF_BUILDAT_FUNC(random_bytes)
	DEF_BUILDAT_FUNC(seal)
	DEF_BUILDAT_FUNC(unseal)
	DEF_BUILDAT_FUNC(tls_new)
	DEF_BUILDAT_FUNC(tls_step)
	DEF_BUILDAT_FUNC(tls_free)
	DEF_BUILDAT_FUNC(qr_code)
}

} // namespace lua_bindings

// vim: set noet ts=4 sw=4:
