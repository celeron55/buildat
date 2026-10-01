// Buildat: games/floorplanner/main/client_data/ProbeReduce.glsl
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// **The average of each cell of the room probes** (editor.lua's room
// probes, user 2026-10-01): a face is K by K cells, and the output is
// 6 * K * K texels by PROBE_ROWS, a cell's each, a face's K * K in a row
// of them, its top row first; each is its 32 / K by 32 / K texels in the
// atlas, read as bilinear samples between four texels each. What a
// surface takes its indirect light from (Palette.glsl's RoomAmbient).
// simplified: the texels are not weighted by the solid angle they cover,
// so a face's corners count a little too much. A sample that is not a
// number (a face not drawn yet) is left out.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vTexCoord;

// The atlas's size in texels, as editor.lua makes it
const vec2 ATLAS = vec2(6.0 * 32.0, 64.0 * 32.0);
const float ROWS = 64.0;
// editor.lua's PROBE_K, and the samples a side of a cell
const float K = 2.0;
const int SIDE = 8;

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vTexCoord = GetQuadTexCoord(gl_Position);
}

void PS()
{
    vec2 cell = floor(vTexCoord * vec2(6.0 * K * K, ROWS));
    float face = floor(cell.x / (K * K));
    float c = cell.x - face * K * K;
    float cy = floor(c / K);
    vec2 tile = vec2(face * 32.0 + (c - cy * K) * 32.0 / K,
            cell.y * 32.0 + cy * 32.0 / K);
    vec3 sum = vec3(0.0);
    float n = 0.0;
    for (int j = 0; j < SIDE; j++) {
        for (int i = 0; i < SIDE; i++) {
            vec2 at = (tile + vec2(float(2 * i + 1), float(2 * j + 1))) / ATLAS;
            vec3 c = texture2D(sDiffMap, at).rgb;
            if (!(c.r == c.r && c.g == c.g && c.b == c.b))
                continue;
            sum += c;
            n += 1.0;
        }
    }
    gl_FragColor = vec4(n > 0.0 ? sum / n : vec3(0.0), 1.0);
}
