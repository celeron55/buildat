// The sky the voxel world stands under. Drawn on a skybox, so it has no depth
// presence at all: it is behind everything and never in the way of the ground.
//
// The gradient here is the one games/voxel_lighting/make_client_data.py bakes
// into VoxelSky.xml, so what a glossy surface reflects agrees with what is
// overhead. The sun and the clouds are drawn only here: the reflection of the
// sky carries its own painted sun disc, and the clouds are not reflected at
// all, which is the one place the two skies knowingly disagree.
#include "Uniforms.glsl"
#include "Transform.glsl"

varying vec3 vTexCoord;

uniform vec3 cSunDirection;

// Kept equal to ZENITH, HORIZON and GROUND in make_client_data.py
const vec3 ZENITH = vec3(0.13, 0.24, 0.58);
const vec3 HORIZON = vec3(0.55, 0.66, 0.84);
// Below the horizon the drawn sky is haze rather than the cube map's GROUND:
// what is down there is the world, and the little of this that shows past its
// edge should sit behind distant terrain rather than under it
const vec3 HAZE = vec3(0.45, 0.49, 0.56);
const float HAZE_DEPTH = 0.25;

// A square rather than a disc, since everything else here is cubic. Half its
// width, on a plane one unit along the sun direction, so about 4 degrees.
const float SUN_HALF = 0.075;
const float SUN_EDGE = 0.004;
const vec3 SUN_COLOR = vec3(1.7, 1.66, 1.52);

// A flat layer of cloud, projected onto the sky by direction. Coverage is how
// much of it is cloud at all, softness how far the edges are drawn out.
const float CLOUD_SCALE = 6.0;
const float CLOUD_COVERAGE = 0.42;
const float CLOUD_SOFTNESS = 0.30;
const vec3 CLOUD_LIT = vec3(1.05, 1.04, 1.02);
const vec3 CLOUD_SHADED = vec3(0.52, 0.57, 0.68);
const vec2 CLOUD_WIND = vec2(0.010, 0.004);
// Below this the layer is edge on, and is faded out rather than smeared along
// the horizon
const float CLOUD_HORIZON = 0.16;

float SkyHash(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float SkyNoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(SkyHash(i), SkyHash(i + vec2(1.0, 0.0)), f.x),
               mix(SkyHash(i + vec2(0.0, 1.0)), SkyHash(i + vec2(1.0, 1.0)), f.x),
               f.y);
}

float CloudDensity(vec2 p)
{
    float v = SkyNoise(p) * 0.5;
    v += SkyNoise(p * 2.03) * 0.25;
    v += SkyNoise(p * 4.01) * 0.125;
    return v / 0.875;
}

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    gl_Position.z = gl_Position.w;
    vTexCoord = iPos.xyz;
}

void PS()
{
    vec3 d = normalize(vTexCoord);
    vec3 sun = normalize(cSunDirection);

    vec3 color = d.y < 0.0 ?
            mix(HORIZON, HAZE, min(1.0, -d.y / HAZE_DEPTH)) :
            mix(HORIZON, ZENITH, sqrt(d.y));

    // Clouds, on a plane overhead: dividing by d.y is what makes them lie flat
    // and crowd together towards the horizon instead of wrapping the dome
    if(d.y > 0.0){
        vec2 p = d.xz / max(d.y, CLOUD_HORIZON) * CLOUD_SCALE +
                cElapsedTimePS * CLOUD_WIND;
        float density = CloudDensity(p);
        float cover = smoothstep(1.0 - CLOUD_COVERAGE,
                1.0 - CLOUD_COVERAGE + CLOUD_SOFTNESS, density);
        // Thicker in the middle than at the edges, and lit from the sun's side
        vec3 cloud = mix(CLOUD_SHADED, CLOUD_LIT, cover);
        cover *= smoothstep(0.0, CLOUD_HORIZON * 2.0, d.y);
        color = mix(color, cloud, cover);
    }

    // The sun, over the clouds: it is the one thing up there that is not
    // behind them
    float towards = dot(d, sun);
    if(towards > 0.0){
        vec3 su = normalize(cross(sun, vec3(0.0, 1.0, 0.0)));
        vec3 sv = cross(su, sun);
        vec3 onPlane = d / towards;
        vec2 uv = abs(vec2(dot(onPlane, su), dot(onPlane, sv)));
        float square = 1.0 - smoothstep(SUN_HALF - SUN_EDGE,
                SUN_HALF + SUN_EDGE, max(uv.x, uv.y));
        color = mix(color, SUN_COLOR, square);
    }

    gl_FragColor = vec4(color, 1.0);
}
