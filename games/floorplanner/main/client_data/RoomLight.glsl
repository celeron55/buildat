// Buildat: games/floorplanner/main/client_data/RoomLight.glsl
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// **The room table and the room's grid, read** (user, 2026-10-01): what
// Palette.glsl and GridBake.glsl both know of editor.lua's room table
// (M.room_bounce: eight texels a row, sSpecMap) and of the rooms' grids
// (GridBake.glsl). A length in the table is 16 bits in two bytes, 4 mm a
// step from -131 m; an axis's component 16 bits from -1 to 1.

const float ROOM_ROWS = 256.0;
// The room probes' layout, as editor.lua makes them: PROBE_K by PROBE_K
// cells a face
const float PROBE_ROWS = 64.0;
const float PROBE_K = 2.0;
// A room's grid: along, up and across its box, and its six normals
const float GRID_U = 8.0;
const float GRID_Y = 3.0;
const float GRID_V = 8.0;
const float GRID_W = 48.0;
const float GRID_H = 1536.0;

vec4 TableTexel(float row, float i)
{
    return texture2D(sSpecMap, vec2((i + 0.5) / 8.0, (row + 0.5) / ROOM_ROWS));
}

float Decode16(float hi, float lo)
{
    return (floor(hi * 255.0 + 0.5) * 256.0 + floor(lo * 255.0 + 0.5) - 32768.0) * 0.004;
}
float DecodeUnit(float hi, float lo)
{
    return (floor(hi * 255.0 + 0.5) * 256.0 + floor(lo * 255.0 + 0.5)) / 32767.5 - 1.0;
}

// A probe's light as a number: what is not one, or past half float's
// range, is none (the probes see their own light, and one bad texel
// would go round and fill the rooms)
vec3 Finite(vec3 c)
{
    return max(c.r, max(c.g, c.b)) < 60000.0 && c == c ? max(c, vec3(0.0)) : vec3(0.0);
}

// The room's first probe row and their number
vec2 RoomRows(float slot)
{
    vec4 t1 = TableTexel(slot, 1.0);
    return vec2(floor(t1.r * 255.0 + 0.5), floor(t1.g * 255.0 + 0.5));
}

// The room's box: a corner (x, z), the along axis (x, z), and its lowest
// and highest corners in the box's own frame (along, up, across)
void RoomBox(float slot, out vec2 O, out vec2 U, out vec3 lo, out vec3 hi)
{
    vec4 o = TableTexel(slot, 2.0);
    vec4 e = TableTexel(slot, 3.0);
    vec4 ax = TableTexel(slot, 4.0);
    vec4 y = TableTexel(slot, 5.0);
    O = vec2(Decode16(o.r, o.g), Decode16(o.b, o.a));
    U = normalize(vec2(DecodeUnit(ax.r, ax.g), DecodeUnit(ax.b, ax.a)));
    lo = vec3(0.0, Decode16(y.r, y.g), 0.0);
    hi = vec3(Decode16(e.r, e.g), Decode16(y.b, y.a), Decode16(e.b, e.a));
}
vec3 ToBox(vec3 p, vec2 O, vec2 U)
{
    vec2 d = p.xz - O;
    return vec3(dot(d, U), p.y, dot(d, vec2(-U.y, U.x)));
}
// The part of the box its light is taken in: the cells are too coarse to
// be right by its faces (by a window wall, a ceiling's edge came out
// lighter where the path tracer's was half as dark, user 2026-10-02);
// what is near a corner is the occlusion pass's (deferred_ssao.xml)
vec3 BoxInset(vec3 lo, vec3 hi)
{
    return min(vec3(0.4), (hi - lo) * 0.5);
}

// **The room's probes along it** (editor.lua's M.room_probes): the row
// before the point, the row after, and how far between
vec3 RoomProbes(float slot, vec3 p)
{
    vec2 rows = RoomRows(slot);
    float first = rows.x;
    float n = rows.y;
    if (n < 1.5)
        return vec3(first, first, 0.0);
    vec4 a = TableTexel(first, 6.0);
    vec4 b = TableTexel(first + n - 1.0, 6.0);
    vec2 p0 = vec2(Decode16(a.r, a.g), Decode16(a.b, a.a));
    vec2 p1 = vec2(Decode16(b.r, b.g), Decode16(b.b, b.a));
    vec2 d = p1 - p0;
    float t = clamp(dot(p.xz - p0, d) / max(dot(d, d), 1e-6), 0.0, 1.0) * (n - 1.0);
    float i = min(floor(t), n - 2.0);
    return vec3(first + i, first + i + 1.0, t - i);
}

// A probe face's look, right and up, as the face cameras have them
// (editor.lua's PROBE_FACES: +X, -X, +Y, -Y, +Z, -Z); a face is drawn
// with its top at the tile's top
void FaceAxes(float face, out vec3 f, out vec3 r, out vec3 u)
{
    if (face < 0.5) {
        f = vec3(1.0, 0.0, 0.0); r = vec3(0.0, 0.0, -1.0); u = vec3(0.0, 1.0, 0.0);
    } else if (face < 1.5) {
        f = vec3(-1.0, 0.0, 0.0); r = vec3(0.0, 0.0, 1.0); u = vec3(0.0, 1.0, 0.0);
    } else if (face < 2.5) {
        f = vec3(0.0, 1.0, 0.0); r = vec3(1.0, 0.0, 0.0); u = vec3(0.0, 0.0, -1.0);
    } else if (face < 3.5) {
        f = vec3(0.0, -1.0, 0.0); r = vec3(1.0, 0.0, 0.0); u = vec3(0.0, 0.0, 1.0);
    } else if (face < 4.5) {
        f = vec3(0.0, 0.0, 1.0); r = vec3(1.0, 0.0, 0.0); u = vec3(0.0, 1.0, 0.0);
    } else {
        f = vec3(0.0, 0.0, -1.0); r = vec3(-1.0, 0.0, 0.0); u = vec3(0.0, 1.0, 0.0);
    }
}
