// buildat: the darkening a shadow map casts over voxel geometry that is lit by
// what the mesher baked into its vertex colours.
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// **A shadow that multiplies, not a light that adds.** The unlit path draws
// Luanti's own baked light and has no diffuse term to add a directional light
// to -- put one through Urho3D's LitSolid over it and every face the sun
// reaches goes white. What official Luanti does with its dynamic shadows on
// is darken what the sun cannot see and leave the rest of the baked light
// alone, so that is what this pass does: it writes the shadow factor as a
// colour and the technique blends it with multiply.
//
// It runs as the technique's light pass, once per light in the scene. The
// Luanti launcher puts two there, the sun and the moon, and only one of them
// is ever enabled -- whichever is above the horizon -- so nothing is darkened
// twice. A game that adds point lights to an unlit world wants
// res/VoxelUnlit.xml instead, whose light pass adds rather than multiplies.

#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Lighting.glsl"

varying vec4 vWorldPos;
varying vec3 vNormal;
// TRANSLUCENT ([PARITY_LEFTOVERS]): the same pass over a blended surface,
// water. The multiply lands on what is already composited -- the water
// and the bed seen through it, which has its own shadow pass -- so the
// darkening is weighted by the texel's alpha: the water's own share is
// shadowed, the bed's is left. simplified: the bed's share under a
// shadowed water is still darkened a little (1 - a of the way), which a
// second render target would avoid.
#ifdef TRANSLUCENT
    varying vec2 vTexCoord;
#endif
#ifdef PERPIXEL
    #ifdef SHADOW
        #ifndef GL_ES
            varying vec4 vShadowPos[NUMCASCADES];
        #else
            varying highp vec4 vShadowPos[NUMCASCADES];
        #endif
    #endif
#endif

// How dark a shadowed surface is left, against the same surface in the sun.
// Luanti's own shadow strength is a setting -- shadow_intensity, 0.33 by
// default -- and this is the light that is left when it is applied, which is
// what a comparison against the reference shots is against.
const float SHADOW_LEFT = 0.67;

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vNormal = GetWorldNormal(modelMatrix);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));
    #ifdef TRANSLUCENT
        vTexCoord = iTexCoord;
    #endif
    #ifdef PERPIXEL
        #ifdef SHADOW
            vec4 projWorldPos = vec4(worldPos, 1.0);
            for (int i = 0; i < NUMCASCADES; i++)
                vShadowPos[i] = GetShadowPos(i, vNormal, projWorldPos);
        #endif
    #endif
}

void PS()
{
    float shadow = 1.0;
    #if defined(PERPIXEL) && defined(SHADOW)
        shadow = GetShadow(vShadowPos, vWorldPos.w);
    #endif
    // A face the light cannot see is in its own shadow whatever the map says,
    // and the map cannot say it: a wall facing away from the sun is lit
    // exactly as its neighbour facing into it. Luanti folds the same term in
    // beside its shadow map. The terminator is softened over a fifth of a
    // unit so that a curved surface -- a mob, a leaf quad -- does not get a
    // hard line across it.
    #if defined(PERPIXEL) && defined(DIRLIGHT)
        shadow = min(shadow,
                smoothstep(0.0, 0.2, dot(normalize(vNormal), cLightDirPS)));
    #endif
    float k = mix(SHADOW_LEFT, 1.0, shadow);
    #ifdef TRANSLUCENT
        k = mix(1.0, k, texture2D(sDiffMap, vTexCoord).a);
    #endif
    gl_FragColor = vec4(k, k, k, 1.0);
}
