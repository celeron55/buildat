// Buildat: games/floorplanner/main/client_data/FpFrame.glsl
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// **The frame as an eye in the room sees it** (user, 2026-10-01: paint
// is chosen off it; fp_frame.xml, after the meter): the light's colour
// adapted away and the HDR frame tone mapped for the screen.
//
// The adaptation: a von Kries scaling in Bradford's cone space from the
// white the eye is adapted to -- what a grey card at the eye is lit by,
// the probes' where the camera is along its room averaged over their six
// faces, or the sun's and the sky's outdoors (editor.lua's M.wb_tick, in
// fp_wb), which the eye's own (fpWhite) moves to in a second or so -- to the
// display's D65, by CIECAM02's degree of adaptation D, which the
// adapting luminance gives: about 1 in daylight, less in the dark. A
// path-traced room's light is that of its walls bounced again and again
// (test/pathtrace_render.py: a white ceiling in a wooden room had
// r/g 1.8); the eye takes most of that out.
//
// The tone map: Khronos PBR Neutral, which leaves a colour under the
// metered light as it is up to near white and only then compresses,
// toward white, without the per-channel shoulder's hue shifts.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vScreenPos;
varying vec2 vTexCoord;

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vScreenPos = GetScreenPosPreDiv(gl_Position);
    vTexCoord = GetQuadTexCoord(gl_Position);
}

#ifdef COMPILEPS
// Linear sRGB to Bradford's cone responses, and back
const mat3 RGB2LMS = mat3(0.422725, 0.055700, 0.021383, 0.491345, 0.961534,
        0.087642, 0.027358, 0.023184, 0.980508);
const mat3 LMS2RGB = mat3(2.538045, -0.146004, -0.042299, -1.293277, 1.116648,
        -0.071607, -0.040237, -0.022329, 1.022753);
const vec3 LUM = vec3(0.2126, 0.7152, 0.0722);
// cd/m2 a unit of the frame's radiance is: the clear noon zenith is 4.5
// (daylight.lua's PHYS), which is some 5000 cd/m2 out of doors
// simplified: one figure, the sky's; the units are not otherwise
// calibrated
const float CD_PER_UNIT = 1000.0;
// The room probes' ambient cubes (editor.lua)
const float PROBE_ROWS = 64.0;

// A probe's cells' mean (all of a solid angle), at luminance one
vec3 ProbeWhite(float row, vec3 outdoor)
{
    if (row < 0.5)
        return outdoor;
    vec3 c = vec3(0.0);
    for (int i = 0; i < 24; i++)
        c += texture2D(sSpecMap, vec2((float(i) + 0.5) / 24.0,
                (row + 0.5) / PROBE_ROWS)).rgb;
    return c == c && dot(c, LUM) > 1e-6 && dot(c, LUM) < 1e6 ? c / dot(c, LUM) : outdoor;
}
// The eye's white's way to the scene's: a time constant of a second
const float WHITE_RATE = 1.0;

vec3 PBRNeutral(vec3 color)
{
    const float startCompression = 0.8 - 0.04;
    const float desaturation = 0.15;
    float x = min(color.r, min(color.g, color.b));
    float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    color -= offset;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression)
        return color;
    const float d = 1.0 - startCompression;
    float newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;
    float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(color, vec3(newPeak), g);
}
#endif

void PS()
{
#ifdef WHITE
    // fpWhite: the eye's white, at luminance one, moved to the scene's
    vec4 p = texture2D(sEmissiveMap, vec2(0.25, 0.5));
    vec3 o = texture2D(sEmissiveMap, vec2(0.75, 0.5)).rgb;
    o /= max(dot(o, LUM), 1e-6);
    vec3 target = mix(ProbeWhite(floor(p.r * 255.0 + 0.5), o),
            ProbeWhite(floor(p.g * 255.0 + 0.5), o), p.b);
    vec3 prev = texture2D(sDiffMap, vTexCoord).rgb;
    float k = 1.0 - exp(-cDeltaTimePS * WHITE_RATE);
    // The first frame's, and one gone wrong: straight to it
    if (!(dot(prev, LUM) > 0.01 && dot(prev, LUM) < 100.0))
        k = 1.0;
    gl_FragColor = vec4(mix(prev, target, k), 1.0);
#else
    vec3 color = max(texture2D(sDiffMap, vScreenPos).rgb, 0.0);
    vec3 w = texture2D(sSpecMap, vec2(0.5, 0.5)).rgb;
    float la = texture2D(sNormalMap, vec2(0.5, 0.5)).r * CD_PER_UNIT;
    float D = clamp(1.0 - exp((-la - 42.0) / 92.0) / 3.6, 0.0, 1.0);
    vec3 gain = mix(vec3(1.0), (RGB2LMS * vec3(1.0)) /
            max(RGB2LMS * (w / max(dot(w, LUM), 1e-6)), vec3(1e-6)), D);
    color = max(LMS2RGB * (gain * (RGB2LMS * color)), 0.0);
    gl_FragColor = vec4(PBRNeutral(color), 1.0);
#endif
}
