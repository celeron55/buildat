// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Big unsigned integers in 32-bit limbs, least significant first. Only what
// modular exponentiation needs: multiply, subtract, divide (Knuth's algorithm
// D) and square-and-multiply. Protocols that use this -- SRP, for one -- do
// their own hashing and formatting on top, in Lua.
//
// Self-check (it wants no Urho3D, so it builds on its own):
//   g++ -std=c++11 -DBIGNUM_SELF_TEST -Isrc -o /tmp/bignum_test \
//       src/impl/bignum.cpp && /tmp/bignum_test
#include "interface/bignum.h"
#include <vector>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

namespace interface {
namespace bignum {

// A 2048-bit modulus (SRP's group from RFC 5054) for the self-check to divide
// and exponentiate by
static const char *TEST_MODULUS_HEX =
	"AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294"
	"3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D"
	"CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB"
	"D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74"
	"7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A"
	"436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D"
	"5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73"
	"03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6"
	"94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F"
	"9E4AFF73";

struct Num
{
	std::vector<uint32_t> d;

	void trim()
	{
		while(!d.empty() && d.back() == 0)
			d.pop_back();
	}

	bool zero() const
	{
		return d.empty();
	}
};

static int cmp(const Num &a, const Num &b)
{
	if(a.d.size() != b.d.size())
		return a.d.size() < b.d.size() ? -1 : 1;
	for(size_t i = a.d.size(); i-- > 0;){
		if(a.d[i] != b.d[i])
			return a.d[i] < b.d[i] ? -1 : 1;
	}
	return 0;
}

static Num add(const Num &a, const Num &b)
{
	Num r;
	uint64_t carry = 0;
	size_t n = a.d.size() > b.d.size() ? a.d.size() : b.d.size();
	r.d.resize(n);
	for(size_t i = 0; i < n; i++){
		uint64_t s = carry;
		if(i < a.d.size())
			s += a.d[i];
		if(i < b.d.size())
			s += b.d[i];
		r.d[i] = (uint32_t)s;
		carry = s >> 32;
	}
	if(carry)
		r.d.push_back((uint32_t)carry);
	return r;
}

// a - b, with a >= b
static Num sub(const Num &a, const Num &b)
{
	Num r;
	r.d.resize(a.d.size());
	int64_t borrow = 0;
	for(size_t i = 0; i < a.d.size(); i++){
		int64_t t = (int64_t)a.d[i] - borrow - (i < b.d.size() ? (int64_t)b.d[i] : 0);
		if(t < 0){
			t += ((int64_t)1 << 32);
			borrow = 1;
		} else {
			borrow = 0;
		}
		r.d[i] = (uint32_t)t;
	}
	r.trim();
	return r;
}

static Num mul(const Num &a, const Num &b)
{
	Num r;
	if(a.zero() || b.zero())
		return r;
	r.d.assign(a.d.size() + b.d.size(), 0);
	for(size_t i = 0; i < a.d.size(); i++){
		uint64_t carry = 0;
		for(size_t j = 0; j < b.d.size(); j++){
			uint64_t t = (uint64_t)a.d[i] * b.d[j] + r.d[i + j] + carry;
			r.d[i + j] = (uint32_t)t;
			carry = t >> 32;
		}
		size_t k = i + b.d.size();
		while(carry){
			uint64_t t = (uint64_t)r.d[k] + carry;
			r.d[k] = (uint32_t)t;
			carry = t >> 32;
			k++;
		}
	}
	r.trim();
	return r;
}

static Num shl_bits(const Num &a, int bits)
{
	if(a.zero() || bits == 0)
		return a;
	Num r;
	r.d.assign(a.d.size() + 1, 0);
	for(size_t i = 0; i < a.d.size(); i++){
		uint64_t t = (uint64_t)a.d[i] << bits;
		r.d[i] |= (uint32_t)t;
		r.d[i + 1] |= (uint32_t)(t >> 32);
	}
	r.trim();
	return r;
}

static Num shr_bits(const Num &a, int bits)
{
	if(a.zero() || bits == 0)
		return a;
	Num r;
	r.d.assign(a.d.size(), 0);
	for(size_t i = 0; i < a.d.size(); i++){
		uint64_t t = (uint64_t)a.d[i] >> bits;
		if(bits && i + 1 < a.d.size())
			t |= (uint64_t)a.d[i + 1] << (32 - bits);
		r.d[i] = (uint32_t)t;
	}
	r.trim();
	return r;
}

// Knuth's algorithm D. q and r may be null.
static void divmod(const Num &u_in, const Num &v_in, Num *q_out, Num *r_out)
{
	if(v_in.zero())
		throw std::runtime_error("bignum: division by zero");
	if(cmp(u_in, v_in) < 0){
		if(q_out)
			q_out->d.clear();
		if(r_out)
			*r_out = u_in;
		return;
	}
	size_t n = v_in.d.size();
	if(n == 1){
		Num q;
		q.d.assign(u_in.d.size(), 0);
		uint64_t rem = 0;
		for(size_t i = u_in.d.size(); i-- > 0;){
			uint64_t cur = (rem << 32) | u_in.d[i];
			q.d[i] = (uint32_t)(cur / v_in.d[0]);
			rem = cur % v_in.d[0];
		}
		q.trim();
		if(q_out)
			*q_out = q;
		if(r_out){
			r_out->d.clear();
			if(rem)
				r_out->d.push_back((uint32_t)rem);
		}
		return;
	}

	// Normalize so that the divisor's top limb has its high bit set
	int shift = 0;
	while(!((v_in.d[n - 1] << shift) & 0x80000000u))
		shift++;
	Num v = shl_bits(v_in, shift);
	Num u = shl_bits(u_in, shift);
	size_t m = u.d.size() - n;
	u.d.push_back(0);

	Num q;
	q.d.assign(m + 1, 0);
	const uint64_t B = (uint64_t)1 << 32;
	for(size_t j = m + 1; j-- > 0;){
		uint64_t num = ((uint64_t)u.d[j + n] << 32) | u.d[j + n - 1];
		uint64_t qhat = num / v.d[n - 1];
		uint64_t rhat = num % v.d[n - 1];
		while(qhat >= B || qhat * v.d[n - 2] >
				((rhat << 32) | u.d[j + n - 2])){
			qhat--;
			rhat += v.d[n - 1];
			if(rhat >= B)
				break;
		}
		// u[j..j+n] -= qhat * v
		uint64_t carry = 0;
		int64_t borrow = 0;
		for(size_t i = 0; i < n; i++){
			uint64_t p = qhat * v.d[i] + carry;
			carry = p >> 32;
			int64_t t = (int64_t)u.d[i + j] - (int64_t)(uint32_t)p - borrow;
			u.d[i + j] = (uint32_t)t;
			borrow = (t < 0) ? 1 : 0;
		}
		int64_t t = (int64_t)u.d[j + n] - (int64_t)carry - borrow;
		u.d[j + n] = (uint32_t)t;
		if(t < 0){
			// qhat was one too big; add the divisor back
			qhat--;
			uint64_t c = 0;
			for(size_t i = 0; i < n; i++){
				uint64_t s = (uint64_t)u.d[i + j] + v.d[i] + c;
				u.d[i + j] = (uint32_t)s;
				c = s >> 32;
			}
			u.d[j + n] = (uint32_t)((uint64_t)u.d[j + n] + c);
		}
		q.d[j] = (uint32_t)qhat;
	}
	q.trim();
	if(q_out)
		*q_out = q;
	if(r_out){
		u.d.resize(n);
		u.trim();
		*r_out = shr_bits(u, shift);
	}
}

static Num mod(const Num &a, const Num &n)
{
	Num r;
	divmod(a, n, nullptr, &r);
	return r;
}

static Num mulm(const Num &a, const Num &b, const Num &n)
{
	return mod(mul(a, b), n);
}

static Num subm(const Num &a, const Num &b, const Num &n)
{
	// a - b mod n, with a and b already reduced
	Num a1 = mod(a, n);
	Num b1 = mod(b, n);
	if(cmp(a1, b1) < 0)
		return sub(add(a1, n), b1);
	return sub(a1, b1);
}

static Num powm(const Num &base, const Num &exp, const Num &n)
{
	Num result;
	result.d.push_back(1);
	Num b = mod(base, n);
	for(size_t limb = 0; limb < exp.d.size(); limb++){
		for(int bit = 0; bit < 32; bit++){
			if(limb * 32 + bit >= exp.d.size() * 32)
				break;
			if((exp.d[limb] >> bit) & 1)
				result = mulm(result, b, n);
			b = mulm(b, b, n);
		}
	}
	return mod(result, n);
}

static Num from_bytes(const ss_ &s)
{
	Num r;
	r.d.assign((s.size() + 3) / 4, 0);
	for(size_t i = 0; i < s.size(); i++){
		size_t from_end = s.size() - 1 - i;
		r.d[from_end / 4] |= (uint32_t)(unsigned char)s[i] << ((from_end % 4) * 8);
	}
	r.trim();
	return r;
}

// Big-endian, no leading zero bytes
static ss_ to_bytes(const Num &a)
{
	if(a.zero())
		return "";
	size_t bytes = a.d.size() * 4;
	while(bytes > 1 && ((a.d[(bytes - 1) / 4] >> (((bytes - 1) % 4) * 8)) & 0xff) == 0)
		bytes--;
	ss_ r(bytes, '\0');
	for(size_t i = 0; i < bytes; i++){
		size_t from_end = bytes - 1 - i;
		r[i] = (char)((a.d[from_end / 4] >> ((from_end % 4) * 8)) & 0xff);
	}
	return r;
}

static Num from_hex(const char *hex)
{
	ss_ bytes;
	size_t len = strlen(hex);
	size_t i = 0;
	if(len % 2){ // Odd number of digits: the first one is on its own
		bytes += (char)strtol(ss_(hex, 1).c_str(), nullptr, 16);
		i = 1;
	}
	for(; i + 1 < len; i += 2)
		bytes += (char)strtol(ss_(hex + i, 2).c_str(), nullptr, 16);
	return from_bytes(bytes);
}

ss_ random_bytes(size_t n)
{
	ss_ result(n, '\0');
#ifdef _WIN32
	// simplified: rand_s() is enough here and needs no crypto library. Upgrade
	// path if this grows into anything but SRP: BCryptGenRandom().
	for(size_t i = 0; i < n; i++){
		unsigned int v = 0;
		if(rand_s(&v) != 0)
			throw std::runtime_error("bignum: rand_s() failed");
		result[i] = (char)v;
	}
#else
	FILE *f = fopen("/dev/urandom", "rb");
	if(!f)
		throw std::runtime_error("bignum: cannot open /dev/urandom");
	size_t got = fread(&result[0], 1, n, f);
	fclose(f);
	if(got != n)
		throw std::runtime_error("bignum: short read from /dev/urandom");
#endif
	return result;
}


// The interface: byte strings in, byte strings out

ss_ add(const ss_ &a, const ss_ &b)
{
	return to_bytes(add(from_bytes(a), from_bytes(b)));
}

ss_ mul(const ss_ &a, const ss_ &b)
{
	return to_bytes(mul(from_bytes(a), from_bytes(b)));
}

ss_ mod(const ss_ &a, const ss_ &m)
{
	return to_bytes(mod(from_bytes(a), from_bytes(m)));
}

ss_ sub_mod(const ss_ &a, const ss_ &b, const ss_ &m)
{
	return to_bytes(subm(from_bytes(a), from_bytes(b), from_bytes(m)));
}

ss_ mul_mod(const ss_ &a, const ss_ &b, const ss_ &m)
{
	return to_bytes(mulm(from_bytes(a), from_bytes(b), from_bytes(m)));
}

ss_ mod_exp(const ss_ &base, const ss_ &exponent, const ss_ &m)
{
	return to_bytes(powm(from_bytes(base), from_bytes(exponent),
			from_bytes(m)));
}

} // namespace bignum
} // namespace interface

