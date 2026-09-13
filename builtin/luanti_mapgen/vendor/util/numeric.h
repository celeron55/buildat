// A shim, not Luanti's: see ../README.txt.
#ifndef LUANTI_SHIM_UTIL_NUMERIC_H
#define LUANTI_SHIM_UTIL_NUMERIC_H
#include "../irrlichttypes_bloated.h"
#include "basic_macros.h"
#include "../constants.h"
#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <cfloat>

// Keep a value inside a range, which is what a mapgen does to everything it
// reads out of a setting
template<typename T, typename U, typename V> inline T rangelim(T d, U min,
		V max)
{
	if(d < (T)min)
		return (T)min;
	if(d > (T)max)
		return (T)max;
	return d;
}

// -1...1 into 0...1 and back out again with the middle pulled apart, which
// is what a cave's noise is read through
inline float contour(float v)
{
	v = std::fabs(v);
	if(v >= 1.0f)
		return 0.0f;
	return (1.0f - v);
}

template<typename T> inline T myround(T f)
{
	return (T)std::floor(f + 0.5);
}

inline v3s16 floatToInt(v3f p, f32 d)
{
	return v3s16(
			(s16)myround(p.X / d),
			(s16)myround(p.Y / d),
			(s16)myround(p.Z / d));
}

inline v3f intToFloat(v3s16 p, f32 d)
{
	return v3f((f32)p.X * d, (f32)p.Y * d, (f32)p.Z * d);
}

// The block a node is in, and the corners of a block
inline s16 getContainerPos(s16 p, s16 d)
{
	return (p >= 0) ? (p / d) : ((p - d + 1) / d);
}

inline v3s16 getContainerPos(v3s16 p, s16 d)
{
	return v3s16(getContainerPos(p.X, d), getContainerPos(p.Y, d),
			getContainerPos(p.Z, d));
}

inline bool isInArea(v3s16 p, v3s16 d)
{
	return p.X >= 0 && p.X < d.X && p.Y >= 0 && p.Y < d.Y &&
			p.Z >= 0 && p.Z < d.Z;
}

// The parity of a number, and a run of bits out of one: what a mapgen uses
// them for is deciding where a thing goes from a seed
inline u32 calc_parity(u32 v)
{
	v ^= v >> 16;
	v ^= v >> 8;
	v ^= v >> 4;
	v &= 0xf;
	return (0x6996 >> v) & 1;
}

inline u32 get_bits(u32 x, u32 pos, u32 len)
{
	u32 mask = (1 << len) - 1;
	return (x >> pos) & mask;
}

inline void set_bits(u32 *x, u32 pos, u32 len, u32 val)
{
	u32 mask = ((1 << len) - 1) << pos;
	*x &= ~mask;
	*x |= (val << pos) & mask;
}

// Luanti's own quick pseudo-random, which a mapgen leans on where the
// result only has to be scattered rather than repeatable across builds
inline int myrand()
{
	return rand();
}

inline int myrand_range(int min, int max)
{
	if(max < min)
		return min;
	return min + (rand() % (max - min + 1));
}

inline float myrand_range(float min, float max)
{
	if(max < min)
		return min;
	return min + (max - min) * ((float)rand() / (float)RAND_MAX);
}

// The block a node is in, which is Luanti's own unit of sixteen
inline v3s16 getNodeBlockPos(const v3s16 &p)
{
	return getContainerPos(p, (s16)16);
}

inline void myrand_bytes(void *out, size_t len)
{
	u8 *p = (u8 *)out;
	for(size_t i = 0; i < len; i++)
		p[i] = (u8)(rand() & 0xff);
}

inline void sortBoxVerticies(v3s16 &p1, v3s16 &p2)
{
	if(p1.X > p2.X) std::swap(p1.X, p2.X);
	if(p1.Y > p2.Y) std::swap(p1.Y, p2.Y);
	if(p1.Z > p2.Z) std::swap(p1.Z, p2.Z);
}

#endif
