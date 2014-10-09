// Copyright 2010-2014 Perttu Ahola <celeron55@gmail.com>
// Copyright 2010-2013 kwolekr, Ryan Kwolek <kwolekr@minetest.net>
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
//
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#pragma once
#include "core/types.h"

namespace interface
{
	struct v3f
	{
		float X = 0;
		float Y = 0;
		float Z = 0;
		v3f(float X = 0, float Y = 0, float Z = 0):
			X(X), Y(Y), Z(Z){}
	};

	class PseudoRandom
	{
	public:
		PseudoRandom(): m_next(0)
		{}
		PseudoRandom(int seed): m_next(seed)
		{}
		void seed(int seed){
			m_next = seed;
		}
		// Returns 0...32767
		int next(){
			m_next = m_next * 1103515245 + 12345;
			return ((unsigned)(m_next/65536) % 32768);
		}
		int range(int min, int max);

	private:
		int m_next;
	};

	struct NoiseParams {
		float offset;
		float scale;
		v3f spread;
		int seed;
		int octaves;
		float persist;

		NoiseParams(){}

		NoiseParams(float offset_, float scale_, v3f spread_,
				int seed_, int octaves_, float persist_)
		{
			offset = offset_;
			scale = scale_;
			spread = spread_;
			seed = seed_;
			octaves = octaves_;
			persist = persist_;
		}
	};

	class Noise {
	public:
		NoiseParams *np;
		int seed;
		int sx;
		int sy;
		int sz;
		float *noisebuf;
		float *buf;
		float *result;

		Noise(NoiseParams *np, int seed, int sx, int sy);
		Noise(NoiseParams *np, int seed, int sx, int sy, int sz);
		virtual ~Noise();

		virtual void init(NoiseParams *np, int seed, int sx, int sy, int sz);
		void setSize(int sx, int sy);
		void setSize(int sx, int sy, int sz);
		void setSpreadFactor(v3f spread);
		void setOctaves(int octaves);
		void resizeNoiseBuf(bool is3d);

		void gradientMap2D(
				float x, float y,
				float step_x, float step_y,
				int seed);
		void gradientMap3D(
				float x, float y, float z,
				float step_x, float step_y, float step_z,
				int seed);
		float* perlinMap2D(float x, float y);
		float* perlinMap2DModulated(float x, float y, float *persist_map);
		float* perlinMap3D(float x, float y, float z);
		void transformNoiseMap();
	};

	// Return value: -1 ... 1
	float noise2d(int x, int y, int seed);
	float noise3d(int x, int y, int z, int seed);

	float noise2d_gradient(float x, float y, int seed);
	float noise3d_gradient(float x, float y, float z, int seed);

	float noise2d_perlin(float x, float y, int seed,
			int octaves, float persistence);

	float noise2d_perlin_abs(float x, float y, int seed,
			int octaves, float persistence);

	float noise3d_perlin(float x, float y, float z, int seed,
			int octaves, float persistence);

	float noise3d_perlin_abs(float x, float y, float z, int seed,
			int octaves, float persistence);

	inline float easeCurve(float t){
		return t * t * t * (t * (6.f * t - 15.f) + 10.f);
	}

	inline float NoisePerlin2D(const NoiseParams *np, float x, float y, float s)
	{
		return (np->offset + np->scale * noise2d_perlin(
					   (float)x / np->spread.X,
					   (float)y / np->spread.Y,
					   s + np->seed, np->octaves, np->persist));
	}

	inline float NoisePerlin2DNoTxfm(
			const NoiseParams *np, float x, float y, float s)
	{
		return (noise2d_perlin(
					   (float)x / np->spread.X,
					   (float)y / np->spread.Y,
					   s + np->seed, np->octaves, np->persist));
	}

	inline float NoisePerlin2DPosOffset(const NoiseParams *np, float x, float xoff,
			float y, float yoff, float s)
	{
		return (np->offset + np->scale * noise2d_perlin(
					   (float)xoff + (float)x / np->spread.X,
					   (float)yoff + (float)y / np->spread.Y,
					   s + np->seed, np->octaves, np->persist));
	}

	inline float NoisePerlin2DNoTxfmPosOffset(const NoiseParams *np, float x,
			float xoff, float y, float yoff, float s)
	{
		return (noise2d_perlin(
					   (float)xoff + (float)x / np->spread.X,
					   (float)yoff + (float)y / np->spread.Y,
					   s + np->seed, np->octaves, np->persist));
	}

	inline float NoisePerlin3D(
			const NoiseParams *np, float x, float y, float z, float s)
	{
		return (np->offset + np->scale *
				   noise3d_perlin((float)x / np->spread.X, (float)y / np->spread.Y,
				   (float)z / np->spread.Z, s + np->seed, np->octaves, np->persist));
	}
}
// vim: set noet ts=4 sw=4:
