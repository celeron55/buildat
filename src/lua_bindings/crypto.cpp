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

void init_crypto(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
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
}

} // namespace lua_bindings

// vim: set noet ts=4 sw=4:
