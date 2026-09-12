// The sky a Luanti world stands under, on a skybox: a gradient from the
// horizon to the zenith, the sun and the moon, the stars at night and a flat
// layer of cloud.
//
// What time of day it is is not worked out here. The client hands in the
// colours -- Luanti's own sky colours, picked and dimmed the way its
// src/client/sky.cpp picks and dims them -- and the direction of the sun, so
// that the ramp through dawn and dusk is Lua's business and this file only
// draws what it is told.
//
// The cloud layer is the one from builtin/voxel_shading's VoxelSkybox, with
// the colour handed in rather than baked in: squares of two tones on a plane
// overhead, thinning into the sky towards the horizon.

#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"

varying vec3 vTexCoord;

uniform vec3 cSkyTop;
uniform vec3 cSkyHorizon;
uniform vec3 cSunDirection;
uniform vec3 cSunTint;
uniform vec3 cCloudColor;
uniform float cStarFade;
// What the game says is up there: half the width of the sun's and the moon's
// squares, zero for one it has turned off; how many of the star grid's cells
// hold a star, and what colour; and how much of the sky the clouds cover.
uniform float cSunSize;
uniform float cSunOverexposure;
uniform float cMoonSize;
uniform float cStarDensity;
uniform vec3 cStarColor;
uniform float cCloudCoverage;
// Whether the game gave the sun or the moon a texture of its own. When it
// did, sDiffMap holds the sun's and sNormalMap the moon's -- two units
// because a material has no third one this needs -- and the square is that
// texture instead of a flat colour.
uniform float cSunTextured;
uniform float cMoonTextured;
// How fast the cloud layer drifts, in this file's own units per second. The
// game says nodes a second and the client fudges it, because these clouds
// are not a layer at a height; see CLOUD_WIND below for what a node comes to.
uniform vec2 cCloudWind;

// How far below the horizon the sky darkens into the ground haze
const float HAZE_DEPTH = 0.25;

// How soft the edge of the sun's or the moon's square is. How wide they are
// is cSunSize and cMoonSize, which the game decides.
const float BODY_EDGE = 0.004;
const vec3 MOON_COLOR = vec3(0.86, 0.88, 0.94);
// The sun's own colour, which it wears until it is low enough to take the
// tint the horizon is painted with: a sun the colour of dawn at midday is
// what the tint alone gives
const vec3 SUN_COLOR = vec3(1.0, 0.97, 0.86);
// How far past white the sun's disc is drawn. The sun is brighter than
// anything else in the frame by orders of magnitude and it has to be said
// somehow: on the vanilla path the frame clips at one, so the disc is pushed
// a little past it and its core comes out white with the texture's own colour
// left at the edges; on the PBR path the frame is tone mapped and this is a
// real multiplier, which is also what makes the bloom around it. Set from
// world.lua. Scaled back to nothing as the sun comes down to the horizon,
// because a low sun is a dim one and its colour is the point of it.

const float CLOUD_SCALE = 6.0;
const float CLOUD_PIXELS = 11.0;
const float CLOUD_LIT_STEP = 0.07;
const float CLOUD_HORIZON = 0.16;
const float CLOUD_FADE = 0.38;

// The stars: one per cell of a grid laid over the direction, only some cells
// holding one at all -- how many is cStarDensity, out of how many stars the
// game asked for. Few enough to read as stars: at any greater density the
// night sky is white noise.
const float STAR_GRID = 220.0;

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
    float v = SkyNoise(p) * 0.65;
    v += SkyNoise(p * 2.03) * 0.35;
    return v;
}

// A square of the given half width around a direction, for the sun and the
// moon: how much of the pixel is inside it in x, and where inside it the
// pixel is in yz, as 0...1 across the square, for a body that wears a
// texture. 0 coverage outside it.
vec3 Body(vec3 d, vec3 towards_body, float half_width)
{
    float towards = dot(d, towards_body);
    if(towards <= 0.0)
        return vec3(0.0, 0.0, 0.0);
    vec3 su = normalize(cross(towards_body, vec3(0.0, 1.0, 0.0)));
    vec3 sv = cross(su, towards_body);
    vec3 onPlane = d / towards;
    vec2 at = vec2(dot(onPlane, su), dot(onPlane, sv));
    vec2 uv = abs(at);
    float cover = 1.0 - smoothstep(half_width - BODY_EDGE,
            half_width + BODY_EDGE, max(uv.x, uv.y));
    return vec3(cover, at / (half_width * 2.0) + 0.5);
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

    // The gradient. Luanti's sky is the horizon colour low down and the sky
    // colour overhead; the square root spends more of the dome on the
    // horizon band, which is where the two differ most.
    vec3 color = d.y < 0.0 ?
            mix(cSkyHorizon, cSkyHorizon * 0.55, min(1.0, -d.y / HAZE_DEPTH)) :
            mix(cSkyHorizon, cSkyTop, sqrt(d.y));

    // The band the sun paints around itself along the horizon, which is what
    // makes dawn and dusk read as dawn and dusk. Strongest when the sun is
    // itself near the horizon, and only in the half of the sky it is in.
    float low = clamp(1.0 - abs(sun.y) * 2.5, 0.0, 1.0);
    if(low > 0.0){
        vec2 flat_d = vec2(d.x, d.z);
        vec2 flat_sun = vec2(sun.x, sun.z);
        float len = length(flat_d) * length(flat_sun);
        float towards = len > 0.0001 ? dot(flat_d, flat_sun) / len : 0.0;
        float band = pow(max(towards, 0.0), 3.0) *
                pow(1.0 - min(abs(d.y), 1.0), 2.5) * low;
        color = mix(color, cSunTint, band * 0.8);
    }

    // The stars, behind everything else up there and only when the sky is
    // dark enough for them
    if(cStarFade > 0.0 && cStarDensity > 0.0 && d.y > -0.05){
        vec2 cell = floor(vec2(d.x, d.z) / max(abs(d.y), 0.15) * STAR_GRID);
        float pick = SkyHash(cell);
        if(pick < cStarDensity){
            float twinkle = 0.55 + 0.45 * SkyHash(cell + 7.0);
            color += cStarColor * twinkle * cStarFade *
                    smoothstep(-0.05, 0.15, d.y);
        }
    }

    // The clouds, on a plane overhead: dividing by d.y is what makes them lie
    // flat and crowd together towards the horizon instead of wrapping the dome
    if(d.y > 0.0 && cCloudCoverage > 0.0){
        vec2 p = d.xz / max(d.y, CLOUD_HORIZON) * CLOUD_SCALE +
                cElapsedTimePS * cCloudWind;
        float density = CloudDensity(floor(p * CLOUD_PIXELS) / CLOUD_PIXELS);
        float threshold = 1.0 - cCloudCoverage;
        vec3 cloud = density > threshold + CLOUD_LIT_STEP ?
                cCloudColor : cCloudColor * 0.72;
        float cover = step(threshold, density) *
                smoothstep(CLOUD_HORIZON, CLOUD_FADE, d.y);
        color = mix(color, cloud, cover);
    }

    // The sun and the moon, over the clouds: they are the two things up there
    // that are not behind them. The sun goes the colour of the tint as it
    // comes down to the horizon, which is where that colour belongs; higher
    // up it is its own.
    if(cSunSize > 0.0){
        vec3 body = Body(d, sun, cSunSize);
        vec3 sun_color = mix(SUN_COLOR, cSunTint * 1.6, low);
        float cover = body.x;
        if(cSunTextured > 0.5){
            // The texture's own colours, and its alpha as the coverage: a
            // sun drawn as a disc in a square image is a disc here too
            vec4 tex = texture2D(sDiffMap, vec2(body.y, 1.0 - body.z));
            sun_color = tex.rgb;
            cover *= tex.a;
        }
        sun_color *= mix(cSunOverexposure, 1.0, low);
        color = mix(color, sun_color, cover);
    }
    if(cMoonSize > 0.0){
        vec3 body = Body(d, -sun, cMoonSize);
        vec3 moon_color = MOON_COLOR;
        float cover = body.x;
        if(cMoonTextured > 0.5){
            vec4 tex = texture2D(sNormalMap, vec2(body.y, 1.0 - body.z));
            moon_color = tex.rgb;
            cover *= tex.a;
        }
        color = mix(color, moon_color, cover);
    }

    gl_FragColor = vec4(color, 1.0);
}
