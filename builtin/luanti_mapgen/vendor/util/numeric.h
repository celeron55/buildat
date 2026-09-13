// A shim, not Luanti's: see ../README.txt.
#pragma once
#include "../irrlichttypes_bloated.h"
#include "basic_macros.h"
#include <cmath>
#include <algorithm>

// Keep a value inside a range, which is what a mapgen does to everything it
// reads out of a setting
template<typename T> inline T rangelim(T d, T min, T max)
{
	return d < min ? min : (d > max ? max : d);
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

inline void sortBoxVerticies(v3s16 &p1, v3s16 &p2)
{
	if(p1.X > p2.X) std::swap(p1.X, p2.X);
	if(p1.Y > p2.Y) std::swap(p1.Y, p2.Y);
	if(p1.Z > p2.Z) std::swap(p1.Z, p2.Z);
}
