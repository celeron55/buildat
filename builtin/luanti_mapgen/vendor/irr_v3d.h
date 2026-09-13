// A shim, not Luanti's: see README.txt.
//
// Irrlicht's vector3d, as much of it as the mapgen uses. The names are
// Irrlicht's -- X, Y, Z rather than x, y, z -- because that is what the
// vendored code is written against.
#ifndef LUANTI_SHIM_IRR_V3D_H
#define LUANTI_SHIM_IRR_V3D_H
#include "irrlichttypes.h"
#include <cmath>
#include <algorithm>

namespace core {

template<class T> class vector3d
{
public:
	T X, Y, Z;

	constexpr vector3d(): X(0), Y(0), Z(0){}
	constexpr vector3d(T x, T y, T z): X(x), Y(y), Z(z){}
	explicit vector3d(T n): X(n), Y(n), Z(n){}
	template<class U> explicit vector3d(const vector3d<U> &o):
		X((T)o.X), Y((T)o.Y), Z((T)o.Z){}

	vector3d operator+(const vector3d &o) const {
		return vector3d(X + o.X, Y + o.Y, Z + o.Z);
	}
	// A vector of another kind on the right, which Luanti's code writes
	// where an integer vector meets a float one
	template<class U> vector3d operator+(const vector3d<U> &o) const {
		return vector3d((T)(X + o.X), (T)(Y + o.Y), (T)(Z + o.Z));
	}
	template<class U> vector3d operator-(const vector3d<U> &o) const {
		return vector3d((T)(X - o.X), (T)(Y - o.Y), (T)(Z - o.Z));
	}
	vector3d operator-(const vector3d &o) const {
		return vector3d(X - o.X, Y - o.Y, Z - o.Z);
	}
	vector3d operator-() const { return vector3d(-X, -Y, -Z); }
	vector3d operator+(const T n) const {
		return vector3d(X + n, Y + n, Z + n);
	}
	vector3d operator-(const T n) const {
		return vector3d(X - n, Y - n, Z - n);
	}
	vector3d operator*(T n) const { return vector3d(X * n, Y * n, Z * n); }
	vector3d operator*(const vector3d &o) const {
		return vector3d(X * o.X, Y * o.Y, Z * o.Z);
	}
	vector3d operator/(T n) const { return vector3d(X / n, Y / n, Z / n); }
	vector3d operator/(const vector3d &o) const {
		return vector3d(X / o.X, Y / o.Y, Z / o.Z);
	}
	vector3d& operator+=(const vector3d &o){
		X += o.X; Y += o.Y; Z += o.Z; return *this;
	}
	vector3d& operator-=(const vector3d &o){
		X -= o.X; Y -= o.Y; Z -= o.Z; return *this;
	}
	vector3d& operator*=(T n){ X *= n; Y *= n; Z *= n; return *this; }
	vector3d& operator/=(T n){ X /= n; Y /= n; Z /= n; return *this; }
	bool operator==(const vector3d &o) const {
		return X == o.X && Y == o.Y && Z == o.Z;
	}
	bool operator!=(const vector3d &o) const { return !(*this == o); }
	// Irrlicht's ordering, which a std::map of these wants
	bool operator<(const vector3d &o) const {
		if(Z != o.Z) return Z < o.Z;
		if(Y != o.Y) return Y < o.Y;
		return X < o.X;
	}
	// Luanti's own converter between the integer and float vectors
	template<class U> static vector3d from(const vector3d<U> &o){
		return vector3d((T)o.X, (T)o.Y, (T)o.Z);
	}
	T getLength() const { return (T)std::sqrt(
			(double)X * X + (double)Y * Y + (double)Z * Z); }
	double getLengthSQ() const {
		return (double)X * X + (double)Y * Y + (double)Z * Z;
	}
	vector3d& set(T x, T y, T z){ X = x; Y = y; Z = z; return *this; }
};

template<class T> inline T clamp(const T &value, const T &low,
		const T &high)
{
	return value < low ? low : (value > high ? high : value);
}

} // namespace core

namespace video {

// Irrlicht's colour, which is what a serialized colour is read into.
// Stored the way Irrlicht stores it: alpha, red, green, blue in one word.
class SColor
{
public:
	SColor(): color(0){}
	SColor(u32 c): color(c){}
	SColor(u32 a, u32 r, u32 g, u32 b):
		color(((a & 0xff) << 24) | ((r & 0xff) << 16) |
				((g & 0xff) << 8) | (b & 0xff)){}

	u32 getAlpha() const { return color >> 24; }
	u32 getRed() const { return (color >> 16) & 0xff; }
	u32 getGreen() const { return (color >> 8) & 0xff; }
	u32 getBlue() const { return color & 0xff; }
	void setAlpha(u32 a){ color = (color & 0x00ffffff) | ((a & 0xff) << 24); }
	void setRed(u32 r){ color = (color & 0xff00ffff) | ((r & 0xff) << 16); }
	void setGreen(u32 g){ color = (color & 0xffff00ff) | ((g & 0xff) << 8); }
	void setBlue(u32 b){ color = (color & 0xffffff00) | (b & 0xff); }
	u32 getData() const { return color; }
	void setData(u32 c){ color = c; }
	bool operator==(const SColor &o) const { return color == o.color; }
	bool operator!=(const SColor &o) const { return color != o.color; }

	u32 color;
};

} // namespace video

typedef core::vector3d<s16> v3s16;
typedef core::vector3d<s32> v3s32;
typedef core::vector3d<f32> v3f;
typedef core::vector3d<double> v3d;

#endif
