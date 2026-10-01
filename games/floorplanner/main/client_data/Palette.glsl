// games/floorplanner: every surface of the plan, drawn from the palette.
//
// The palette is a texture of one row per entry (see palette_texture() in
// editor.lua for the layout); a vertex says which row in its texture
// coordinate. The pattern of each material type is made here from where
// the fragment is in the world, in metres, so it is the same size on
// every surface and continues across the walls' joins.
//
// Passes as Urho3D's LitSolid: forward (base, litbase, light) and
// deferred, with PLANLOOK drawing flat colours for the plan view.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Lighting.glsl"
#include "Fog.glsl"

varying vec3 vNormal;
varying vec4 vWorldPos;
varying vec2 vRow;
varying vec4 vColor;
#ifdef PERPIXEL
    #ifdef SHADOW
        #ifndef GL_ES
            varying vec4 vShadowPos[NUMCASCADES];
        #else
            varying highp vec4 vShadowPos[NUMCASCADES];
        #endif
    #endif
    #ifdef SPOTLIGHT
        varying vec4 vSpotPos;
    #endif
    #ifdef POINTLIGHT
        varying vec3 vCubeMaskVec;
    #endif
#else
    varying vec3 vVertexLight;
    varying vec4 vScreenPos;
#endif

#ifdef COMPILEPS
    uniform float cPaletteRows;
    uniform float cPlanLook;
    // **PBR** ([FP_DAYLIGHT]): the frame in radiance, metered and tone
    // mapped after; albedo decoded from the palette's sRGB, the ambient
    // the sky's times what of it reaches this face (its room's daylight
    // factor, which the vertex carries as 1 - it in the texture
    // coordinate's y), reflections of the sky's own cube, lamps at
    // vanilla's radiance. 0: the unlit look as it always was.
    uniform float cPbr;
    // Towards the sun, for the sky's brighter side ([FP_DAYLIGHT])
    uniform vec3 cSunToward;
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vNormal = GetWorldNormal(modelMatrix);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));
    vRow = iTexCoord;
    vColor = iColor;

    #ifdef PERPIXEL
        vec4 projWorldPos = vec4(worldPos, 1.0);
        #ifdef SHADOW
            for (int i = 0; i < NUMCASCADES; i++)
                vShadowPos[i] = GetShadowPos(i, vNormal, projWorldPos);
        #endif
        #ifdef SPOTLIGHT
            vSpotPos = projWorldPos * cLightMatrices[0];
        #endif
        #ifdef POINTLIGHT
            vCubeMaskVec = (worldPos - cLightPos.xyz) * mat3(cLightMatrices[0][0].xyz,
                    cLightMatrices[0][1].xyz, cLightMatrices[0][2].xyz);
        #endif
    #else
        vVertexLight = GetAmbient(GetZonePos(worldPos));
        #ifdef NUMVERTEXLIGHTS
            for (int i = 0; i < NUMVERTEXLIGHTS; ++i)
                vVertexLight += GetVertexLight(i, worldPos, vNormal) * cVertexLights[i * 3].rgb;
        #endif
        vScreenPos = GetScreenPos(gl_Position);
    #endif
}

#ifdef COMPILEPS

vec4 Texel(float i)
{
    return texture2D(sDiffMap, vec2((i + 0.5) / 8.0, (floor(vRow.x + 0.5) + 0.5) / cPaletteRows));
}