#ifdef BIGNUM_SELF_TEST
#include <cassert>
#include <iostream>

using namespace interface;

int main()
{
	using namespace interface::bignum;

	Num m = from_hex(TEST_MODULUS_HEX);
	// Multiply and divide against each other over sizes that make the
	// quotient estimate in divmod correct itself
	for(int i = 1; i < 40; i++){
		ss_ bytes;
		for(int j = 0; j < i * 13; j++)
			bytes += (char)((j * 37 + i * 11) & 0xff);
		Num a = from_bytes(bytes);
		Num q, r;
		divmod(a, m, &q, &r);
		assert(cmp(add(mul(q, m), r), a) == 0); // a == q*m + r
		assert(cmp(r, m) < 0);
		assert(to_bytes(from_bytes(to_bytes(a))) == to_bytes(a));
	}

	// Small answers that can be checked by hand
	assert(mod_exp(ss_(1, (char)3), ss_(1, (char)100), ss_(1, (char)7)) ==
			ss_(1, (char)4)); // 3^100 mod 7 == 4
	assert(mul_mod(ss_(1, (char)7), ss_(1, (char)8), ss_(1, (char)10)) ==
			ss_(1, (char)6));
	assert(sub_mod(ss_(1, (char)3), ss_(1, (char)8), ss_(1, (char)10)) ==
			ss_(1, (char)5)); // Wraps around
	assert(add(ss_(1, (char)255), ss_(1, (char)1)) ==
			ss_("\x01\x00", 2));
	assert(mod_exp(ss_(1, (char)2), "", ss_(1, (char)10)) == ss_(1, (char)1));
	assert(mod("", ss_(1, (char)10)) == ""); // Zero stays zero

	// 3^65537 mod the 2048-bit modulus, from Python's pow()
	const char *expect_hex =
			"2fc8fd900ca93db777c0fe109d3ad454629b306283f3baf608dbc7dc124b5f5a"
			"a31948ddff62646cdb7585fa261ddb51f3669d0cef8862a3ba767657bdedc327"
			"d9dff8528a189eee768bc336d83d12611868d2b72d43e11122dd8613bc5415ce"
			"b2d94c5554912ced3b591b4923134bbd146e92839a4ba291516d39c470aa0e78"
			"2ce31145f64911decb92eb6f396d0045385d87e4706fc51c7cd66753e774f5da"
			"ab759f410e98ecbb088f58b89660b5c103c36564cae672b1b36d7e88916dd903"
			"a7d0a3db587f5237d66cab6046e3b174a4dfbf26d70a012186b59610285712d8"
			"1d792cdc1456fabc5df7d1629785af2e837db3e4e3b50ab8110bef72f37ea729";
	assert(mod_exp(ss_(1, (char)3), ss_("\x01\x00\x01", 3), to_bytes(m)) ==
			to_bytes(from_hex(expect_hex)));

	// Randomness is not all the same byte, and gives the length asked for
	ss_ r1 = random_bytes(32);
	ss_ r2 = random_bytes(32);
	assert(r1.size() == 32 && r2.size() == 32 && r1 != r2);

	std::cout<<"bignum.cpp self-test: ok"<<std::endl;
	return 0;
}
#endif
// vim: set noet ts=4 sw=4:
