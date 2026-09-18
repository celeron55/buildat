// A fork of builtin/voxel_shading's PBRVoxel.glsl, and no longer a copy of it.
//
// It started as one because a Luanti client cannot use the built-in shader:
// builtin/ is not on a client's resource path and there is no buildat server
// to deliver it. What keeps the two apart now is that a good deal of what is
// in here is an art style rather than a mechanism -- how far a spot turns, how
// narrowly a leaf passes light through itself -- and this client's worlds and
// games/voxel_lighting's are not the same worlds. Tuning one of them through a
// shared file retunes the other, which is how voxel_lighting's rock quietly
// lost its speckle.
//
// So the two are not kept in step. A fix to the machinery is worth carrying
// across by hand; a number that decides how something looks is not. What
// differs today, and why:
//
//   cSkyLight, cSkyTint, cSkyTintAmount
//                       VOXELSKYTINT only, which is builtin/luanti's own
//                       client: the brightness of the sky's contribution and
//                       a hue to move the cube map towards, in place of
//                       cSkyColor. See the uniforms below for why they are
//                       two knobs rather than one.
//   cSkyColor           Only here. The colour the sky is at this moment, which
//                       the client pushes so that reflections follow the sky
//                       it paints without a cube map being rebaked.
//   SPOT_TILT           0.06 here, 0.45 there. A Luanti game's ground is
//                       plants the whole way across and every one of them can
//                       hold a spot, so the sparkle has to gather tightly
//                       around the light or it reads as glitter over a field.
//                       voxel_lighting's few surfaces are sparsely spotted and
//                       a wide turn is what makes them catch anything at all.
//   TRANSMISSION_FOCUS  A thirty-second power here against a sixth there, for
//                       the same reason: a canopy of Luanti leaves glowing
//                       over a quarter of the sky stops reading as the sun
//                       behind it.
//   spotGloss           Ramped on sharply here, linear there. With plants this
//                       dense, the half open cells -- most of them at any
//                       moment -- are a sheen that follows the light.
//
// STATIC_SPOT_TILT is the same number in both and wants to stay that way: a
// facet is a chip of rock either way, and narrowing it does not gather the
// speckle anywhere, it only takes it off the sand.
//
// Copied from CoreData/Shaders/GLSL/PBRLitSolid.glsl (Urho3D 1.7.1). Two
// changes, both about how voxel skylight reaches the ambient term:
//
//   VS  vVertexLight mixes the zone ambient with the vertex color instead of
//       being the zone ambient alone
//   PS  the vertex color is not multiplied into diffColor
//
// The mesher packs a voxel's lighting into the vertex color as
//   rgb = light bounced off nearby surfaces, already attenuated
//   a   = how much of the sky the surface sees
// so the ambient a surface receives is
//   cAmbientColor.rgb * color.a + color.rgb
// which is a real mix of two colors: sky blue where the sky is visible, and
// the neutral grey of bounced light where it is not. Ambient occlusion and a
// per-face brightness are already folded into both terms by the mesher.
//
// Direct light is deliberately left alone, unless VOXELSUNGATE is defined:
// with it, the directional light is multiplied by the vertex color's alpha, so
// that a world whose light value says "underground" gets no sun. That is for a
// world whose light curve is built for it -- see PBR_LIGHT_MAP in the Luanti
// client's world.lua; without such a curve it would darken shadowed faces
// twice, which is why it is off by default.
//
// On top of that, two things the stock PBR shaders do differently:
//
//   VOXELNORMALMAP  the tangent frame is built from the derivatives of the
//       world position and the texture coordinate rather than from a vertex
//       attribute, because the voxel mesher writes no tangent -- the vertex's
//       tangent slot carries the surface modifiers instead, when there are any
//   VOXELIBL  reflections of the zone cube map, specular only. The diffuse
//       half of image based lighting is left out: the skylight in the vertex
//       color is already the scene's ambient diffuse, and adding an
//       unoccluded sky on top of it would light the inside of a cave. The
//       specular term is scaled by the same skylight for the same reason.
//       cSkyVis dims the cube map by direction: it is how much of the sky the
//       camera can see each way, as 6x6 values per cube face, which the client
//       fills by marching the voxel data. So a tunnel's walls stop reflecting
//       sky while the sky out of its mouth still reflects, and a cave seen
//       from outside reflects no horizon band it cannot see. There is no
//       separate indoor cube map: the same sky, dimmed where it is not
//       visible, is what a surface indoors reflects.
//   VOXELSPOTS  which parts of a surface are turned to catch the light at this
//       moment. Worked out per pixel from world position and time rather than
//       stored, so the specks come and go the way leaves in wind do, and a
//       surface with no animated normal map can still sparkle.
//   VOXELMODIFIERS  the voxel format's surface modifiers, which the mesher
//       wrote into the vertex tangent: an albedo tint, and wetness, grain and
//       gloss changing the albedo, the roughness and how much of the texture's
//       relief is kept. Off by default, because a world that binds no modifier
//       has nothing in the tangent; see PBRVoxelModifiers.xml.
//   VOXELTRANSLUCENCY  light reaching a surface from behind and coming through
//       it at those spots, tinted by the surface's own color. This is why a
//       leaf against the sun reads yellow-green and not as the blue of the sky
//       lighting its front.
//
// sSpecMap carries roughness in r, where Urho's own PBR shaders read it, and
// spec_strength, translucency and the spot fraction in gba. Metalness is not
// per texel here; nothing has been metal yet, so it stays cMetallic.

