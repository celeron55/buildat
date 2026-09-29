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

// A material at the fragment: its albedo, how much and how tightly it
// reflects light, its reflectiveness, its own light and its opacity
void Surface(vec3 p, vec3 n, out vec3 albedo, out float spec, out float power,
        out float refl, out vec3 emissive, out float alpha)
{
    vec4 t0 = Texel(0.0);
    vec4 t1 = Texel(1.0);
    vec4 t2 = Texel(2.0);
    vec4 t3 = Texel(3.0);
    vec4 t4 = Texel(4.0);
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
        float r = length(g.xy) * 6.0 + Fbm(vec3(g.xy * 2.0, g.z * 0.15)) * 3.0;
        float ring = smoothstep(0.2, 0.9, fract(r));
        float streak = Noise3(vec3(g.xy * 40.0, g.z * 0.5));
        nat = base * mix(0.72, 1.08, ring) * (0.92 + 0.12 * streak);
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
    } else {
        // Plaster: a soft mottle and fine speckle
        nat = base * (0.93 + 0.07 * Fbm(q * 8.0));
        nat += vec3(0.08) * step(0.975, Hash3(floor(p * 300.0))) * param;
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

// A sky and a ground for what is reflected
// simplified: an analytic sky rather than a captured cube map; the upgrade
// is a probe per room
vec3 Environment(vec3 r)
{
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
            finalColor += cAmbientColor.rgb * albedo + emissive + reflected;
            if (cPlanLook > 0.5)
                finalColor = albedo;
            gl_FragColor = vec4(GetFog(finalColor, fogFactor), alpha);
        #else
            gl_FragColor = vec4(GetLitFog(finalColor, fogFactor), alpha);
        #endif
    #elif defined(DEFERRED)
        vec3 finalColor = vVertexLight * albedo + emissive + reflected;
        if (cPlanLook > 0.5)
            finalColor = albedo;
        gl_FragData[0] = vec4(GetFog(finalColor, fogFactor), 1.0);
        gl_FragData[1] = fogFactor * vec4(cPlanLook > 0.5 ? vec3(0.0) : albedo, spec);
        gl_FragData[2] = vec4(normal * 0.5 + 0.5, power / 255.0);
        gl_FragData[3] = vec4(EncodeDepth(vWorldPos.w), 0.0);
    #else
        vec3 finalColor = vVertexLight * albedo + emissive + reflected;
        if (cPlanLook > 0.5)
            finalColor = albedo;
        gl_FragColor = vec4(GetFog(finalColor, fogFactor), alpha);
    #endif
}

#endif
