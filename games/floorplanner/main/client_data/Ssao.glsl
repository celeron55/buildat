// Buildat: games/floorplanner/main/client_data/Ssao.glsl
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// **Ambient occlusion in screen space** ([FP_AO], user 2026-10-01): how
// much of the hemisphere over each point the scene near it hides, from the
// G-buffer's depth and normal. deferred_ssao.xml runs it at half the size
// (AO) and puts it over the ambient at full size with a blur that keeps to
// one depth (APPLY).
//
// AO: points around the pixel on the screen, out to about SsaoRadius
// metres at its depth, are read back into the world, and each one above
// the surface and near it hides the sky in its direction. No projection
// matrix reaches a pixel shader here, so a point off the pixel is found by
// stepping the far-plane ray by its derivatives, which a quad makes exact.
//
// simplified: the screen only knows what is on it, so the occlusion fades
// where the occluder is off the edge or behind something nearer
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vScreenPos;
varying vec3 vFarRay;

#ifdef COMPILEPS
uniform float cSsaoRadius;
uniform float cSsaoStrength;
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vScreenPos = GetScreenPosPreDiv(gl_Position);
    vFarRay = GetFarRay(gl_Position);
}

#ifdef COMPILEPS
float Depth(vec2 uv)
{
    return DecodeDepth(texture2D(sDepthBuffer, uv).rgb);
}
#endif

void PS()
{
#ifdef AO
    // A pixel's step on the screen and in the far-plane ray, out of the
    // branches: a derivative needs the whole quad of pixels
    vec2 du = dFdx(vScreenPos);
    vec2 dv = dFdy(vScreenPos);
    vec3 rx = dFdx(vFarRay);
    vec3 ry = dFdy(vFarRay);
    float d = Depth(vScreenPos);
    if (d >= 0.999) {
        gl_FragColor = vec4(1.0);
        return;
    }
    vec3 p = vFarRay * d;
    vec3 n = normalize(texture2D(sNormalBuffer, vScreenPos).rgb * 2.0 - 1.0);
    // The radius in this target's pixels, kept to what the cache bears
    float px_m = max(length(rx) * d, 1e-6);
    float r_px = clamp(cSsaoRadius / px_m, 2.0, 48.0);
    float rr = cSsaoRadius * cSsaoRadius;
    // A turn of the pattern for each pixel, which the blur averages
    float turn = 6.2831853 * fract(52.9829189 *
            fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    const int N = 12;
    float hidden = 0.0;
    for (int i = 0; i < N; i++) {
        float t = (float(i) + 0.5) / float(N);
        float a = float(i) * 2.3999632 + turn;
        vec2 o = vec2(cos(a), sin(a)) * (t * r_px);
        vec2 uv = vScreenPos + du * o.x + dv * o.y;
        vec3 q = (vFarRay + rx * o.x + ry * o.y) * Depth(uv);
        vec3 v = q - p;
        float vv = dot(v, v);
        // Above the surface, with a margin for a flat one's own depth
        // steps, and less the further it is
        float up = dot(v, n) * inversesqrt(vv + 1e-6);
        hidden += max(0.0, up - 0.1) * max(0.0, 1.0 - vv / rr);
    }
    float ao = clamp(1.0 - cSsaoStrength * hidden / float(N), 0.0, 1.0);
    gl_FragColor = vec4(ao, ao, ao, 1.0);
#endif
#ifdef APPLY
    // Four by four of the half-size texels, each as much as its depth is
    // this pixel's, so a corner's shade does not bleed onto what is in
    // front of it
    float d = Depth(vScreenPos);
    vec2 texel = cGBufferInvSize * 2.0;
    float sum = 0.0;
    float weight = 0.0;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            vec2 uv = vScreenPos + (vec2(float(x), float(y)) - 1.5) * texel;
            float w = max(0.0, 1.0 - abs(Depth(uv) - d) / (0.05 * d + 1e-5)) +
                    1e-4;
            sum += texture2D(sDiffMap, uv).r * w;
            weight += w;
        }
    }
    float ao = sum / weight;
    gl_FragColor = vec4(ao, ao, ao, 1.0);
#endif
}