#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Lighting.glsl"
#include "Constants.glsl"
#include "Fog.glsl"
#include "PBR.glsl"
#include "IBL.glsl"
#line 30010

// Light bounced off the surroundings, in the same units as the zone's
// ambient, reaching a surface in proportion to how much sky it does not
// see: the second term of the ambient ([PBR_FIT] term 2), so that a cave
// is lit by the day outside it rather than black, and by nothing at
// night. The client sets it with the hour; unset it reads as zero and the
// shader is what it was. The mesher's own bounce (0.055, the lamps' unit)
// stays in the vertex colour beside it and is small in these units.
// simplified: no hemisphere weighting -- a vertical face in the open gets
// no ground bounce, since its sky visibility is one. The upgrade is a
// ground radiance times (1 - n.y) / 2 on top, once the render says how much.
uniform vec3 cBounceLight;
// And the ground: what the lower hemisphere of a face outdoors sees, the
// radiance of sunlit and sky-lit ground, which a vertical face gets half
// of and a ceiling all of. In the ambient's units, set by the client from
// the sun and the sky of the hour times the ground's albedo; the warm
// bounce that the path trace's second bounce puts on a terrace's side.
// Scaled by the shaped skylight so a cave's ceiling does not see a sunlit
// field through the rock.
uniform vec3 cGroundLight;

#if defined(NORMALMAP)
    varying vec4 vTexCoord;
    varying vec4 vTangent;
#else
    varying vec2 vTexCoord;
#endif
varying vec3 vNormal;
varying vec4 vWorldPos;
#ifdef VOXELMODIFIERS
    varying vec4 vSurface;
#endif
#ifdef PERPIXEL
    #ifdef SHADOW
        #ifndef GL_ES
            varying vec4 vShadowPos[NUMCASCADES];
        #else
            varying highp vec4 vShadowPos[NUMCASCADES];
        #endif
    #endif
    #ifdef VOXELSUNGATE
        // How much of the sky this vertex sees, which on the light pass is
        // what says whether the sun can reach it at all; see below
        varying float vSkyVisibility;
    #endif
    #ifdef SPOTLIGHT
        varying vec4 vSpotPos;
    #endif
    #ifdef POINTLIGHT
        varying vec3 vCubeMaskVec;
    #endif
#else
    varying vec3 vVertexLight;
    // How much of the sky this vertex sees, ambient occlusion included; the
    // alpha the mesher packed into the vertex color
    varying float vSkyVisibility;
    varying vec4 vScreenPos;
    #ifdef ENVCUBEMAP
        varying vec3 vReflectionVec;
    #endif
    #if defined(LIGHTMAP) || defined(AO)
        varying vec2 vTexCoord2;
    #endif
#endif