// Value noise: exact enough at house scale, and cheap
float Hash3(vec3 p)
{
    p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float Noise3(vec3 x)
{
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(Hash3(i), Hash3(i + vec3(1, 0, 0)), f.x),
            mix(Hash3(i + vec3(0, 1, 0)), Hash3(i + vec3(1, 1, 0)), f.x), f.y),
            mix(mix(Hash3(i + vec3(0, 0, 1)), Hash3(i + vec3(1, 0, 1)), f.x),
            mix(Hash3(i + vec3(0, 1, 1)), Hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float Fbm(vec3 p)
{
    return 0.5 * Noise3(p) + 0.25 * Noise3(p * 2.03) + 0.125 * Noise3(p * 4.01);
}

// Knots in wood: in a cell of `cell` metres now and then one, 4 to 15 mm
// in radius, stretched along the grain (x). Returns how much of the knot's
// core the point is in, and how far the rings nearby are bent round it.
// A knot is kept inside its cell across the grain, which is a board.
vec2 Knots(vec2 x, vec2 cell, float seed)
{
    vec2 c = floor(x / cell);
    vec2 k = vec2(0.0);
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            vec2 id = c + vec2(float(i), float(j));
            if (Hash3(vec3(id, seed)) > 0.3)
                continue;
            vec2 at = (id + vec2(Hash3(vec3(id, seed + 1.0)),
                    0.2 + 0.6 * Hash3(vec3(id, seed + 2.0)))) * cell;
            float rad = mix(0.004, 0.015, Hash3(vec3(id, seed + 3.0)));
            float dist = length((x - at) / vec2(1.6, 1.0)) / rad;
            k.x = max(k.x, 1.0 - smoothstep(0.75, 1.0, dist));
            k.y += 2.5 * exp(-dist * 0.35);
        }
    }
    return k;
}

// A knot's core: twice as far below the base as the grain's dark lines
// (0.9 - 0.18 at a contrast of 1)
float KnotShade(float contrast)
{
    return max(0.05, 0.9 - 0.36 * contrast);
}

float Luma(vec3 c)
{
    return dot(c, vec3(0.299, 0.587, 0.114));
}

// Where on a flat surface the fragment is: the two world axes across the
// face the normal is most along
// simplified: the dominant axis, not a blend of three, so a pattern on a
// wall at 45 degrees is stretched by up to 1.4
vec2 Plane(vec3 p, vec3 n)
{
    vec3 a = abs(n);
    if (a.y >= a.x && a.y >= a.z)
        return p.xz;
    if (a.x >= a.z)
        return vec2(p.z, p.y);
    return p.xy;
}

// The world axes of Plane()'s two
void PlaneAxes(vec3 n, out vec3 u, out vec3 v)
{
    vec3 a = abs(n);
    if (a.y >= a.x && a.y >= a.z) {
        u = vec3(1.0, 0.0, 0.0);
        v = vec3(0.0, 0.0, 1.0);
    } else if (a.x >= a.z) {
        u = vec3(0.0, 0.0, 1.0);
        v = vec3(0.0, 1.0, 0.0);
    } else {
        u = vec3(1.0, 0.0, 0.0);
        v = vec3(0.0, 1.0, 0.0);
    }
}

// A material at the fragment: its albedo, how much and how tightly it
// reflects light, its reflectiveness, its own light and its opacity; and
// the normal, which a pattern with a relief bends
void Surface(vec3 p, inout vec3 n, out vec3 albedo, out float spec, out float power,
        out float refl, out vec3 emissive, out float alpha)
{
    vec4 t0 = Texel(0.0);
    vec4 t1 = Texel(1.0);
    vec4 t2 = Texel(2.0);
    vec4 t3 = Texel(3.0);
    vec4 t4 = Texel(4.0);
    vec4 t5 = Texel(5.0);
    vec4 t6 = Texel(6.0);
    vec3 base = t0.rgb;
    float kind = floor(t0.a * 255.0 / 20.0 + 0.5);
    vec3 paint = t1.rgb;
    float finish = floor(t1.a * 255.0 / 32.0 + 0.5);
    vec3 second = t2.rgb;
    float opacity = t2.a;
    float roughness = t3.r;
    spec = t3.g;
    refl = t3.b;
    float seed = floor(t3.a * 255.0 + 0.5) + 256.0 * floor(t4.b * 255.0 + 0.5);
    // Pattern scale in mm, stored as a power of two
    float scale = exp2(t4.r * 16.0) / 1000.0;
    float flags = floor(t4.g * 255.0 / 16.0 + 0.5);
    float param = t4.a;
    // Wood's grain contrast, 1 as it always was, and paneling's angle
    float contrast = t5.g * 3.0;
    float angle = t5.r * 3.14159265;
    float polish = t5.b;
    float handmade = t5.a;
    vec3 sp = p + vec3(seed * 1.37, seed * 0.71, seed * 2.13);
    vec3 q = sp / scale;
    vec2 uv = Plane(p, n) / scale;
    emissive = vec3(0.0);
    alpha = 1.0;

    vec3 nat = base;
    if (cPlanLook > 0.5) {
        // The plan's flat colours: no pattern, and a lamp as its colour
    } else if (kind < 0.5) {
        // Drywall: all but flat
        nat = base * (0.97 + 0.03 * Noise3(p * 40.0));
    } else if (kind < 1.5) {
        // Wood: rings about the grain's axis, streaked along it
        float axis = mod(flags, 4.0);
        vec3 g = axis < 0.5 ? q.yzx : (axis < 1.5 ? q.xzy : q.xyz);
        // simplified: the knots are on the surface, grain along its first
        // axis, rather than branches through the solid
        vec2 knot = Knots(vec2(g.z, g.x + g.y) * scale, vec2(0.45, 0.2), seed);
        float r = length(g.xy) * 6.0 + Fbm(vec3(g.xy * 2.0, g.z * 0.15)) * 3.0 +
                knot.y;
        float ring = smoothstep(0.2, 0.9, fract(r));
        float streak = Noise3(vec3(g.xy * 40.0, g.z * 0.5));
        nat = base * (0.9 + (ring - 0.5) * 0.36 * contrast) *
                (0.98 + (streak - 0.5) * 0.12 * contrast);
        nat = mix(nat, base * KnotShade(contrast), knot.x);
    } else if (kind < 2.5) {
        // Stone: mottled, with veins of the second colour
        float m = Fbm(q * 3.0);
        float vein = abs(sin(q.x * 3.0 + q.y * 2.0 + Fbm(q * 2.0) * 7.0));
        nat = mix(base * (0.8 + 0.35 * m), second, smoothstep(0.96, 1.0, vein) * 0.8);
    } else if (kind < 3.5) {
        // Wallpaper: a motif the seed picks, in the second colour on the base
        vec2 f = fract(uv);
        float motif = mod(seed, 3.0);
        float on;
        if (motif < 0.5)
            on = step(0.5, f.x);
        else if (motif < 1.5)
            on = step(length(f - 0.5), 0.22);
        else
            on = step(0.25, sin(f.x * 6.2832) * sin(f.y * 6.2832) +
                    0.3 * Noise3(vec3(uv * 4.0, seed)));
        nat = mix(base, second, on);
    } else if (kind < 4.5) {
        // Lamp: its own light, in its colour
        emissive = base * param * 4.0;
    } else if (kind < 5.5) {
        // Glass: a tint and how much it lets through
        alpha = opacity;
    } else if (kind < 6.5) {
        // Metal: brushed along the plane's first axis
        nat = base * (0.9 + 0.1 * Noise3(vec3(uv.x * 2.0, uv.y * 300.0, 0.0)));
    } else if (kind < 7.5) {
        // Tiles: a grid of them, every other row shifted when staggered,
        // with grout of the second colour between
        vec2 t = uv;
        if (flags >= 4.0)
            t.x += 0.5 * mod(floor(t.y), 2.0);
        vec2 f = fract(t);
        float grout = param * 0.25;
        float in_grout = step(f.x, grout) + step(f.y, grout);
        nat = in_grout > 0.0 ? second : base * (0.95 + 0.07 * Hash3(vec3(floor(t), seed)));
    } else if (kind < 8.5) {
        // Fabric: a weave
        float w = sin(uv.x * 6.2832) * sin(uv.y * 6.2832);
        nat = base * (0.86 + 0.14 * w) * (0.95 + 0.05 * Noise3(vec3(uv * 0.1, 0.0)));
    } else if (kind < 9.5) {
        // Plaster: a soft mottle and fine speckle
        nat = base * (0.93 + 0.07 * Fbm(q * 8.0));
        nat += vec3(0.08) * step(0.975, Hash3(floor(p * 300.0))) * param;
    } else {
        // Paneling: boards `scale` wide, at the angle from the plane's first
        // axis (0 runs them level on a wall, 90 upright), a V-groove at each
        // seam, the grain along each board and every board its own.
        // Hand made, the seams wander and the boards are uneven: up to a
        // log wall's round logs of a sixth of their width up and down.
        vec2 pm = Plane(p, n);
        vec2 b = vec2(cos(angle) * pm.x + sin(angle) * pm.y,
                -sin(angle) * pm.x + cos(angle) * pm.y) / scale;
        b.y += handmade * 0.35 *
                (Noise3(vec3(b.x * scale * 1.2, b.y * 0.7, seed * 0.13)) - 0.5);
        float board = floor(b.y);
        float f = fract(b.y);
        float h = Hash3(vec3(board, seed, 3.7));
        // Metres along the board and across it
        float along = b.x * scale + h * 10.0;
        float across = f * scale;
        // Rings of a sawn log, some 8 mm apart, waving along the board
        vec2 knot = Knots(vec2(along, b.y * scale), vec2(0.35, scale), seed);
        float r = across * 125.0 + h * 7.0 +
                Fbm(vec3(along * 4.0, across * 20.0, board)) * 2.5 + knot.y;
        // Rings finer than a pixel are their average, not a moire
        float ring = mix(smoothstep(0.2, 0.9, fract(r)), 0.55,
                smoothstep(0.3, 0.8, fwidth(r)));
        float streak = mix(Noise3(vec3(along * 3.0, across * 500.0, board)), 0.5,
                smoothstep(0.3, 0.8, fwidth(across * 500.0)));
        nat = base * (0.93 + 0.14 * h) *
                (0.9 + (ring - 0.5) * 0.36 * contrast) *
                (0.98 + (streak - 0.5) * 0.12 * contrast);
        nat = mix(nat, base * KnotShade(contrast), knot.x);
        // Across the boards in the world, along the face
        vec3 pu, pv;
        PlaneAxes(n, pu, pv);
        vec3 t = -sin(angle) * pu + cos(angle) * pv;
        t = normalize(t - n * dot(t, n));
        vec3 s = normalize(cross(n, t));
        // The seam's groove, `gap` wide and `depth` deep, in tenths of a mm
        // in 16 bits: a V whose two sides slope down to the seam, and hand
        // made a round one, as two logs' sides meet. Its sides are shaded
        // the more the deeper and steeper; where the groove is under a
        // pixel its slope fades to the flat.
        float depth = (t6.b * 65280.0 + t6.a * 255.0) / 10000.0;
        // Hand made, the gap wanders in width, and its edges are chipped:
        // patches a few cm long where a piece has come off them
        float chip = max(0.0, Noise3(vec3(along * 18.0, board, 9.1)) - 0.55) * 2.2;
        float half_gap = min((t6.r * 65280.0 + t6.g * 255.0) / 20000.0,
                scale * 0.5) * (1.0 + handmade * 0.6 *
                (Noise3(vec3(along * 2.0, board, 5.3)) - 0.5) +
                handmade * chip);
        float d = min(f, 1.0 - f) * scale;
        // (fwidth outside the branch: a derivative needs all the quad)
        float blur = fwidth(d);
        float slope = 0.0;
        if (half_gap > 0.0 && d < half_gap) {
            float x = 1.0 - d / half_gap;
            float arc = sqrt(max(1.0 - x * x, 0.01));
            float low = mix(x, 1.0 - arc, handmade);
            float steep = depth / half_gap * mix(1.0, x / arc, handmade);
            slope = (f < 0.5 ? steep : -steep) *
                    (1.0 - smoothstep(0.5, 2.0, blur / half_gap));
            nat *= 1.0 - 0.55 * min(1.0, depth / half_gap * 2.0) * low;
        }
        // simplified: the unevenness is noise taken for the slopes, not the
        // gradient of a height; it reads as the same at these amplitudes
        float bumps = handmade * 0.3 * (1.0 - smoothstep(0.02, 0.1, blur));
        slope += bumps * (Noise3(vec3(along * 6.0, f * 3.0, board + seed)) - 0.5);
        float slope_s = bumps *
                (Noise3(vec3(along * 6.0 + 17.0, f * 3.0, board)) - 0.5);
        // Hand made, the boards have lived: drying cracks along the grain,
        // a few per board, wavering and thinning out at their ends; and
        // dings, small dents here and there. Each fades to its average
        // where it is finer than a pixel.
        if (handmade > 0.0) {
            float seg = along / 0.8 + h * 3.0;
            float k = Hash3(vec3(board, floor(seg), seed + 11.0));
            float u = fract(seg);
            float taper = smoothstep(0.0, 0.3, u) * smoothstep(1.0, 0.7, u);
            float cpos = (0.2 + 0.6 * Hash3(vec3(board, floor(seg), seed + 17.0))) *
                    scale + 0.006 * (Noise3(vec3(along * 5.0, board, 3.0)) - 0.5);
            float cw = (0.0006 + 0.0016 * k) * taper *
                    step(k, 0.75 * handmade);
            float dc = abs(across - cpos);
            float aa = max(fwidth(across), 1e-6);
            float crack = (1.0 - smoothstep(0.0, cw + aa, dc)) *
                    min(1.0, cw / aa);
            nat *= 1.0 - 0.75 * crack;
            slope += sign(across - cpos) * 0.6 * crack;
            // Dings here and there (user: as of a nail pulled out once),
            // in cells of 30 cm, one in about twelve, 3 to 8 mm across
            vec2 q2 = vec2(along, across) / 0.3;
            vec2 cell = floor(q2);
            float r = Hash3(vec3(cell, board + seed + 23.0));
            vec2 cen = cell + 0.2 + 0.6 * vec2(Hash3(vec3(cell, board + 29.0)),
                    Hash3(vec3(cell, board + 31.0)));
            float rad = 0.0015 + 0.0025 * Hash3(vec3(cell, board + 37.0));
            vec2 dv = (q2 - cen) * 0.3;
            float dd = length(dv);
            float seen = 1.0 - smoothstep(0.3, 1.0, fwidth(dd) / rad);
            if (r < 0.08 * handmade && dd < rad) {
                // A bowl 2 mm deep: its slope, out from the middle, and
                // the grime in it
                vec2 g = dv * (2.0 * 0.002 / (rad * rad)) * seen;
                slope += g.y;
                slope_s += g.x;
                nat *= 1.0 - 0.35 * (1.0 - dd / rad) * seen;
            }
        }
        // Rough sawn, the fibres stand up across the grain and the surface
        // is grit a millimetre or two across, lit and dark by turns, where
        // a pixel is finer than it; polished, the colour deepens as wetted
        // and the surface is a smooth mirror. Unfinished wood has no
        // highlight at all (user: a log wall at polish 0 was still shiny).
        float rough = 1.0 - polish;
        slope += (streak - 0.5) * 0.4 * rough;
        vec3 gp = p * 600.0;
        float grit = rough * (1.0 - smoothstep(0.3, 1.0, length(fwidth(gp))));
        slope += (Noise3(gp) - 0.5) * 0.6 * grit;
        slope_s += (Noise3(gp + 31.0) - 0.5) * 0.6 * grit;
        nat *= 1.0 + (Noise3(gp * 0.5 + 7.0) - 0.5) * 0.25 * grit;
        n = normalize(n - slope * t - slope_s * s);
        nat = pow(max(nat, vec3(0.0)), vec3(mix(0.85, 1.2, polish)));
        roughness = mix(1.0, 0.08, polish);
        spec = 0.6 * polish * sqrt(polish);
        refl = 0.25 * polish * polish;
    }

    // The finish: the paint over the material's own colour (only ever
    // darker), over a white undercoat, or as a translucent stain that
    // pulls each texel towards it
    if (finish < 0.5)
        albedo = nat * paint;
    else if (finish < 1.5)
        albedo = paint * mix(1.0, Luma(nat) / max(Luma(base), 0.01), 0.15);
    else
        albedo = mix(nat, paint, opacity);
    // Shinier where it is smoother
    power = mix(120.0, 4.0, roughness);
}

// A sky and a ground for what is reflected: the sky's cube under PBR, and
// an analytic one otherwise
// simplified: the open sky's even indoors; the upgrade is a probe per room
vec3 Environment(vec3 r)
{
    #if !defined(GL_ES) || __VERSION__ >= 300
        if (cPbr > 0.5)
            return textureCube(sZoneCubeMap, r).rgb * (1.0 - vRow.y);
    #endif
    return mix(vec3(0.35, 0.33, 0.30), vec3(0.75, 0.82, 0.92), smoothstep(-0.2, 0.3, r.y));
}

void PS()
{
    vec3 normal = normalize(vNormal);
    vec3 albedo, emissive;
    float spec, power, refl, alpha;
    Surface(vWorldPos.xyz, normal, albedo, spec, power, refl, emissive, alpha);
    albedo *= vColor.rgb;
    // A lamp switched off: its vertices' alpha is 0
    emissive *= vColor.a;
    // What of the ambient reaches this face
    float ambientShare = 1.0;
    if (cPbr > 0.5)
    {
        albedo = pow(max(albedo, vec3(0.0)), vec3(2.2));
        emissive = pow(max(emissive, vec3(0.0)), vec3(2.2)) * 8.0;
        ambientShare = 1.0 - vRow.y;
        // A face sees the sky by which way it is turned: all of it facing
        // up, half on a wall, the floor's bounce facing down; and the
        // sun's side of the sky is the brighter one. So the faces of a
        // room read apart where the ambient is all there is.
        vec2 sh = cSunToward.xz;
        float shl = length(sh);
        float side = shl > 0.01 ? dot(normal.xz, sh / shl) : 0.0;
        ambientShare *= (0.7 + 0.3 * normal.y) * (1.0 + 0.2 * side);
    }

    #ifdef HEIGHTFOG
        float fogFactor = GetHeightFogFactor(vWorldPos.w, vWorldPos.y);
    #else
        float fogFactor = GetFogFactor(vWorldPos.w);
    #endif

    vec3 eye = normalize(cCameraPosPS - vWorldPos.xyz);
    float fresnel = refl * (0.25 + 0.75 * pow(1.0 - max(dot(eye, normal), 0.0), 5.0));
    vec3 reflected = Environment(reflect(-eye, normal)) * fresnel;

    #if defined(PERPIXEL)
        vec3 lightDir;
        float diff = GetDiffuse(normal, vWorldPos.xyz, lightDir);
        #ifdef SHADOW
            diff *= GetShadow(vShadowPos, vWorldPos.w);
        #endif
        #if defined(SPOTLIGHT)
            vec3 lightColor = vSpotPos.w > 0.0 ? texture2DProj(sLightSpotMap, vSpotPos).rgb * cLightColor.rgb : vec3(0.0);
        #elif defined(CUBEMASK)
            vec3 lightColor = textureCube(sLightCubeMap, vCubeMaskVec).rgb * cLightColor.rgb;
        #else
            vec3 lightColor = cLightColor.rgb;
        #endif
        float s = GetSpecular(normal, cCameraPosPS - vWorldPos.xyz, lightDir, power);
        vec3 finalColor = diff * lightColor * (albedo + s * spec);
        if (cPlanLook > 0.5)
            finalColor = vec3(0.0);
        #ifdef AMBIENT
            finalColor += cAmbientColor.rgb * albedo * ambientShare + emissive + reflected;
            if (cPlanLook > 0.5)
                finalColor = albedo;
            gl_FragColor = vec4(GetFog(finalColor, fogFactor), alpha);
        #else
            gl_FragColor = vec4(GetLitFog(finalColor, fogFactor), alpha);
        #endif
    #elif defined(DEFERRED)
        vec3 finalColor = vVertexLight * albedo * ambientShare + emissive + reflected;
        if (cPlanLook > 0.5)
            finalColor = albedo;
        gl_FragData[0] = vec4(GetFog(finalColor, fogFactor), 1.0);
        gl_FragData[1] = fogFactor * vec4(cPlanLook > 0.5 ? vec3(0.0) : albedo, spec);
        gl_FragData[2] = vec4(normal * 0.5 + 0.5, power / 255.0);
        gl_FragData[3] = vec4(EncodeDepth(vWorldPos.w), 0.0);
    #else
        vec3 finalColor = vVertexLight * albedo * ambientShare + emissive + reflected;
        if (cPlanLook > 0.5)
            finalColor = albedo;
        gl_FragColor = vec4(GetFog(finalColor, fogFactor), alpha);
    #endif
}

#endif
