// Buildat: apps/floorplanner/main/client_data/GridBake.glsl
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// **The rooms' light on a grid** (user, 2026-10-02: the probes' light put
// back on the box for each pixel was 70 ms a frame on the web): for each
// room with probes, GRID_U by GRID_Y by GRID_V points through its box,
// taken in from its faces (BoxInset), and at each the light round six
// normals -- along, up and across the box, each way -- as the ambient term
// takes it. Palette.glsl reads it there and weights the three normals a
// surface's normal is between by their squares. fp_grid.xml draws it, all
// of it at once, when the probes' light has changed (editor.lua's
// M.grid_bake). A room's block is GRID_Y * GRID_V rows of the target from
// its first probe row on, a row the six normals' GRID_U points each.
//
// A probe's light put back on the box (user, 2026-10-01: the light round a
// probe was a far wall's too, at the probe's nearness to the sun's patch;
// checked against the path tracer's at three walls of a room, within a
// tenth with two by two cells a face, where the probe's own was off by up
// to three times): each cell of the probe's faces -- its mean radiance,
// the reduce pass's (cRoomCubes 1), or editor.lua's worked out ones as
// sqrt(L / 16) (2) -- is the patch of the box where the cell's middle
// leaves it, of the area the cell's solid angle makes there, and lights a
// point facing n as a disc does: L A cos cos / (pi r^2 + A), the ambient
// term that is. Inside the room the box is all of a surface's view, so
// the discs' shares are made to add up to it: two by two cells a face are
// coarse by a corner, where their shares came to less, a shade deeper than
// the path tracer's corners and one that went with the cells' size, and
// more would have grown round and round through the probes.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vTexCoord;

#ifdef COMPILEPS
uniform float cRoomCubes;
#include "main/RoomLight.glsl"

// A cell's solid angle: a quarter of a face's
const float CELL_OMEGA = 0.5235988;

vec3 Cell(float i, float row)
{
    vec2 uv = vec2((i + 0.5) / 24.0, (row + 0.5) / PROBE_ROWS);
    if (cRoomCubes > 1.5) {
        vec3 t = texture2D(sNormalMap, uv).rgb;
        return Finite(t * t * 16.0);
    }
    return Finite(texture2D(sEmissiveMap, uv).rgb);
}

// x and n in the box's frame
vec3 ProbeLight(float row, vec3 x, vec3 n, vec3 lo, vec3 hi, vec2 O, vec2 U)
{
    vec4 q0 = TableTexel(row, 6.0);
    vec4 q1 = TableTexel(row, 7.0);
    vec3 q = ToBox(vec3(Decode16(q0.r, q0.g), Decode16(q1.r, q1.g),
            Decode16(q0.b, q0.a)), O, U);
    vec3 sum = vec3(0.0);
    float shares = 0.0;
    for (int i = 0; i < 24; i++) {
        float fi = float(i);
        float face = floor(fi / 4.0);
        float c = fi - face * 4.0;
        float cy = floor(c / 2.0);
        float cx = c - cy * 2.0;
        vec3 f, r, u;
        FaceAxes(face, f, r, u);
        vec3 dw = normalize(f + r * (cx - 0.5) + u * (0.5 - cy));
        vec3 d = vec3(dot(dw.xz, U), dw.y, dot(dw.xz, vec2(-U.y, U.x)));
        vec3 sd = vec3(abs(d.x) > 1e-6 ? d.x : 1e-6, abs(d.y) > 1e-6 ? d.y : 1e-6,
                abs(d.z) > 1e-6 ? d.z : 1e-6);
        vec3 tt = (mix(lo, hi, step(0.0, sd)) - q) / sd;
        float t = max(min(tt.x, min(tt.y, tt.z)), 0.0);
        vec3 nh = tt.x <= tt.y && tt.x <= tt.z ? vec3(-sign(sd.x), 0.0, 0.0) :
                tt.y <= tt.z ? vec3(0.0, -sign(sd.y), 0.0) : vec3(0.0, 0.0, -sign(sd.z));
        vec3 h = q + d * t;
        float A = CELL_OMEGA * t * t / max(abs(dot(d, nh)), 0.05);
        vec3 w = x - h;
        float r2 = dot(w, w);
        float rl = sqrt(max(r2, 1e-8));
        float ce = max(dot(w, nh) / rl, 0.0);
        float cr = max(-dot(w, n) / rl, 0.0);
        float share = A * ce * cr / (3.14159265 * r2 + A);
        sum += Cell(fi, row) * share;
        shares += share;
    }
    return shares > 1e-4 ? sum / shares : vec3(0.0);
}
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vTexCoord = GetQuadTexCoord(gl_Position);
}

void PS()
{
    vec2 cell = floor(vTexCoord * vec2(GRID_W, GRID_H));
    float dir = floor(cell.x / GRID_U);
    float iu = cell.x - dir * GRID_U;
    float block = floor(cell.y / (GRID_Y * GRID_V));
    float r = cell.y - block * GRID_Y * GRID_V;
    float iy = floor(r / GRID_V);
    float iv = r - iy * GRID_V;
    // The block's room: its first probe row's
    float slot = floor(TableTexel(block, 7.0).b * 255.0 + 0.5);
    if (slot < 0.5 || RoomRows(slot).x != block) {
        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    vec2 O, U;
    vec3 lo, hi;
    RoomBox(slot, O, U, lo, hi);
    vec3 inset = BoxInset(lo, hi);
    vec3 x = mix(lo + inset, hi - inset,
            vec3(iu / (GRID_U - 1.0), iy / (GRID_Y - 1.0), iv / (GRID_V - 1.0)));
    vec3 n = dir < 0.5 ? vec3(1.0, 0.0, 0.0) : dir < 1.5 ? vec3(-1.0, 0.0, 0.0) :
            dir < 2.5 ? vec3(0.0, 1.0, 0.0) : dir < 3.5 ? vec3(0.0, -1.0, 0.0) :
            dir < 4.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 0.0, -1.0);
    // The world's place of the point, for the probes it is between
    vec2 V = vec2(-U.y, U.x);
    vec2 pxz = O + U * x.x + V * x.z;
    vec3 pr = RoomProbes(slot, vec3(pxz.x, x.y, pxz.y));
    vec3 a = ProbeLight(pr.x, x, n, lo, hi, O, U);
    if (pr.z > 0.001)
        a = mix(a, ProbeLight(pr.y, x, n, lo, hi, O, U), pr.z);
    gl_FragColor = vec4(a, 1.0);
}
