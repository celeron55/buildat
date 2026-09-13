// A shim, not Luanti's: see README.txt.
//
// Irrlicht's vector3d, as much of it as the mapgen uses. The names are
// Irrlicht's -- X, Y, Z rather than x, y, z -- because that is what the
// vendored code is written against.
#pragma once
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
	vector3d operator-(const vector3d &o) const {
		return vector3d(X - o.X, Y - o.Y, Z - o.Z);
	}
	vector3d operator-() const { return vector3d(-X, -Y, -Z); }
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
	T getLength() const { return (T)std::sqrt(
			(double)X * X + (double)Y * Y + (double)Z * Z); }
	double getLengthSQ() const {
		return (double)X * X + (double)Y * Y + (double)Z * Z;
	}
	vector3d& set(T x, T y, T z){ X = x; Y = y; Z = z; return *this; }
};

} // namespace core

typedef core::vector3d<s16> v3s16;
typedef core::vector3d<s32> v3s32;
typedef core::vector3d<f32> v3f;
typedef core::vector3d<double> v3d;