// **What the skylight nibble is allowed to say**, for the client that turns
// this on. On the PBR path the sun is a real light with a shadow map, and
// the shadow map is what darkens what is under a tree -- so node lighting is
// left to answer the one question a shadow map cannot, "am I underground",
// and nothing else. The curve holds at full until the light has fallen far
// enough that it can only be rock overhead, and then drops away: a canopy
// reads 11..14 of 15 and stays fully lit, a cave reads 0..2 and goes dark,
// and a doorway is the band between.
//
// extensions/luanti_client shapes the same nibble in its own block copy,
// with the same knee -- see PBR_LIGHT_MAP in its world.lua, whose comment
// says what the knee is for: *raise it and overhangs start being darkened
// twice, once here and once by the shadow map.* That double is exactly what
// this is here to stop; see [AMBIENT_LEVEL] in doc/plan/rendering_plan.md.
//
// Behind VOXELSKYCURVE because the extension has already applied it before
// the mesher sees the value and must not apply it again.
#ifdef VOXELSKYCURVE
    const float SKY_KNEE_LOW = 2.0 / 15.0;
    const float SKY_KNEE_HIGH = 11.0 / 15.0;

    float ShapeSkylight(float sky)
    {
        float t = clamp((sky - SKY_KNEE_LOW) /
            (SKY_KNEE_HIGH - SKY_KNEE_LOW), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }
#else
    float ShapeSkylight(float sky)
    {
        return sky;
    }
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vNormal = GetWorldNormal(modelMatrix);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));

    #ifdef VOXELMODIFIERS
        // The voxel format's surface modifiers, which the mesher wrote into
        // the tangent. Not transformed: they are numbers, not a direction.
        vSurface = iTangent;
    #endif


    #if defined(NORMALMAP) || defined(DIRBILLBOARD)
        vec4 tangent = GetWorldTangent(modelMatrix);
        vec3 bitangent = cross(tangent.xyz, vNormal) * tangent.w;
        vTexCoord = vec4(GetTexCoord(iTexCoord), bitangent.xy);
        vTangent = vec4(tangent.xyz, bitangent.z);
    #else
        vTexCoord = GetTexCoord(iTexCoord);
    #endif

    #ifdef PERPIXEL
        // Per-pixel forward lighting
        vec4 projWorldPos = vec4(worldPos, 1.0);

        #ifdef VOXELSUNGATE
            vSkyVisibility = ShapeSkylight(iColor.a);
        #endif

        #ifdef SHADOW
            // Shadow projection: transform from world space to shadow space
            for (int i = 0; i < NUMCASCADES; i++)
                vShadowPos[i] = GetShadowPos(i, vNormal, projWorldPos);
        #endif

        #ifdef SPOTLIGHT
            // Spotlight projection: transform from world space to projector texture coordinates
            vSpotPos = projWorldPos * cLightMatrices[0];
        #endif

        #ifdef POINTLIGHT
            vCubeMaskVec = (worldPos - cLightPos.xyz) * mat3(cLightMatrices[0][0].xyz, cLightMatrices[0][1].xyz, cLightMatrices[0][2].xyz);
        #endif
    #else
        // Ambient & per-vertex lighting
        #if defined(LIGHTMAP) || defined(AO)
            // If using lightmap, disregard zone ambient light
            // If using AO, calculate ambient in the PS
            vVertexLight = vec3(0.0, 0.0, 0.0);
            vTexCoord2 = iTexCoord1;
        #else
            // The sky's share is the nibble as it is, not the shaped one:
            // the knee is for the sun, whose shadow map already darkens a
            // canopy's floor; the sky is not in the shadow map, and a face
            // under leaves does see less of it -- 11..14 of 15 is what
            // Luanti says it sees. The render's canopy-shaded snow reads
            // 0.6 of open shade ([PBR_FIT] term 2). The bounce keeps the
            // shaped value: a canopy is not a cave.
            vVertexLight = GetAmbient(GetZonePos(worldPos)) * iColor.a +
                iColor.rgb +
                cBounceLight * (1.0 - ShapeSkylight(iColor.a)) +
                cGroundLight * (0.5 - 0.5 * vNormal.y) *
                    ShapeSkylight(iColor.a);
        #endif
        vSkyVisibility = ShapeSkylight(iColor.a);

        #ifdef NUMVERTEXLIGHTS
            for (int i = 0; i < NUMVERTEXLIGHTS; ++i)
                vVertexLight += GetVertexLight(i, worldPos, vNormal) * cVertexLights[i * 3].rgb;
        #endif

        vScreenPos = GetScreenPos(gl_Position);

        #ifdef ENVCUBEMAP
            vReflectionVec = worldPos - cCameraPos;
        #endif
    #endif
}

#ifdef COMPILEPS
    // How much of the surface is letting light through at this point, right
    // now. A leaf lets light past when it happens to have a gap behind it, and
    // in any wind that is a different leaf a moment later, so this is a
    // function of where and when rather than a map: nothing about it is stored
    // per texel.
    //
    // The world is diced into cells a fraction of a voxel across. Each cell
    // gets its own phase and its own rate from a hash of its position, and
    // opens and closes on a sine of those; the threshold decides how much of
    // that cycle counts as open, and so what fraction of cells are open at
    // once. A slow term along the wind direction is added to the phase, which
    // turns what would be an even twinkle into gusts crossing the surface.

    // The sky visibility cube and its lookup, beside this file. At column
    // zero because Urho3D's Shader::ProcessSource() only consumes an
    // #include that starts its line; indented, it reaches the GLSL
    // compiler as "include not found".
