// A shim, not Luanti's: see README.txt.
//
// Irrlicht's 4x4 matrix, as much of it as the tree generator uses: it
// builds its own rotation into one element by element, multiplies matrices
// together as it walks a branch, and reads the elements back out. Row
// major, sixteen floats, which is the layout Irrlicht's own is in and what
// treegen.cpp indexes.
#ifndef LUANTI_SHIM_IRR_MATRIX4_H
#define LUANTI_SHIM_IRR_MATRIX4_H
#include "irrlichttypes.h"
#include "irr_v3d.h"

namespace core {

class matrix4
{
public:
	matrix4(){ makeIdentity(); }

	f32& operator[](u32 i){ return M[i]; }
	const f32& operator[](u32 i) const { return M[i]; }

	matrix4& makeIdentity(){
		for(u32 i = 0; i < 16; i++)
			M[i] = 0.0f;
		M[0] = M[5] = M[10] = M[15] = 1.0f;
		return *this;
	}

	matrix4 operator*(const matrix4 &o) const {
		matrix4 r;
		for(u32 i = 0; i < 4; i++){
			for(u32 j = 0; j < 4; j++){
				f32 sum = 0.0f;
				for(u32 k = 0; k < 4; k++)
					sum += M[i * 4 + k] * o.M[k * 4 + j];
				r.M[i * 4 + j] = sum;
			}
		}
		return r;
	}

	matrix4& operator*=(const matrix4 &o){
		*this = *this * o;
		return *this;
	}

	// A direction through the matrix, with no translation: what a branch's
	// orientation does to a vector
	void rotateVect(v3f &v) const {
		const v3f in = v;
		v.X = in.X * M[0] + in.Y * M[4] + in.Z * M[8];
		v.Y = in.X * M[1] + in.Y * M[5] + in.Z * M[9];
		v.Z = in.X * M[2] + in.Y * M[6] + in.Z * M[10];
	}

	f32 M[16];
};

} // namespace core

typedef core::matrix4 matrix4;

#endif
