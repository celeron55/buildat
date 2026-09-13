// A shim, not Luanti's: see README.txt.
//
// Luanti's noise API over buildat's own copy of it. buildat vendored
// Luanti's value noise years ago for its own generators
// (src/interface/noise.h); this maps the calls the mapgen makes onto that,
// rather than carrying a second copy of the same algorithm and keeping it
// in step with upstream.
//
// simplified, and it is the trade the plan names: lacunarity and the flags
// are taken and not acted on, because buildat's copy doubles the frequency
// per octave and has no eased or absvalue switch. A world generated here
// therefore looks like a Luanti world rather than reproducing one: the same
// seed does not give the same terrain as upstream. See "Mapgen stage 3" in
// doc/plan/luanti_module_plan.md.
#pragma once
#include "irrlichttypes_bloated.h"
#include "exceptions.h"
#include "interface/noise.h"
#include <cstring>
#include <cmath>

#define NOISE_FLAG_DEFAULTS    0x01
#define NOISE_FLAG_EASED       0x02
#define NOISE_FLAG_ABSVALUE    0x04
#define NOISE_FLAG_POINTBUFFER 0x08
#define NOISE_FLAG_SIMPLEX     0x10

// Luanti's own randomness, which is buildat's own vendored copy of it
using interface::PseudoRandom;

// A seeded PCG, which the mapgen uses for anything that has to be the same
// for the same block. buildat's copy carries PseudoRandom only, so this is
// the one algorithm that is here rather than there -- it is small, it is
// exactly Luanti's, and a mapgen's randomness is what makes a world.
class PcgRandom {
public:
	static const s32 RANDOM_MIN = -0x7fffffff - 1;
	static const s32 RANDOM_MAX = 0x7fffffff;
	static const u32 RANDOM_RANGE = 0xffffffff;

	PcgRandom(u64 state = 0x853c49e6748fea9bULL,
			u64 seq = 0xda3e39cb94b95bdbULL)
	{
		seed(state, seq);
	}

	void seed(u64 state, u64 seq = 0xda3e39cb94b95bdbULL)
	{
		m_state = 0U;
		m_inc = (seq << 1u) | 1u;
		next();
		m_state += state;
		next();
	}

	u32 next()
	{
		u64 oldstate = m_state;
		m_state = oldstate * 6364136223846793005ULL + m_inc;
		u32 xorshifted = ((oldstate >> 18u) ^ oldstate) >> 27u;
		u32 rot = oldstate >> 59u;
		return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
	}

	u32 range(u32 bound)
	{
		if(bound == 0)
			return next();
		u32 threshold = -bound % bound;
		u32 r;
		while((r = next()) < threshold)
			;
		return r % bound;
	}

	s32 range(s32 min, s32 max)
	{
		if(max < min)
			throw PrngException("Invalid range (max < min)");
		u64 num = (u64)max - (u64)min + 1;
		return (s32)(range((u32)num) + min);
	}

	void bytes(void *out, size_t len)
	{
		u8 *outb = (u8 *)out;
		while(len--){
			if(m_bytes_left == 0){
				m_bytes = next();
				m_bytes_left = 4;
			}
			*outb++ = (u8)(m_bytes & 0xff);
			m_bytes >>= 8;
			m_bytes_left--;
		}
	}

	s32 randNormalDist(s32 min, s32 max, int num_trials = 6)
	{
		s32 accum = 0;
		for(int i = 0; i < num_trials; i++)
			accum += range(min, max);
		return (s32)std::round((float)accum / num_trials);
	}

	void getState(u64 state[2]) const { state[0] = m_state; state[1] = m_inc; }
	void setState(const u64 state[2]) { m_state = state[0]; m_inc = state[1]; }

	class PrngException: public BaseException {
	public:
		PrngException(const std::string &s): BaseException(s){}
	};

private:
	u64 m_state = 0;
	u64 m_inc = 0;
	u32 m_bytes = 0;
	int m_bytes_left = 0;
};

struct NoiseParams {
	float offset = 0.0f;
	float scale = 1.0f;
	v3f spread = v3f(250, 250, 250);
	s32 seed = 12345;
	u16 octaves = 3;
	float persist = 0.6f;
	// Taken and not acted on; see the header of this file
	float lacunarity = 2.0f;
	u32 flags = NOISE_FLAG_DEFAULTS;

	NoiseParams() = default;
	NoiseParams(float offset_, float scale_, const v3f &spread_, s32 seed_,
			u16 octaves_, float persist_, float lacunarity_ = 2.0f,
			u32 flags_ = NOISE_FLAG_DEFAULTS):
		offset(offset_), scale(scale_), spread(spread_), seed(seed_),
		octaves(octaves_), persist(persist_), lacunarity(lacunarity_),
		flags(flags_)
	{}
};

// One value of the noise, which is what a mapgen asks for a single point
float NoiseFractal2D(const NoiseParams *np, float x, float y, s32 seed);
float NoiseFractal3D(const NoiseParams *np, float x, float y, float z,
		s32 seed);

inline float NoiseFractal2D_PO(NoiseParams *np, float x, float xoff,
		float y, float yoff, s32 seed)
{
	return NoiseFractal2D(np, x + xoff * np->spread.X,
			y + yoff * np->spread.Y, seed);
}

inline float NoiseFractal3D_PO(NoiseParams *np, float x, float xoff,
		float y, float yoff, float z, float zoff, s32 seed)
{
	return NoiseFractal3D(np, x + xoff * np->spread.X,
			y + yoff * np->spread.Y, z + zoff * np->spread.Z, seed);
}

// A map of it, which is how a mapgen asks for a whole chunk at once
class Noise {
public:
	NoiseParams np;
	s32 seed;
	u32 sx;
	u32 sy;
	u32 sz;
	float *result = nullptr;

	Noise(const NoiseParams *np_, s32 seed_, u32 sx_, u32 sy_, u32 sz_ = 1);
	~Noise();

	void setSize(u32 sx_, u32 sy_, u32 sz_ = 1);

	float* noiseMap2D(float x, float y, float *persistence_map = nullptr);
	float* noiseMap3D(float x, float y, float z,
			float *persistence_map = nullptr);

	inline float* noiseMap2D_PO(float x, float xoff, float y, float yoff,
			float *persistence_map = nullptr)
	{
		return noiseMap2D(x + xoff * np.spread.X, y + yoff * np.spread.Y,
				persistence_map);
	}

	inline float* noiseMap3D_PO(float x, float xoff, float y, float yoff,
			float z, float zoff, float *persistence_map = nullptr)
	{
		return noiseMap3D(x + xoff * np.spread.X, y + yoff * np.spread.Y,
				z + zoff * np.spread.Z, persistence_map);
	}

	void transformNoiseMap();

private:
	// buildat's own, which does the work
	interface::NoiseParams m_np;
	interface::Noise *m_noise = nullptr;
	void rebuild();
};