#include "SkyVis.glsl"

    // Multiplies the reflected sky, for looking at the reflections rather
    // than at the scene. 1 is what a game renders; the benchmarks turn it up
    // so that changes to the sky visibility sampling are visible at all --
    // most of a cave is rock reflecting almost nothing, and a change worth
    // arguing about moves a wall by a fraction of a value out of 255. Zero
    // when nothing sets it, so voxel_shading pushes it every frame.
    uniform float cSpecEmphasis;

    // What the sky is worth now, as a colour: the cube map beside this file is
    // one static noon gradient, and this is what makes it a sunset, a
    // thunderstorm or the green of being under water. The client sets it from
    // the same colours it paints the sky with, so the reflections follow the
    // sky without a cube map being rebaked. Zero when nothing sets it, which
    // is why the client pushes it with the sky.
    uniform vec3 cSkyColor;

    #ifdef VOXELSKYTINT
        // What builtin/luanti's own client drives instead of cSkyColor: the
        // brightness of the sky's contribution, and a hue to move the cube
        // map towards without changing how bright it answers. Behind a
        // define because **a shader parameter a material never sets reads as
        // zero**: the techniques in this directory that do not declare it
        // never see these, so their materials never have to set them.
        //
        // The two are not the same knob. cSkyColor multiplies, so a dim sky
        // dims the reflection and a coloured one colours it together;
        // cSkyTint keeps the luminance the cube gives and moves only the
        // hue, with cSkyLight scaling separately. A client that wants a
        // night that is dark and blue rather than dark and grey wants the
        // second.
        uniform float cSkyLight;
        uniform vec3 cSkyTint;
        uniform float cSkyTintAmount;
    #endif

    const float TRANSMISSION_CELLS = 16.0;   // Cells per voxel, per axis
    // A material whose own roughness is already below this cannot glint, so
    // water is given a duller base than a still pond would have
    const float SPOT_ROUGHNESS = 0.10;
    // How far a spot turns away from the surface it is on. This is what makes
    // a spot catch the sun: glossiness on its own only shows where the thing
    // being reflected has some contrast to it, and the sky in the cube map is
    // a smooth gradient with no sun drawn in it, so a sharper reflection of it
    // looks no different from a blurred one. A turned normal moves the direct
    // sunlight's own highlight instead, which is the bright thing in the scene.
    //
    // It is also what decides how far from the light the sparkle reaches. A
    // spot turned this far catches the sun from anywhere within that angle of
    // the mirror direction, so a large one puts glints over a whole field
    // rather than in the band where the light is actually being reflected.
    const float SPOT_TILT = 0.06;
    // Bigger than the moving ones: a facet is a chip of rock, not a leaf.
    // Taken from the world position for the same reason as those, that a map
    // lives in one voxel face and would repeat every voxel.
    const float STATIC_SPOT_CELLS = 6.0;     // Cells per voxel, per axis
    // Left where it was when the moving kind was narrowed: a facet is a chip
    // of rock that is flat and stays turned, not a leaf that has caught the
    // light for a moment, and narrowing it takes the speckle off sand and
    // gravel rather than gathering it anywhere.
    const float STATIC_SPOT_TILT = 0.35;
    // How narrowly the light through a surface is aimed at the camera. Light
    // coming through a leaf is light going the way it was already going, so it
    // is seen looking back along it and not from the side: at the width a
    // sixth power gives, a canopy glows over a quarter of the sky and the glow
    // stops reading as the sun behind it.
    const float TRANSMISSION_FOCUS = 32.0;
    const float TRANSMISSION_RATE = 0.03;    // Cycles per second, mean
    const vec3 TRANSMISSION_WIND = vec3(0.35, 0.0, -0.2);

    // fract(sin(dot(...))) loses its uniformity once the coordinates get
    // large, and a cell index here is the world position times sixteen, so
    // this hashes by mixing fractional parts instead and stays even across the
    // whole volume.
    float TransmissionHash(vec3 cell)
    {
        vec3 p = fract(cell * 0.1031);
        p += dot(p, p.yzx + 33.33);
        return fract((p.x + p.y) * p.z);
    }

    // How much of a spot this point is, right now. Each cell runs its own
    // cycle, at its own rate and from its own starting point, and is a spot for
    // openFraction of it. Working in the cycle's own
    // 0..1 position rather than in the height of a wave keeps that fraction
    // exact: near the top of a sine the wave is almost flat, so a threshold
    // that lets 4 per cent of cells fully open leaves another 10 per cent
    // hovering just under it, and the surface hazes over instead of speckling.
    // Which way a spot has turned, before it is flattened onto the surface.
    // Constant per cell, so a spot holds still while it is open rather than
    // shimmering within itself.
    vec3 GetSpotTilt(vec3 worldPos, float cells)
    {
        vec3 cell = floor(worldPos * cells);
        return vec3(TransmissionHash(cell + 41.0),
            TransmissionHash(cell + 67.0),
            TransmissionHash(cell + 89.0)) * 2.0 - 1.0;
    }

    // A still spot is on or off with no fade: a facet has an edge, and its
    // tilt is constant across the cell, so it reads as one flat surface.
    float GetStaticSpots(vec3 worldPos, float fraction)
    {
        if (fraction <= 0.0)
            return 0.0;
        vec3 cell = floor(worldPos * STATIC_SPOT_CELLS);
        return TransmissionHash(cell + 7.0) < fraction ? 1.0 : 0.0;
    }


    float GetSurfaceSpots(vec3 worldPos, float openFraction)
    {
        // No spots at all: none of the surface is one. The translucency term
        // wants the opposite of this -- a material with no spots lets light
        // through all over rather than nowhere -- and says so where it uses
        // it, rather than here, where the value is also the mask that glosses
        // the surface and turns its normal. Returning 1.0 here made every
        // material that named no spots fully spotted: its whole surface took
        // the spot roughness and a per cell random tilt, which is the speckle
        // that showed on plain rock and grass.
        if (openFraction <= 0.0)
            return 0.0;
        vec3 cell = floor(worldPos * TRANSMISSION_CELLS);
        float rate = TRANSMISSION_RATE * (0.6 + TransmissionHash(cell + 19.0));
        // A slow ramp along the wind direction, which turns what would be an
        // even twinkle into gusts crossing the surface
        float gust = dot(worldPos, TRANSMISSION_WIND);
        float u = fract(TransmissionHash(cell) + cElapsedTimePS * rate + gust);
        // Fade in and out rather than blink, using a quarter of the window at
        // each end so that a gap is still fully open in the middle of it
        float edge = openFraction * 0.25;
        return smoothstep(0.0, edge, u) *
            (1.0 - smoothstep(openFraction - edge, openFraction, u));
    }
