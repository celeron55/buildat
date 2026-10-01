// A shim, not Luanti's: see README.txt and the header of noise.h.
#include "noise.h"
#include "log.h"

// buildat's own copy applies the offset and the scale in
// transformNoiseMap(), and Luanti's applies them inside the map call, so
// the map call here does both. Luanti's own transformNoiseMap() is
// therefore nothing to do -- no mapgen calls it, and one that did would
// mean it once.
Noise::Noise(const NoiseParams *np_, s32 seed_, u32 sx_, u32 sy_, u32 sz_):
	np(*np_), seed(seed_), sx(sx_), sy(sy_), sz(sz_)
{
	rebuild();
}

Noise::~Noise()
{
	delete m_noise;
}

void Noise::rebuild()
{
	delete m_noise;
	m_noise = nullptr;
	m_np.offset = np.offset;
	m_np.scale = np.scale;
	m_np.spread = interface::v3f(np.spread.X, np.spread.Y, np.spread.Z);
	m_np.seed = np.seed;
	m_np.octaves = np.octaves;
	m_np.persist = np.persist;
	m_noise = new interface::Noise(&m_np, seed, (int)sx, (int)sy, (int)sz);
	result = m_noise->result;
}

void Noise::setSize(u32 sx_, u32 sy_, u32 sz_)
{
	sx = sx_;
	sy = sy_;
	sz = sz_;
	rebuild();
}

float* Noise::noiseMap2D(float x, float y, float *persistence_map)
{
	if(persistence_map)
		m_noise->fbmMap2DModulated(x, y, persistence_map);
	else
		m_noise->fbmMap2D(x, y);
	m_noise->transformNoiseMap();
	result = m_noise->result;
	return result;
}

float* Noise::noiseMap3D(float x, float y, float z, float *persistence_map)
{
	m_noise->fbmMap3D(x, y, z);
	m_noise->transformNoiseMap();
	result = m_noise->result;
	return result;
}

void Noise::transformNoiseMap()
{
	// Already done by the map call above
}

float NoiseFractal2D(const NoiseParams *np, float x, float y, s32 seed)
{
	return np->offset + np->scale * interface::noise2d_fbm(
			x / np->spread.X, y / np->spread.Y,
			seed + np->seed, np->octaves, np->persist);
}

float NoiseFractal3D(const NoiseParams *np, float x, float y, float z,
		s32 seed)
{
	return np->offset + np->scale * interface::noise3d_fbm(
			x / np->spread.X, y / np->spread.Y, z / np->spread.Z,
			seed + np->seed, np->octaves, np->persist);
}
