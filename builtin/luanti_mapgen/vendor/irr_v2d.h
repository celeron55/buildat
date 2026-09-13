// A shim, not Luanti's: see README.txt.
#pragma once
#include "irrlichttypes.h"

namespace core {

template<class T> class vector2d
{
public:
	T X, Y;

	constexpr vector2d(): X(0), Y(0){}
	vector2d(T x, T y): X(x), Y(y){}

	vector2d operator+(const vector2d &o) const {
		return vector2d(X + o.X, Y + o.Y);
	}
	vector2d operator-(const vector2d &o) const {
		return vector2d(X - o.X, Y - o.Y);
	}
	bool operator==(const vector2d &o) const { return X == o.X && Y == o.Y; }
	bool operator!=(const vector2d &o) const { return !(*this == o); }
};

} // namespace core

typedef core::vector2d<s16> v2s16;
typedef core::vector2d<s32> v2s32;
typedef core::vector2d<f32> v2f;