#endif

void PS()
{
    // Get material diffuse albedo
    #ifdef DIFFMAP
        vec4 diffInput = texture2D(sDiffMap, vTexCoord.xy);
        #ifdef ALPHAMASK
            if (diffInput.a < 0.5)
                discard;
        #endif
        // The atlas is a game's textures as they come, display-encoded, and
        // this path lights in linear and encodes once at the end: read as
        // linear, an sRGB texel is an albedo a third too bright and half
        // as saturated -- grass read max/min 1.7 against the render's 3.9
        // off the same PNG, which Cycles decodes ([PBR_FIT]). Decoded here.
        // simplified: 2.2, not the sRGB curve; the difference is under the
        // texel's own quantisation.
        diffInput.rgb = pow(diffInput.rgb, vec3(2.2));
        vec4 diffColor = cMatDiffColor * diffInput;
    #else
        vec4 diffColor = cMatDiffColor;
    #endif


    #ifdef VOXELMODIFIERS
        // simplified: the four slots are read as tint, wetness, grain and
        // gloss, which is the first four of the engine's surface roles in
        // its own order. A world that binds exactly those gets this; one
        // that binds a different set -- speckle, emission, or only two of
        // these -- gets the slots shifted and has to write its own shader,
        // which is what a game does anyway once it knows what it wants its
        // materials to look like. The upgrade path is a uniform naming the
        // role in each slot, at the cost of a branch per slot.
        float mTint = vSurface.x;
        float mWetness = vSurface.y;
        float mGrain = vSurface.z;
        float mGloss = vSurface.w;

        // The tint is a colour rather than a scalar, packed 5-6-5; see
        // VoxelFormat::tint in interface/voxel.h. It multiplies the albedo,
        // which is the whole reason it travels here instead of in the vertex
        // colour: the vertex colour is light.
        float tintPacked = floor(mTint + 0.5);
        float tintR = floor(tintPacked / 2048.0);
        float tintG = floor((tintPacked - tintR * 2048.0) / 32.0);
        float tintB = tintPacked - tintR * 2048.0 - tintG * 32.0;
        diffColor.rgb *= vec3(tintR / 31.0, tintG / 63.0, tintB / 31.0);

        // Wet darkens and sharpens: water fills the pores of a surface, so
        // less light scatters back out of it and more reflects off the film
        // on top. Both are what a wet pavement does.
        diffColor.rgb *= 1.0 - 0.45 * mWetness;
    #endif

    // How much of a spot this pixel is. Used twice: to gloss the surface here,
    // and to let light through it in the lighting below.
    float surfaceSpots = 0.0;
    float staticSpots = 0.0;

    #ifdef METALLIC
        vec4 surfaceSrc = texture2D(sSpecMap, vTexCoord.xy);

        float roughness = surfaceSrc.r + cRoughness;
        float metalness = cMetallic;
        float specStrength = surfaceSrc.g;
        #ifdef VOXELSPOTS
            surfaceSpots = GetSurfaceSpots(vWorldPos.xyz, surfaceSrc.a);
            staticSpots = GetStaticSpots(vWorldPos.xyz,
                texture2D(sNormalMap, vTexCoord.xy).a);
            // A spot is glossy because it is a leaf or a facet that has
            // turned, and one that has half turned is a smaller turn rather
            // than a wider, duller highlight: the fade belongs in the tilt,
            // which carries it below. Ramping the gloss on sharply instead is
            // what keeps the half open cells -- which at any moment are most
            // of them -- from being a broad sheen that follows the light
            // across a whole field.
            float spotMask = max(surfaceSpots, staticSpots);
            float spotGloss = spotMask * spotMask * spotMask;
            roughness = mix(roughness, SPOT_ROUGHNESS, spotGloss);
            // Full strength however matte the rest is, so that rock can be
            // dull everywhere except at its facets
            specStrength = mix(specStrength, 1.0, spotGloss);
        #endif
    #else
        float roughness = cRoughness;
        float metalness = cMetallic;
        float specStrength = 1.0;
    #endif

    #ifdef VOXELMODIFIERS
        // Wetness and the binder both smooth a surface; the binder also
        // gives it something to shine with, where a wet surface shines with
        // the water on it
        roughness *= 1.0 - 0.55 * mWetness - 0.45 * mGloss;
        specStrength = mix(specStrength, 1.0,
            max(0.7 * mWetness, 0.8 * mGloss));
    #endif

    roughness *= roughness;

    roughness = clamp(roughness, ROUGHNESS_FLOOR, 1.0);
    metalness = clamp(metalness, METALNESS_FLOOR, 1.0);

    vec3 specColor = mix(0.08 * specStrength * cMatSpecColor.rgb,
        diffColor.rgb, metalness);
    diffColor.rgb = diffColor.rgb - diffColor.rgb * metalness;

    // Get normal
    #if defined(NORMALMAP) || defined(DIRBILLBOARD)
        vec3 tangent = vTangent.xyz;
        vec3 bitangent = vec3(vTexCoord.zw, vTangent.w);
        mat3 tbn = mat3(tangent, bitangent, vNormal);
    #endif

    #ifdef NORMALMAP
        vec3 nn = DecodeNormal(texture2D(sNormalMap, vTexCoord.xy));
        //nn.rg *= 2.0;
        vec3 normal = normalize(tbn * nn);
    #elif defined(VOXELNORMALMAP)
        // Cotangent frame: the tangent is the direction in world space that
        // the texture's u axis runs, recovered from the screen space
        // derivatives. Voxel faces are flat and axis aligned, so this is exact
        // for them and costs no vertex attribute.
        vec3 geomNormal = normalize(vNormal);
        vec3 dpdx = dFdx(vWorldPos.xyz);
        vec3 dpdy = dFdy(vWorldPos.xyz);
        vec2 dtdx = dFdx(vTexCoord.xy);
        vec2 dtdy = dFdy(vTexCoord.xy);
        vec3 dpdyPerp = cross(dpdy, geomNormal);
        vec3 dpdxPerp = cross(geomNormal, dpdx);
        vec3 tangentU = dpdyPerp * dtdx.x + dpdxPerp * dtdy.x;
        vec3 tangentV = dpdyPerp * dtdx.y + dpdxPerp * dtdy.y;
        float invMax = inversesqrt(max(dot(tangentU, tangentU),
            dot(tangentV, tangentV)));
        vec3 nn = DecodeNormal(texture2D(sNormalMap, vTexCoord.xy));
        #ifdef VOXELMODIFIERS
            // Grain is how fine the material is. A coarse surface keeps the
            // relief its texture's normal map has; a fine one -- sand, flour
            // -- has relief far below a texel and reads as flat, so the
            // normal is pulled towards the face's own.
            //
            // Not renormalized: the frame below is not orthonormal, so
            // normalizing here changes the shading of every surface and not
            // only of a grainy one -- which showed up as glints on a world
            // that had bound no grain at all.
            nn.xy *= 1.0 - 0.8 * mGrain;
        #endif
        vec3 normal = normalize(mat3(tangentU * invMax, tangentV * invMax,
            geomNormal) * nn);
    #else
        vec3 normal = normalize(vNormal);
    #endif

    #ifdef VOXELSPOTS
        // A spot is a piece of the surface that has turned: a leaf facing a
        // different way, or a ripple. Same mask as the gloss and the
        // transmission, so all three are the same event.
        //
        // The turn is taken across the surface rather than in any direction.
        // A free direction tips some normals past the horizon, and those
        // reflect the ground half of the cube map: brown specks on water.
        vec3 spotTilt =
            GetSpotTilt(vWorldPos.xyz, TRANSMISSION_CELLS) *
                (SPOT_TILT * surfaceSpots) +
            GetSpotTilt(vWorldPos.xyz, STATIC_SPOT_CELLS) *
                (STATIC_SPOT_TILT * staticSpots);
        spotTilt -= normal * dot(spotTilt, normal);
        normal = normalize(normal + spotTilt);
    #endif

    // Get fog factor
    #ifdef HEIGHTFOG
        float fogFactor = GetHeightFogFactor(vWorldPos.w, vWorldPos.y);
    #else
        float fogFactor = GetFogFactor(vWorldPos.w);
    #endif

    #if defined(PERPIXEL)
        // Per-pixel forward lighting
        vec3 lightColor;
        vec3 lightDir;
        vec3 finalColor;

        float atten = 1;

        #if defined(DIRLIGHT)
            atten = GetAtten(normal, vWorldPos.xyz, lightDir);
        #elif defined(SPOTLIGHT)
            atten = GetAttenSpot(normal, vWorldPos.xyz, lightDir);
        #else
            atten = GetAttenPoint(normal, vWorldPos.xyz, lightDir);
        #endif

        float shadow = 1.0;
        #ifdef SHADOW
            shadow = GetShadow(vShadowPos, vWorldPos.w);
        #endif

        #if defined(SPOTLIGHT)
            lightColor = vSpotPos.w > 0.0 ? texture2DProj(sLightSpotMap, vSpotPos).rgb * cLightColor.rgb : vec3(0.0, 0.0, 0.0);
        #elif defined(CUBEMASK)
            lightColor = textureCube(sLightCubeMap, vCubeMaskVec).rgb * cLightColor.rgb;
        #else
            lightColor = cLightColor.rgb;
        #endif

        #if defined(DIRLIGHT) && defined(VOXELSUNGATE)
            // The sun does not reach underground, and nothing else in the
            // scene knows that: a shadow map cannot tell a cave from a leaf
            // canopy, because in both cases the sky is blocked by geometry
            // that is being drawn. So the world's own light value is the
            // gate, and it is built for exactly this -- see PBR_LIGHT_MAP in
            // world.lua, which holds at full through a canopy and falls to
            // nothing in rock. Under a tree the sun is at full here and the
            // shadow map does the darkening; in a cave there is no sun to
            // shadow.
            lightColor *= vSkyVisibility;
        #endif

        vec3 toCamera = normalize(cCameraPosPS - vWorldPos.xyz);
        vec3 lightVec = normalize(lightDir);
        float ndl = clamp((dot(normal, lightVec)), M_EPSILON, 1.0);

        vec3 BRDF = GetBRDF(vWorldPos.xyz, lightDir, lightVec, toCamera, normal, roughness, diffColor.rgb, specColor);

        // Lambert, once. Urho3D's PBR.glsl hands back a diffuse of
        // albedo / pi times a power of the view angle, and this pass
        // divided by pi again over an atten that is already n.l -- so a
        // light of E lit a face to albedo * E * n.l / pi^2 times a factor
        // that fell to 0.4 seen at a grazing angle. Against the path
        // trace ([PBR_FIT]) the sun came out at a fifth of what it was
        // set to. What a face lit by an irradiance E reflects is albedo
        // * E * n.l / pi and nothing else: the view-dependent diffuse is
        // swapped for that and the extra pi goes -- from the diffuse
        // alone. The specular keeps Urho3D's normalization, which
        // counts on the pass's pi: without it a rose's white highlight
        // came to the size of its red ([PBR_FIT], the saturation rows).
        float ndvDiffuse = abs(dot(normal, toCamera)) + 1e-5;
        vec3 specularPart = BRDF -
            Diffuse(diffColor.rgb, roughness, ndvDiffuse, ndl, 1.0);
        BRDF = specularPart / M_PI + diffColor.rgb * (1.0 / M_PI);
        finalColor.rgb = BRDF * lightColor * (atten * shadow);

        #if defined(VOXELTRANSLUCENCY) && defined(METALLIC)
            // Light through the surface from the far side. It needs the light
            // on the back (atten is zero there, which is why this cannot ride
            // on it) and the camera roughly opposite the light, which is the
            // one geometry where a thin surface glows.
            //
            // simplified: not multiplied by shadow. A surface lit from behind
            // is its own shadow caster, so the shadow map says it is shadowed
            // and the term would never appear. That also means a leaf in
            // somebody else's shadow glows; with voxel geometry, where only
            // the outside of a canopy is meshed at all, that is rare enough to
            // leave. Sampling the shadow map along the transmission direction
            // would be the fix.
            //
            // The light keeps only part of the surface's color on the way
            // through. A spot where light comes through a canopy is partly a
            // gap, which passes the sun unchanged, and partly thin leaf, which
            // tints it; what a surface transmits is not what it reflects. Using
            // the albedo raw applies the leaf's green a second time and the
            // spots come out as saturated as the texture.
            const float TRANSMISSION_TINT = 0.55;
            vec3 transmitted = mix(vec3(1.0), diffColor.rgb,
                TRANSMISSION_TINT);
            float backNdl = max(0.0, -dot(normal, lightVec));
            float forward = pow(max(0.0, dot(-lightVec, toCamera)),
                TRANSMISSION_FOCUS);
            // A material with no spots at all is translucent all over
            #ifdef VOXELSPOTS
                float through = surfaceSrc.a > 0.0 ? surfaceSpots : 1.0;
            #else
                float through = 1.0;
            #endif
            finalColor.rgb += surfaceSrc.b * through * transmitted *
                lightColor * (backNdl * forward) / M_PI;
        #endif

        #ifdef AMBIENT
            finalColor += cAmbientColor.rgb * diffColor.rgb;
            finalColor += cMatEmissiveColor;
            gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
        #else
            gl_FragColor = vec4(GetLitFog(finalColor, fogFactor), diffColor.a);
        #endif
    #elif defined(DEFERRED)
        // Fill deferred G-buffer
        const vec3 spareData = vec3(0,0,0); // Can be used to pass more data to deferred renderer
        gl_FragData[0] = vec4(specColor, spareData.r);
        gl_FragData[1] = vec4(diffColor.rgb, spareData.g);
        gl_FragData[2] = vec4(normal * roughness, spareData.b);
        gl_FragData[3] = vec4(EncodeDepth(vWorldPos.w), 0.0);
    #else
        // Ambient & per-vertex lighting
        vec3 finalColor = vVertexLight * diffColor.rgb;
        #ifdef AO
            // If using AO, the vertex light ambient is black, calculate occluded ambient here
            finalColor += texture2D(sEmissiveMap, vTexCoord2).rgb * cAmbientColor.rgb * diffColor.rgb;
        #endif

        #ifdef MATERIAL
            // Add light pre-pass accumulation result
            // Lights are accumulated at half intensity. Bring back to full intensity now
            vec4 lightInput = 2.0 * texture2DProj(sLightBuffer, vScreenPos);
            vec3 lightSpecColor = lightInput.a * lightInput.rgb / max(GetIntensity(lightInput.rgb), 0.001);

            finalColor += lightInput.rgb * diffColor.rgb + lightSpecColor * specColor;
        #endif

        vec3 toCamera = normalize(vWorldPos.xyz - cCameraPosPS);
        vec3 reflection = normalize(reflect(toCamera, normal));

        #ifdef VOXELIBL
            // Specular half of image based lighting only; see the note at the
            // top of this file. Rougher surfaces read a blurrier mip, which is
            // what makes water a mirror and rock not.
            vec3 reflectDir = GetSpecularDominantDir(normal, reflection,
                roughness);
            float ndv = clamp(dot(-toCamera, normal), 0.0, 1.0);
            float mip = GetMipFromRoughness(roughness);
            vec3 lookup = FixCubeLookup(reflectDir);
            // simplified: a direction the camera cannot see the sky along
            // reflects nothing rather than the dark rock that is actually
            // there. Bounced light is in the vertex color if a floor for it is
            // ever wanted.
            #ifdef VOXELSKYTINT
                vec3 cube = textureLod(sZoneCubeMap, lookup, mip).rgb *
                    GetSkyVisibility(reflectDir);
                if(cSkyTintAmount > 0.0){
                    float sky_luma = dot(cube, vec3(0.299, 0.587, 0.114));
                    cube = mix(cube, cSkyTint * sky_luma, cSkyTintAmount);
                }
            #else
                vec3 cube = textureLod(sZoneCubeMap, lookup, mip).rgb *
                    GetSkyVisibility(reflectDir) * cSkyColor;
            #endif
            // Scaled by how much sky the surface itself sees as well as by
            // how much is visible along the reflection: the cube map answers
            // for the direction, the vertex color for the place.
            finalColor.rgb += cube * EnvBRDFApprox(specColor, roughness, ndv) *
                vSkyVisibility * cSpecEmphasis
            #ifdef VOXELSKYTINT
                * cSkyLight
            #endif
                ;
        #endif

        #ifdef ENVCUBEMAP
            finalColor += cMatEnvMapColor * textureCube(sEnvCubeMap, reflect(vReflectionVec, normal)).rgb;
        #endif
        #ifdef LIGHTMAP
            finalColor += texture2D(sEmissiveMap, vTexCoord2).rgb * diffColor.rgb;
        #endif
        #ifdef EMISSIVEMAP
            finalColor += cMatEmissiveColor * texture2D(sEmissiveMap, vTexCoord.xy).rgb;
        #else
            finalColor += cMatEmissiveColor;
        #endif

        gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
    #endif
}
