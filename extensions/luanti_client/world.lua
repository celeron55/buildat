-- Buildat: extension/luanti_client/world.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's mapblocks on screen: a scene with a camera in it, and a node per
-- block with buildat's voxel mesher on it.
--
-- A mapblock is 16^3 nodes. The mesher culls the faces of a chunk against the
-- voxels around it, so it wants a one-voxel border: a block becomes an 18^3
-- volume holding the block itself plus a slice off each of the six neighbours.
-- buildat.pack_voxel_volume() does all seven copies in one call. A neighbour
-- arriving makes this block's mesh out of date, which is what the dirty set is
-- for; a block with a neighbour still missing shows a seam until it comes.
--
-- Where the world sits: a buildat voxel and a Luanti node both occupy the cube
-- centred on their integer coordinate, so Luanti node coordinates are Urho3D
-- world coordinates one for one. block_node_position() is the same arithmetic
-- builtin/voxelworld does for its chunks.

local sounds_proto = dofile(__buildat_extension_path("luanti_client")..
		"/sounds.lua")
local shapes = dofile(__buildat_extension_path("luanti_client")..
		"/shapes.lua")
local particles = dofile(__buildat_extension_path("luanti_client")..
		"/particles.lua")
local light_flood = dofile(__buildat_extension_path("luanti_client")..
		"/light.lua")
local skyvis = dofile(__buildat_extension_path("luanti_client")..
		"/skyvis.lua")
local surface = dofile(__buildat_extension_path("luanti_client")..
		"/surface.lua")

local M = {}

local BLOCKSIZE = 16
-- The volume handed to the mesher, block plus border
local VOLUME_MIN = -1
local VOLUME_MAX = BLOCKSIZE

-- buildat voxel ids, in the order they go into the registry
local VOXEL_AIR = 1
local VOXEL_PLACEHOLDER = 2

-- Luanti's fixed content ids; see mapnode.h
local CONTENT_AIR = 126
local CONTENT_IGNORE = 127

-- Luanti draw types drawn as a full cube from the node's own six tiles.
--
-- A draw type that has a shape of its own -- a node box, a mesh, a flowing
-- liquid -- is here too: what it gets from this table is only what its cube
-- is when it has no shape to be drawn as, which is what a mesh in a format
-- this cannot read and a liquid at its top level come to.
--
-- The value is the buildat edge material the cube gets, which is what decides
-- when a face between two of them is drawn: two "ground" cubes hide the face
-- between them, two glass cubes hide the face between each other but not the
-- one against ground.
--
-- Leaves (NDT_ALLFACES) are "allfaces": a cube whose every face is drawn,
-- including the ones between two of them, because the texture is full of
-- holes and what is behind a hole is the next leaf's face. The shader
-- discards the holes.
--
-- A liquid is "liquid": it hides the face between two of itself, draws the
-- face against everything else -- including the stone it sits in, which is
-- visible through it -- and its faces are blended rather than cut out.
local EDGEMATERIAL_GLASS = 10
local EDGEMATERIAL_LIQUID = 11
local CUBE_DRAWTYPES = {
	[0] = "ground",  -- NDT_NORMAL
	[2] = "liquid",  -- NDT_LIQUID
	[3] = "liquid",  -- NDT_FLOWINGLIQUID
	[4] = "glass",   -- NDT_GLASSLIKE
	[5] = "allfaces",-- NDT_ALLFACES, leaves
	[6] = "allfaces",-- NDT_ALLFACES_OPTIONAL
	[13] = "glass",  -- NDT_GLASSLIKE_FRAMED
	[15] = "glass",  -- NDT_GLASSLIKE_FRAMED_OPTIONAL
	[16] = "ground", -- NDT_MESH, drawn as its selection box; see shapes.lua
}
local DRAWTYPE_AIRLIKE = 1
local DRAWTYPE_FLOWINGLIQUID = 3
local DRAWTYPE_RAILLIKE = 11
-- nodedef.lua's M.LIQUID_NONE, which is what a node that is not a liquid has
local NODEDEF_LIQUID_NONE = 0
-- nodedef.lua's M.ALPHAMODE_BLEND: the game asked for this node's texture
-- alpha to be blended rather than used as a mask
local NODEDEF_ALPHAMODE_BLEND = 0

-- How long a frame may spend handing blocks to the mesher, and how many it
-- may hand over however fast they go. Meshing itself is on a worker thread,
-- but packing the volume and handing it over is not, so a burst of a hundred
-- blocks arriving at once would otherwise be one long frame. One block is
-- always meshed, so a block that costs more than the whole budget still gets
-- drawn.
local MESH_BUDGET_US = 4000
local MESH_PER_FRAME = 8

-- What the mesher is told each node id is. Only air is known without the node
-- definitions, so everything else is the placeholder cube; CONTENT_IGNORE is
-- "no data here", which draws as nothing.
local PLACEHOLDER_MAP = {
	[CONTENT_AIR] = VOXEL_AIR,
	[CONTENT_IGNORE] = VOXEL_AIR,
}

-- Luanti keeps two light values in param1: the low nibble is the light a node
-- has when the sun is up, the high one the light it gets from light sources
-- alone. What the sun itself contributes is the difference, which is what
-- buildat calls skylight; the high nibble is buildat's lamplight.
--
-- Both of buildat's nibbles are written by one source with field = "light",
-- so a block's light costs one pass over its param1 rather than two. The map
-- is a byte per param1 value, which is what pack_voxel_volume takes.
local LIGHT_MAP = (function()
	local out = {}
	for p = 0, 255 do
		local day = p % 16
		local night = math.floor(p / 16)
		local sky = day > night and day - night or 0
		out[p + 1] = string.char(night * 16 + sky)
	end
	return table.concat(out)
end)()

-- The same, for the PBR path, whose skylight means something else.
--
-- There the sun is a real light with a shadow map, and the shadow map is what
-- darkens what is under a tree. So node lighting is left to answer the one
-- question a shadow map cannot -- "am I underground" -- and nothing else: the
-- curve holds at full until the light has fallen far enough that it can only
-- be rock overhead, and then drops away. A canopy reads 11..14 and stays fully
-- lit; a cave reads 0..2 and goes dark; a doorway is the band between.
--
-- The knee is the tuning knob. Lower it and cave mouths brighten; raise it and
-- overhangs start being darkened twice, once here and once by the shadow map.
local PBR_SKY_KNEE_LOW = 2
local PBR_SKY_KNEE_HIGH = 11

local PBR_LIGHT_MAP = (function()
	local out = {}
	for p = 0, 255 do
		local day = p % 16
		local night = math.floor(p / 16)
		local sky = day > night and day - night or 0
		local t = (sky - PBR_SKY_KNEE_LOW) /
				(PBR_SKY_KNEE_HIGH - PBR_SKY_KNEE_LOW)
		t = t < 0 and 0 or (t > 1 and 1 or t)
		local smooth = t * t * (3 - 2 * t)
		out[p + 1] = string.char(night * 16 + math.floor(15 * smooth + 0.5))
	end
	return table.concat(out)
end)()

-- What the curve has to hold, checked at load: full sun outdoors, nothing in
-- rock, and a canopy left for the shadow map to darken. The lamp nibble rides
-- through untouched, because the two are separate lights.
do
	local function sky_of(day, night)
		return string.byte(PBR_LIGHT_MAP, night * 16 + day + 1) % 16
	end
	local function lamp_of(day, night)
		return math.floor(string.byte(PBR_LIGHT_MAP, night * 16 + day + 1) / 16)
	end
	assert(sky_of(15, 0) == 15, "pbr light curve: open sky")
	assert(sky_of(PBR_SKY_KNEE_HIGH, 0) == 15, "pbr light curve: canopy")
	assert(sky_of(PBR_SKY_KNEE_LOW, 0) == 0, "pbr light curve: rock")
	assert(sky_of(0, 0) == 0, "pbr light curve: dark")
	assert(sky_of(8, 8) == 0, "pbr light curve: lamp is not sky")
	assert(lamp_of(15, 7) == 7, "pbr light curve: lamp nibble kept")
end

-- What the volume is before the block and its neighbours are copied into it:
-- air that sees the full sky. A face against a neighbour that has not arrived
-- is then lit as if it were out in the open, which is wrong in a cave but
-- only until the neighbour comes, and a wrongly lit face reads better than
-- the black one that unlit air would give. This is a raw voxel word under
-- the format base_registry() sets, where the skylight is bits 16..19.
local VOXEL_AIR_LIT = VOXEL_AIR + 15 * 0x10000

-- How a (voxel id, param2) pair is keyed: id + param2 * this, which is what
-- pack_voxel_volume's paired lookup wants. Luanti's ids are 16 bits.
local PAIR_SCALE = 65536

-- Luanti's ContentParamType2, the values that change what a voxel looks like
local CPT2_FACEDIR = 3
local CPT2_WALLMOUNTED = 4
local CPT2_COLOR = 8
local CPT2_COLORED_FACEDIR = 9
local CPT2_COLORED_WALLMOUNTED = 10
local CPT2_COLORED_DEGROTATE = 12
local CPT2_4DIR = 13
local CPT2_COLORED_4DIR = 14

-- How param2 says which way a voxel faces, per paramtype2: which mask of it
-- to read, and what the value means
local FACING = {
	[CPT2_FACEDIR] = "facedir",
	[CPT2_COLORED_FACEDIR] = "facedir",
	[CPT2_4DIR] = "4dir",
	[CPT2_COLORED_4DIR] = "4dir",
	[CPT2_WALLMOUNTED] = "wallmounted",
	[CPT2_COLORED_WALLMOUNTED] = "wallmounted",
}

-- Which bits of param2 are the palette index, per paramtype2. Luanti indexes
-- the 256-entry palette with the whole of param2 for CPT2_COLOR and with the
-- high bits for the types that keep a direction in the low ones; what is
-- written here is how much of param2 one colour covers, which is what the low
-- bits are worth: param2 - param2 % step is the index.
local COLOR_STEP = {
	[CPT2_COLOR] = 1,
	[CPT2_COLORED_FACEDIR] = 32,
	[CPT2_COLORED_WALLMOUNTED] = 8,
	[CPT2_COLORED_DEGROTATE] = 32,
	[CPT2_COLORED_4DIR] = 4,
}

-- Lights in the scene, for the voxels a game says give light. Luanti floods
-- light through the voxels and bakes it into param1; this puts a real light
-- where the torch is instead, which is a buildat-ism and looks like one --
-- the light falls off around corners the way a light does.
--
-- There is a cap because a forward renderer draws the geometry again per
-- light: the nearest few to the camera are lit and the rest of the world
-- keeps the light its param1 gives it.
local MAX_SCENE_LIGHTS = 24
-- Per block, so that a room full of lamps cannot fill the list on its own
local MAX_LIGHTS_PER_BLOCK = 12
-- How far a light of level n reaches, in voxels. Luanti's own light falls off
-- one level per voxel, so the level is the range; a little more looks better
-- than a little less.
local LIGHT_RANGE_PER_LEVEL = 1.0
-- What a light source is coloured. A game does not say -- Luanti's
-- light_source is one number -- and what gives light in one is mostly fire.
local LIGHT_COLOR = {r = 1.0, g = 0.85, b = 0.65}

-- A voxel's collision boxes, turned the way its facedir says
local function turn_boxes(boxes, facedir)
	local out = {}
	for i, box in ipairs(boxes) do
		out[i] = shapes.turn_box(box, facedir)
	end
	return out
end

-- What a definition's param2 does to how its voxels are drawn, as the
-- variants buildat's mesher indexes by the param: a shape turned one way,
-- a cube's tiles moved to the faces they end up on, a liquid's surface at
-- one of eight levels. One variant per distinct look, claiming the param2
-- values that come to it -- so a facedir is twenty-four of them rather
-- than two hundred and fifty-six, and none of them is a voxel type.
--
-- A param2 that comes to nothing different is left unclaimed and draws as
-- the definition itself does, which is facing 0 with a full liquid.
--
-- The palette is not here: a palette entry tints the *texture*, and a
-- variant's colour tints the light, so a colour still gets a voxel of its
-- own with its own composed textures. See build_pair().
local function build_variants(def, facing, liquid_range, mesh_quads)
	if not facing and not liquid_range then
		return nil
	end
	local list = {}
	local by_key = {}
	for p2 = 0, 255 do
		local facedir = shapes.facedir_of(facing, p2)
		-- A wallmounted shape wants the direction itself, not only the
		-- facedir it comes to: which of its three boxes it is made of
		-- depends on it
		local wall = facing == "wallmounted" and p2 % 8 or nil
		-- A liquid at the top level is a whole cube, which the voxel
		-- itself already is
		local ltop = liquid_range and
				shapes.liquid_top(liquid_range, p2) or nil
		if ltop and ltop >= 0.5 then
			ltop = nil
		end
		if (facedir and facedir ~= 0) or ltop then
			local key = tostring(facedir).."/"..tostring(wall).."/"..
					tostring(ltop)
			local var = by_key[key]
			if not var then
				var = {params = {}}
				local shape = shapes.for_node(def, facedir, wall,
						mesh_quads, ltop)
				if shape then
					var.shape = shape
				elseif facedir and facedir ~= 0 then
					-- A cube wears the same six textures in the order
					-- the turn puts them in, each turned inside its own
					-- face. The faces are 0...5 here and 1...6 there.
					local tiles = shapes.FACEDIR_TILES[facedir + 1]
					if tiles then
						local order = {}
						for i = 1, 6 do
							order[i] = (tiles[i] or i) - 1
						end
						var.tile_order = order
						var.tile_turns =
								shapes.FACEDIR_TILE_TURNS[facedir + 1]
					end
				end
				if ltop then
					var.liquid_top = ltop
				end
				by_key[key] = var
				list[#list + 1] = var
			end
			var.params[#var.params + 1] = p2
		end
	end
	if #list == 0 then
		return nil
	end
	return list
end

local function block_key(x, y, z)
	return x..","..y..","..z
end

-- The six directions a border slice comes from, and which slice of the
-- neighbour it is: for -x, the neighbour's x = 15 plane lands at x = -1.
local NEIGHBOURS = {
	{-1, 0, 0}, {1, 0, 0},
	{0, -1, 0}, {0, 1, 0},
	{0, 0, -1}, {0, 0, 1},
}

-- new(magic, buildat, log, options)
--
-- magic is the sandboxed Urho3D interface and buildat the sandboxed buildat
-- interface (buildat.safe), because set_voxel_geometry() wants sandboxed nodes
-- and this is called from an extension, where buildat is the unsafe table.
--
-- options.far_clip, options.texture: what the camera sees and what an unknown
-- node looks like.
function M.new(magic, buildat, log, options)
	options = options or {}
	local far_clip = options.far_clip or 240
	local texture = options.texture or "luanti_client/res/placeholder.png"
	-- options.read_mesh(def) -> the quads of the model a "mesh" drawtype
	-- names, or nil for one that could not be read. Whoever has the media
	-- has the file; this only wants the quads.
	local read_mesh = options.read_mesh
	-- options.read_image(resource) -> w, h, rgba, for the colour a light
	-- source shines in. Handed in rather than taken from buildat because it
	-- is not part of the sandbox's own interface.
	local read_image = options.read_image
	-- options.media_texture(name) -> the resource name of one of the game's
	-- own textures, or nil for one that has not arrived. The sky's sun and
	-- moon are the ones here that want it, and their names can be texture
	-- expressions like any other.
	local media_texture = options.media_texture
	-- Whether the world is drawn with res/PBRVoxel -- normal and surface
	-- maps, reflections of the sky, the sun as a real light -- instead of
	-- the Luanti-native VoxelUnlit. Chosen in the connect dialog and fixed
	-- for the session: the atlas's surface maps have to be on from the first
	-- texture it builds, and they are two thirds of what adding one costs.
	local pbr = options.pbr and true or false

	local self = {}
	self.pbr = pbr

	-- One of the game's own textures, drawn without smoothing. A Luanti
	-- game's textures are pixel art and interpolating them is wrong at every
	-- size: the voxel atlas already says so in the engine (see
	-- SetFilterMode in src/impl/atlas.cpp) and everything else a game's
	-- texture goes on -- an object, a dropped item, the sun -- wants the
	-- same. The mode is on the texture rather than on the material, so
	-- setting it once per use is setting it for good; it is cheap and there
	-- is nowhere better.
	-- filter is FILTER_NEAREST unless the caller says otherwise: a game's
	-- textures are pixel art and interpolating them is wrong at every size.
	-- The exception is a particle, which is drawn smaller than its own
	-- texture and whose whole shape can be one pixel wide -- a rain drop is
	-- -- so point sampling drops it altogether at a distance. Luanti's own
	-- particle material says nearest magnification and *mipmapped*
	-- minification, which is FILTER_NEAREST_ANISOTROPIC here: crisp up
	-- close, and a thin thing that is far away goes dim rather than
	-- disappearing.
	--
	-- The filter belongs to the texture rather than to the material, so a
	-- file used both ways gets whichever was asked for last. Nothing in the
	-- games looked at does that.
	local function game_texture(name, filter)
		local tex = magic.cache:GetResource("Texture2D", name)
		if tex then
			tex.filterMode = filter or magic.FILTER_NEAREST
		end
		return tex
	end

	-- The colour of full sunlight for a day/night factor of 0...1, which is
	-- Luanti's own get_sunlight_color(): a little blue is left at night and a
	-- little is added in the day, so a shadowed face reads cool rather than
	-- grey.
	local function sunlight_color(factor)
		local rg = factor - 0.04
		if rg < 0 then
			rg = 0
		end
		return magic.Color(rg, rg, 0.98 * factor + 0.078)
	end

	local scene = magic.Scene()
	scene:CreateComponent("Octree")
	self.scene = scene

	-- How wide the sun and the moon are drawn, on a plane one unit along
	-- their direction, at the scale of one: the ratio Luanti draws them at.
	-- A game's own scale multiplies these.
	local SUN_HALF = 0.075
	local MOON_HALF = 0.048
	-- How many stars a game asks for by default, and how many of the star
	-- grid's cells hold one at that count: the density was picked to look
	-- right at Luanti's own default, so a game asking for more gets more in
	-- proportion.
	local STARS_DEFAULT = 1000
	local STAR_DENSITY_DEFAULT = 0.004
	-- The same for the clouds: how much of the sky is covered at the density
	-- a game has unless it says otherwise
	-- Luanti's own default cloud speed, in nodes a second, and what one node
	-- a second is worth in the sky shader's own units.
	--
	-- simplified, and knowingly: these clouds are not a layer at a height --
	-- the shader divides the view direction by its own y to fake a flat
	-- plane -- so a speed in nodes a second has nothing exact to become. The
	-- factor is picked so that the default below drifts at the rate the
	-- shader had baked in before a game could ask for anything, which makes
	-- a game asking for twice that twice as fast. See doc/luanti_client.txt.
	local CLOUD_SPEED_DEFAULT = {0, -2}
	local CLOUD_WIND_PER_NODE = 0.0054
	local CLOUD_DENSITY_DEFAULT = 0.4
	-- Luanti's own default cloud colour is 229 of 255 opaque, and a game that
	-- names a colour without an alpha gets a full one; either way the layer
	-- is drawn at what the colour says rather than solid
	local CLOUD_ALPHA_DEFAULT = 229 / 255

	-- What the game says is in the sky, out of SET_SUN, SET_MOON, SET_STARS
	-- and CLOUD_PARAMS. What is here to begin with is what Luanti has before
	-- a game says anything.
	--
	-- The sun and the moon wear the textures the game gives them, on the
	-- shader's two texture units.
	--
	-- simplified: the sunrise texture, the tonemaps and the stars' own colour
	-- ramp are not drawn -- a tonemap is a colour grade of the body and the
	-- sunrise is a band of its own along the horizon, which the shader paints
	-- from the sky colours instead. What is honoured is the textures, whether
	-- each body is there at all, how big, how many, and what colour the
	-- stars and the clouds are, which is what turns a dimension with no sky
	-- into one.
	local sky_bodies = {
		sun = {visible = true, scale = 1},
		moon = {visible = true, scale = 1},
		stars = {visible = true, count = STARS_DEFAULT, scale = 1},
		clouds = {density = CLOUD_DENSITY_DEFAULT,
				speed = CLOUD_SPEED_DEFAULT},
	}

	-- What the sky looks like until the server says, and what it says; see
	-- set_sky() below
	local FOG = {r = 0.60, g = 0.72, b = 0.88}
	local sky = nil
	local daylight = 1.0
	-- Where the sun was put last, so that a SET_SKY in the middle of the
	-- night does not draw it back at noon
	local daylight_time = nil

	-- The sky itself: a skybox drawn by res/LuantiSky.glsl,
	-- which is handed the colours and the sun's direction from here.
	local sky_node = scene:CreateChild("Sky")
	local sky_material = nil
	do
		local skybox = sky_node:CreateComponent("Skybox")
		skybox:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
		sky_material = magic.Material.new()
		sky_material:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/LuantiSky.xml"))
		skybox.material = sky_material
	end

	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-100000, 100000)
	zone.ambientColor = sunlight_color(1.0)
	zone.fogColor = magic.Color(FOG.r, FOG.g, FOG.b)
	zone.fogStart = far_clip * 0.7
	zone.fogEnd = far_clip
	zone.priority = -1000

	-- No light in the scene: the mesher bakes the light into the vertex
	-- colours and VoxelUnlit reads it from there, so there is nothing for a
	-- directional light to reach. The PBR path reads the same vertex colours
	-- as its ambient, so that is true of it as well -- what it adds on top is
	-- the sky it reflects.
	local technique = magic.cache:GetResource("Technique", pbr and
			"luanti_client/res/PBRVoxel.xml" or
			"luanti_client/res/VoxelUnlit.xml")
	local alpha_technique = magic.cache:GetResource("Technique", pbr and
			"luanti_client/res/PBRVoxelAlpha.xml" or
			"luanti_client/res/VoxelUnlitAlpha.xml")
	if pbr then
		-- What the reflections are of: one static noon gradient, multiplied
		-- in the shader by the colour the sky is now, so a sunset and being
		-- under water follow without anything being rebaked. See set_sky_tint
		-- below and the note on cSkyColor in res/PBRVoxel.glsl.
		zone.zoneTexture = magic.cache:GetResource("TextureCube",
				"luanti_client/res/VoxelSky.xml")
	end

	-- The sun, on the PBR path only. The vanilla path has no light in the
	-- scene at all: the mesher bakes what a node is lit by into the vertex
	-- colours, and a directional light on top of that would light everything
	-- twice. The PBR path keeps the vertex colours as its ambient and adds
	-- the sun, and what stops the double is the light curve: PBR_LIGHT_MAP
	-- reads as "am I underground" and nothing else, and the shader gates the
	-- sun by it. A leaf canopy is then darkened by the shadow map, which is
	-- the thing a shadow map is good at and a baked light value is not.
	--
	-- Biased for performance, because there are no graphics settings beyond
	-- the PBR checkbox: two cascades rather than four, a small map, and the
	-- single-tap filter.
	local SHADOW_NEAR = 24    -- nodes; the first cascade
	local SHADOW_FAR = 96     -- and the second, which is the shadow distance
	-- What a lit face gets from the sun, against the sky as the ambient. The
	-- number is large because Urho's PBR direct lighting is normalized -- the
	-- BRDF is divided by pi and so is the diffuse term inside it -- and
	-- because the frame is tone mapped, so a sun well past white is what
	-- white is for. games/voxel_lighting arrived at the same number for the
	-- same reasons.
	local SUN_BRIGHTNESS = 50.0
	-- How far past the tone curve's middle the frame is exposed
	local TONEMAP_EXPOSURE = 1.6
	-- What the sun's disc is drawn at, in the same units: well past white, so
	-- that the tone curve leaves it white and the bloom finds it
	local SUN_DISC_OVEREXPOSURE = 6.0

	-- What the moon is worth, in the same units. Not a measurement of
	-- anything -- real moonlight is a millionth of sunlight and would render
	-- as nothing -- but a night lit from where the moon is, coldly, and far
	-- enough above the sky's own light that the moon casts a shadow. A
	-- fiftieth of the sun.
	local MOON_BRIGHTNESS = 1.0
	local MOON_COLOR = {0.55, 0.68, 1.0}

	-- When the sun is in the scene and when the moon is, in Luanti's
	-- 0...24000. Below the horizon a directional light shines up through the
	-- world, and its specular -- the sparkle surface.lua asks for on water,
	-- on snow and on ore -- is then the brightest thing in a night frame and
	-- is coming from the wrong side of the sky. So the sun is taken out of
	-- the scene for the night and the moon is put in, each fading over the
	-- hour on either side of when the sun is level with the horizon.
	local SUN_RISE = 5000     -- nothing before this
	local SUN_UP = 6000       -- full sun from here
	local SUN_SET = 18000     -- full sun until here
	local SUN_DOWN = 19000    -- nothing after this

	-- The moon's day is a little longer than the sun's night: it is going
	-- before the sun arrives and does not come back until the sun is well
	-- gone. That leaves it nine hours at full against the sun's twelve, which
	-- is one more way of saying which of the two is the dim one, and it means
	-- that by the time the sun is making any real light the moon has stopped.
	local MOON_FADE_OUT = 4500   -- the moon starts going here
	local MOON_OUT = 5500        -- and is gone here, the sun then half up
	local MOON_FADE_IN = 18500   -- and comes back from here
	local MOON_IN = 19500        -- to full here

	-- Nothing above the horizon shines from under it. The clocks above are
	-- where the fade is shaped; this is the line itself, taken from where the
	-- body actually is, so that neither can light the undersides of the world
	-- whatever the clock says. A couple of degrees of softness, because a
	-- light that switches off in one frame is a light that pops.
	local HORIZON_FADE = 0.05    -- sine of the angle, so about three degrees

	local function clamp01(v)
		return v < 0 and 0 or (v > 1 and 1 or v)
	end

	-- 0 below low, 1 above high, and a smooth ride between them
	local function smoothstep01(v, low, high)
		local t = clamp01((v - low) / (high - low))
		return t * t * (3 - 2 * t)
	end

	local function luminance(rgb)
		return 0.2126 * rgb[1] + 0.7152 * rgb[2] + 0.0722 * rgb[3]
	end

	local function above_horizon(sine_of_elevation)
		return clamp01(sine_of_elevation / HORIZON_FADE)
	end

	-- 0 before the rise, 1 between the rise and the set, 0 after it, and the
	-- way across each ramp in between
	local function up_between(time_of_day, rise_from, rise_to,
			set_from, set_to)
		local t = (time_of_day or 12000) % 24000
		if t <= rise_from or t >= set_to then
			return 0
		elseif t < rise_to then
			return (t - rise_from) / (rise_to - rise_from)
		elseif t <= set_from then
			return 1
		end
		return (set_to - t) / (set_to - set_from)
	end

	local function sun_amount(time_of_day)
		return up_between(time_of_day, SUN_RISE, SUN_UP, SUN_SET, SUN_DOWN)
	end

	-- Where the sun is for the purpose of casting a shadow, which is not
	-- quite where it is. A shadow map is rasterized afresh every frame, and a
	-- light that has turned a little between two of them rasterizes it
	-- differently, so the edges crawl -- which is what a sun that moves as
	-- smoothly as this one now does made visible. Holding the direction still
	-- for a step at a time trades the crawl for a small jump, which is far
	-- easier not to see. The step is in Luanti's own units of the day, so it
	-- is a fixed angle of sun however fast the game's clock runs: a hundred
	-- of them is a degree and a half, and about five seconds at Luanti's own
	-- default speed.
	local SUN_STEP = 100

	local function stepped_time(time_of_day)
		local t = time_of_day or 12000
		return math.floor(t / SUN_STEP + 0.5) * SUN_STEP
	end

	-- The half hour either side of the sun crossing the horizon, at each end
	-- of the day, as 0 outside and 1 at the crossing itself. This is the
	-- window dawn and dusk happen in: what the sun is red in, and what the
	-- clouds take their colour from. Smooth at both ends, because a tint that
	-- switches on is a tint you notice switching on.
	local RED_HALF_WIDTH = 500

	local function low_sun(time_of_day)
		local t = (time_of_day or 12000) % 24000
		local d = math.min(math.abs(t - SUN_RISE), math.abs(t - SUN_DOWN))
		local u = 1 - d / RED_HALF_WIDTH
		if u <= 0 then
			return 0
		end
		return u * u * (3 - 2 * u)
	end

	-- What is up while the day is not: the same shape, read the other way
	-- round, so that the four numbers above say when the moon is out rather
	-- than being the sun's turned inside out
	local function moon_amount(time_of_day)
		return 1 - up_between(time_of_day, MOON_FADE_OUT, MOON_OUT,
				MOON_FADE_IN, MOON_IN)
	end

	-- What the schedule has to hold, checked at load: the two never leave the
	-- sky empty between them, and the moon is out of the way by the time the
	-- sun is worth anything.
	do
		assert(above_horizon(-1) == 0 and above_horizon(0) == 0 and
				above_horizon(1) == 1, "the horizon line")
		assert(sun_amount(12000) == 1 and moon_amount(12000) == 0, "noon")
		assert(sun_amount(0) == 0 and moon_amount(0) == 1, "midnight")
		assert(moon_amount(SUN_RISE) > 0.4, "the moon is still up at sunrise")
		assert(moon_amount(MOON_OUT) == 0 and sun_amount(MOON_OUT) > 0.4,
				"the sun has the sky to itself once the moon is gone")
		assert(sun_amount(SUN_DOWN) == 0 and moon_amount(SUN_DOWN) > 0.4,
				"the moon is up by the time the sun is gone")
		-- Dawn and dusk are a window around the crossings and nowhere else
		assert(low_sun(SUN_RISE) == 1 and low_sun(SUN_DOWN) == 1,
				"reddest as the sun crosses")
		assert(low_sun(SUN_RISE - RED_HALF_WIDTH) == 0 and
				low_sun(SUN_RISE + RED_HALF_WIDTH) == 0 and
				low_sun(SUN_DOWN - RED_HALF_WIDTH) == 0 and
				low_sun(SUN_DOWN + RED_HALF_WIDTH) == 0,
				"and back to nothing half an hour either side")
		assert(low_sun(12000) == 0 and low_sun(0) == 0,
				"nothing of it at noon or at midnight")
		assert(low_sun(SUN_RISE - 250) > 0.4 and low_sun(SUN_RISE - 250) < 0.6,
				"and the way across it in between")
	end

	-- What the sky is worth as a light, against that. Two numbers, because
	-- the sky's own colour is the wrong one to light a world with: it is the
	-- colour of the zenith, and a surface sees the whole dome -- the pale
	-- band along the horizon and the glare around the sun as much as the blue
	-- overhead -- so what reaches it is far less blue than what is up there.
	local AMBIENT_DESATURATE = 0.55
	local AMBIENT_FROM_SKY = 0.6
	-- And a floor under it while the sun is down. The sky is the only ambient
	-- there is on this path, and a game's night sky can be black -- VoxeLibre
	-- paints one -- which leaves a moon shadow with nothing in it at all now
	-- that the moon casts one. This is what is in it: the moon's own cold
	-- colour, at little enough that what the moon lights is still brighter
	-- than what it does not.
	local AMBIENT_NIGHT_FLOOR = 0.015
	local AMBIENT_NIGHT_COLOR = {0.55, 0.68, 1.0}

	-- night is 1 while the sun is down and 0 while it is up, across its own
	-- hour at each end
	local function ambient_from_sky(sky, night)
		local luma = 0.2126 * sky.r + 0.7152 * sky.g + 0.0722 * sky.b
		local k = AMBIENT_DESATURATE
		local floor = AMBIENT_NIGHT_FLOOR * (night or 0)
		local function channel(v, i)
			return math.max((v * (1 - k) + luma * k) * AMBIENT_FROM_SKY,
					AMBIENT_NIGHT_COLOR[i] * floor)
		end
		return magic.Color(channel(sky.r, 1), channel(sky.g, 2),
				channel(sky.b, 3))
	end
	local sun_node = nil
	local sun_light = nil
	local moon_node = nil
	local moon_light = nil
	if pbr then
		sun_node = scene:CreateChild("Sun")
		sun_light = sun_node:CreateComponent("Light")
		sun_light.lightType = magic.LIGHT_DIRECTIONAL
		sun_light.castShadows = true
		sun_light.brightness = SUN_BRIGHTNESS
		sun_light.specularIntensity = 1.0
		-- Voxel faces at a grazing sun angle are the classic shadow acne
		-- case: a whole flat face falls inside one shadow texel and shadows
		-- itself in stripes. A slope-scaled bias on top of the automatic one,
		-- and a normal offset, which is the one that works on a face that is
		-- flat and wide.
		sun_light.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
		sun_light.shadowCascade = magic.CascadeParameters(
				SHADOW_NEAR, SHADOW_FAR, 0, 0, 0.8)
		-- The moon, which is the same light from the other side of the sky,
		-- with the same shadow map settings. The two are both in the scene
		-- for the hour either side of dusk and dawn, which is two shadow maps
		-- for that hour and one for the rest of the day.
		moon_node = scene:CreateChild("Moon")
		moon_light = moon_node:CreateComponent("Light")
		moon_light.lightType = magic.LIGHT_DIRECTIONAL
		moon_light.castShadows = true
		moon_light.brightness = MOON_BRIGHTNESS
		moon_light.specularIntensity = 1.0
		moon_light.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
		moon_light.shadowCascade = magic.CascadeParameters(
				SHADOW_NEAR, SHADOW_FAR, 0, 0, 0.8)
		moon_light.color = magic.Color(MOON_COLOR[1], MOON_COLOR[2],
				MOON_COLOR[3])

		-- Past the far cascade the world is ambient-lit, which at that range
		-- reads as haze rather than as a missing shadow
		magic.renderer.shadowMapSize = 1024
		magic.renderer.shadowQuality = magic.SHADOWQUALITY_SIMPLE_16BIT
		magic.renderer.drawShadows = true
	end

	-- The mesher sets no technique on skylit geometry -- only the game knows
	-- which shader reads what it packed -- so every block's materials get
	-- this one once they exist.
	local function apply_to(cg, tech)
		if not cg then
			return
		end
		-- Urho3D's drawables cast no shadow unless told to, one by one. On
		-- the vanilla path there is no light to cast one from; on the PBR
		-- path this is what puts the world in the sun's shadow map.
		cg.castShadows = pbr
		local i = 0
		while true do
			local m = cg:GetMaterial(i)
			if m == nil then
				break
			end
			m:SetTechnique(0, tech)
			i = i + 1
		end
	end

	local function apply_technique(node)
		apply_to(node:GetComponent("CustomGeometry"), technique)
		-- The mesher puts the translucent voxels' faces on a child node of
		-- the chunk when there are any; those get the blended technique.
		local alpha_node = node:GetChild("alpha")
		if alpha_node then
			apply_to(alpha_node:GetComponent("CustomGeometry"),
					alpha_technique)
		end
	end

	local camera_node = scene:CreateChild("Camera")
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.1
	camera.farClip = far_clip
	-- What the field of view is when the server has not asked for anything
	-- else. TOCLIENT_FOV can ask for degrees or for a multiplier of this,
	-- over a transition time, which is what a game zooms with.
	local BASE_FOV = 72
	camera.fov = BASE_FOV
	self.camera_node = camera_node
	self.camera = camera

	local fov_target = BASE_FOV
	-- Degrees a second while a transition is running, and nil when there is
	-- none
	local fov_step = nil

	-- set_fov(fov, is_multiplier, transition_time), out of TOCLIENT_FOV. A
	-- fov of zero means back to the client's own.
	function self:set_fov(fov, is_multiplier, transition_time)
		local want = BASE_FOV
		if fov and fov > 0 then
			want = is_multiplier and BASE_FOV * fov or fov
		end
		-- A game that asks for something absurd gets the nearest sane thing
		want = math.min(math.max(want, 5), 160)
		fov_target = want
		if transition_time and transition_time > 0 then
			fov_step = math.abs(want - camera.fov) / transition_time
		else
			fov_step = nil
			camera.fov = want
		end
	end

	function self:update_fov(dtime)
		if not fov_step then
			return
		end
		local at = camera.fov
		if at < fov_target then
			at = math.min(fov_target, at + fov_step * dtime)
		else
			at = math.max(fov_target, at - fov_step * dtime)
		end
		camera.fov = at
		if at == fov_target then
			fov_step = nil
		end
	end

	-- Held on self: the renderer keeps a raw reference to the viewport, so a
	-- viewport that only a local pointed at gets freed under it the next time
	-- Lua collects garbage
	local viewport = magic.Viewport:new(scene, camera)
	self.viewport = viewport
	magic.set_preferred_viewports({viewport})

	-- On the PBR path the frame is rendered in HDR and tone mapped, the way
	-- games/voxel_lighting does it. Nothing else makes the sun read as the
	-- sun: in a frame that clips at one, a sun strong enough to put a real
	-- shadow on the ground flattens every lit surface to white, and one weak
	-- enough not to do that is a sun whose colour and whose shadow are both
	-- invisible under the sky's. With the curve in, the sun can be fifty
	-- times the sky, which is about what it is, and what a lit surface gets
	-- is the sun's own colour rather than a mixture with the sky's; the same
	-- curve lifts the shadows, so a shadow under full skylight reads as shade
	-- rather than as a hole.
	if pbr then
		magic.renderer.HDRRendering = true
		local rp = viewport.renderPath:Clone()
		rp:Append(magic.cache:GetResource("XMLFile",
				"PostProcess/BloomHDR.xml"))
		rp:Append(magic.cache:GetResource("XMLFile",
				"PostProcess/Tonemap.xml"))
		rp:Append(magic.cache:GetResource("XMLFile",
				"PostProcess/GammaCorrection.xml"))
		-- Tonemap.xml ships with Reinhard on; Uncharted2 keeps more contrast
		-- in the shadows, which on a world lit by one sun is most of it
		rp:SetEnabled("TonemapReinhardEq3", false)
		rp:SetEnabled("TonemapUncharted2", true)
		rp:SetShaderParameter("TonemapExposureBias", TONEMAP_EXPOSURE)
		viewport.renderPath = rp
	end

	-- The sounds the server asked for. A sound at a position is a node in
	-- the scene and the listener rides the camera, which is what makes it
	-- come from the right side, so this is here rather than in the
	-- extension. Keyed by the server's own id, which is what STOP_SOUND and
	-- FADE_SOUND name.
	camera_node:CreateComponent("SoundListener")
	magic.audio.listener = camera_node:GetComponent("SoundListener")

	-- How far a positioned sound carries. Luanti leaves this to OpenAL's
	-- defaults, which are in its own units; these are nodes.
	local SOUND_NEAR = 2.0
	local SOUND_FAR = 48.0

	local sounds = {}

	-- A scene node per object, kept by id. Declared here rather than with
	-- the rest of the object code below because a sound attached to an
	-- object follows it, and the sounds are above that.
	local object_nodes = {}

	-- play_sound(id, spec, resource)
	--
	-- spec is what sounds.lua read out of PLAY_SOUND and resource the name
	-- of one file of the group it asked for -- picking which one is the
	-- caller's, because which files there are is the media's business.
	--
	-- A sound attached to an object starts where the object is and follows
	-- it, which is what a mob's own noises want.
	--
	-- simplified: start_time is ignored, because seeking is not in the
	-- sandbox's SoundSource. A game uses it for background music a player
	-- rejoins in the middle of.
	function self:play_sound(id, spec, resource)
		local sound = magic.cache:GetResource("Sound", resource)
		if not sound then
			return false
		end
		sound.looped = spec.loop and true or false
		local node = scene:CreateChild("sound_"..tostring(id))
		local source
		-- A sound attached to an object starts where the object is and
		-- follows it; one at a position stays there; one that is neither is
		-- in the player's own head and has no position at all.
		local follows = spec.location == sounds_proto.OBJECT and
				spec.object_id ~= 0 and spec.object_id or nil
		if spec.location == sounds_proto.LOCAL then
			source = node:CreateComponent("SoundSource")
		else
			local at = follows and object_nodes[follows]
			if at and at.at_x then
				node.position = magic.Vector3(at.at_x,
						at.at_y + (at.offset or 0), at.at_z)
			else
				node.position = magic.Vector3(spec.pos[1], spec.pos[2],
						spec.pos[3])
			end
			source = node:CreateComponent("SoundSource3D")
			source.nearDistance = SOUND_NEAR
			source.farDistance = SOUND_FAR
		end
		source.soundType = magic.SOUND_EFFECT
		local gain = spec.gain or 1.0
		-- A fade on the packet means it starts silent and comes up to the
		-- gain it asked for
		local entry = {node = node, source = source, gain = gain,
				started = false, object_id = follows}
		if spec.fade and spec.fade > 0 then
			entry.target = gain
			entry.step = spec.fade
			gain = 0
		end
		source.gain = gain
		if spec.pitch and spec.pitch > 0 and spec.pitch ~= 1 then
			source.frequency = sound.frequency * spec.pitch
		end
		source:Play(sound)
		-- A sound the server gave no id keeps none: it said it will not talk
		-- about it again, and the update below takes the node away when it
		-- has finished
		self:stop_sound(id)
		sounds[id] = entry
		return true
	end

	function self:stop_sound(id)
		local entry = sounds[id]
		if not entry then
			return
		end
		sounds[id] = nil
		entry.source:Stop()
		entry.node:Remove()
	end

	-- FADE_SOUND: gain moves by step a second until it is at gain, and a
	-- sound faded to nothing stops
	function self:fade_sound(id, step, gain)
		local entry = sounds[id]
		if not entry then
			return
		end
		entry.target = gain
		entry.step = step
	end

	-- The fades, and the nodes of the sounds that have finished
	function self:update_sounds(dtime)
		for id, entry in pairs(sounds) do
			-- A sound attached to an object goes where the object goes: a
			-- mob's own noises come from the mob rather than from where it
			-- was when it made them
			local follow = entry.object_id and object_nodes[entry.object_id]
			if follow and follow.at_x and
					(follow.at_x ~= entry.at_x or
					follow.at_y ~= entry.at_y or
					follow.at_z ~= entry.at_z) then
				entry.at_x, entry.at_y, entry.at_z =
						follow.at_x, follow.at_y, follow.at_z
				entry.node.position = magic.Vector3(follow.at_x,
						follow.at_y + (follow.offset or 0), follow.at_z)
			end
			if entry.target then
				local gain, done = sounds_proto.fade_step(entry.gain,
						entry.target, entry.step, dtime)
				entry.gain = gain
				entry.source.gain = gain
				if done then
					entry.target = nil
					if gain <= 0 then
						self:stop_sound(id)
					end
				end
			end
			-- Not on the frame it started: a source has not been mixed yet
			-- and says it is not playing
			if sounds[id] then
				if entry.started and not entry.source.playing then
					self:stop_sound(id)
				end
				entry.started = true
			end
		end
	end

	function self:sound_count()
		local n = 0
		for _, _ in pairs(sounds) do
			n = n + 1
		end
		return n
	end

	-- Which family of connecting nodes each node id belongs to.
	--
	-- Luanti says this with node ids: a definition lists the ids it connects
	-- to, and a fence's list holds every fence and gate in the game. The
	-- mesher has voxel ids rather than node ids and one word to test, so the
	-- ids are turned into families here, once per set of definitions: two
	-- nodes are in the same family when exactly the same definitions reach
	-- out to them, which is what makes every wood's fence one family and
	-- every stone's wall another.
	--
	-- simplified: 32 families, because the mask the mesher tests is one
	-- word. A game with more gets the rest sharing the last one, which draws
	-- a connection that should not be there rather than dropping one, and
	-- says so.
	local CONNECT_GROUPS_MAX = 32
	local function connect_families(defs)
		-- Who reaches out to whom
		local referrers = {}
		for id, def in pairs(defs) do
			for _, to in ipairs(def.connects_to or {}) do
				local list = referrers[to]
				if not list then
					list = {}
					referrers[to] = list
				end
				list[#list + 1] = id
			end
		end
		local group_of = {}
		local group_of_signature = {}
		local count = 0
		local overflowed = false
		for id, list in pairs(referrers) do
			table.sort(list)
			local signature = table.concat(list, ",")
			if not group_of_signature[signature] then
				if count < CONNECT_GROUPS_MAX then
					count = count + 1
					group_of_signature[signature] = count
				else
					group_of_signature[signature] = CONNECT_GROUPS_MAX
					overflowed = true
				end
			end
			group_of[id] = group_of_signature[signature]
		end
		-- A rail is its own kind of family: Luanti has rails connect by the
		-- connect_to_raillike group rather than by connects_to, and every
		-- rail in a group connects to every other one in it.
		for id, def in pairs(defs) do
			if def.drawtype == DRAWTYPE_RAILLIKE and not group_of[id] then
				local signature = "rail:"..tostring(
						(def.groups or {}).connect_to_raillike or def.name)
				if not group_of_signature[signature] then
					if count < CONNECT_GROUPS_MAX then
						count = count + 1
						group_of_signature[signature] = count
					else
						group_of_signature[signature] = CONNECT_GROUPS_MAX
						overflowed = true
					end
				end
				group_of[id] = group_of_signature[signature]
			end
		end
		if overflowed then
			log:warning("connected nodes: more than "..CONNECT_GROUPS_MAX..
					" families of them; the rest share the last one")
		end
		return group_of
	end

	-- Which liquid family a node belongs to, as a small number, or 0 for a
	-- node that is not a liquid. Two nodes are the same liquid when they name
	-- the same source, which is how a water source and a flowing water are
	-- the same water and lava is not. The numbers are kept across registry
	-- rebuilds; there is a handful of them per game.
	local liquid_groups = {}
	local liquid_group_count = 0
	local function liquid_group(def)
		if def.liquid_type == nil or
				def.liquid_type == NODEDEF_LIQUID_NONE then
			return 0
		end
		local key = def.liquid_alternative_source
		if key == nil or key == "" then
			key = def.name
		end
		if not liquid_groups[key] then
			-- The edge material is one byte and the groups start at 11, so
			-- this cannot run away; a game with two hundred liquids gets the
			-- last of them drawn as if it were the first.
			liquid_group_count = (liquid_group_count % 200) + 1
			liquid_groups[key] = liquid_group_count
		end
		return liquid_groups[key]
	end

	-- A voxel whose six faces are the given resource names, in buildat's face
	-- order (+Y, -Y, +X, -X, +Z, -Z), which is also Luanti's tile order.
	--
	-- With shape given it is not a cube at all: the quads are the voxel's own
	-- geometry, it draws no cube faces of its own, and its neighbours draw
	-- theirs against it. shapes.lua is what builds those.
	-- turns is nil or six quarter turns, one per face: how far the texture is
	-- turned inside its own face. See VoxelDefinition.tile_turns.
	-- liquid_group is nonzero for a liquid, one number per liquid family; see
	-- liquid_group() below. connect is {group, mask, solid} for a node other
	-- nodes connect to or that connects to others; see connect_families().
	-- masked is a shape per neighbour mask instead of one shape, which is
	-- what a rail wants; see VoxelDefinition.shape_masked.
	-- blend is the node's own use_texture_alpha = "blend": see
	-- NODEDEF_ALPHAMODE_BLEND
	-- How many of the definitions built wear a texture beyond their six.
	-- Logged when a registry is done: it is the one number that says the
	-- rooted plants and the liquids' own tiles got through, and a game
	-- where it is zero is a game where they did not.
	local extras_built = 0

	-- surf is what surface.lua guessed the node is made of, or nil for the
	-- placeholder and anything else with no definition behind it
	local function add_cube(voxel_reg, name, resources, kind, shape,
			double_sided, turns, liquid_group, connect, masked, variants,
			blend, solid_base, surf)
		surf = surf or surface.for_node(nil)
		local vdef = buildat.VoxelDefinition()
		vdef.name.block_name = name
		vdef.handler_module = ""
		local textures = {}
		for i = 1, 6 do
			local seg = buildat.AtlasSegmentDefinition()
			seg.resource_name = resources[i]
			seg.total_segments = magic.IntVector2(1, 1)
			seg.select_segment = magic.IntVector2(0, 0)
			seg.roughness = surf.roughness
			seg.spec_strength = surf.spec_strength
			seg.bumpiness = surf.bumpiness
			seg.translucency = surf.translucency
			seg.spots = surf.spots
			seg.static_spots = surf.static_spots
			textures[i] = seg
		end
		vdef.textures = textures
		-- Anything past the six is a texture a shape's quads wear of their
		-- own: the plant standing in a rooted plant's cube of ground. The
		-- list is what the quads address as tile 7 and over.
		local extras = {}
		local i = 7
		while resources[i] do
			local seg = buildat.AtlasSegmentDefinition()
			seg.resource_name = resources[i]
			seg.total_segments = magic.IntVector2(1, 1)
			seg.select_segment = magic.IntVector2(0, 0)
			seg.roughness = surf.roughness
			seg.spec_strength = surf.spec_strength
			seg.bumpiness = surf.bumpiness
			seg.translucency = surf.translucency
			seg.spots = surf.spots
			seg.static_spots = surf.static_spots
			extras[#extras + 1] = seg
			i = i + 1
		end
		if #extras > 0 then
			vdef.extra_textures = extras
			extras_built = extras_built + 1
		end
		if turns then
			vdef.tile_turns = turns
		end
		if liquid_group and liquid_group ~= 0 then
			-- One edge material per liquid family, so water culls against
			-- water and lava against lava while the face between them is
			-- drawn -- and so is the terrain under either, because ground is
			-- neither.
			vdef.edge_material_id = EDGEMATERIAL_LIQUID + liquid_group - 1
			vdef.shape_group = liquid_group
		elseif kind == "glass" then
			vdef.edge_material_id = EDGEMATERIAL_GLASS
		elseif kind == "allfaces" then
			vdef.face_draw_type =
					buildat.VoxelDefinition.FACEDRAWTYPE_ALWAYS
			vdef.edge_material_id =
					buildat.VoxelDefinition.EDGEMATERIALID_GROUND
		else
			vdef.edge_material_id =
					buildat.VoxelDefinition.EDGEMATERIALID_GROUND
		end
		vdef.physically_solid = true
		if connect then
			vdef.connect_group = connect.group or 0
			vdef.connect_mask = connect.mask or 0
			vdef.connect_to_solid = connect.solid and true or false
		end
		-- Which pass the faces go in. The mesher puts a translucent voxel's
		-- faces on a child node of the chunk and world.lua gives that one the
		-- blended technique.
		--
		-- A liquid always, and anything the game asked to be blended rather
		-- than alpha masked: that is what use_texture_alpha = "blend" means,
		-- and without reading it framed glass and panes are drawn with every
		-- texel either solid or gone where the game meant them to be seen
		-- through.
		vdef.translucent = (liquid_group ~= nil and liquid_group ~= 0) or
				blend == true
		if liquid_group ~= nil and liquid_group ~= 0 then
			-- Where the surface stands, which is what the mesher averages
			-- across the voxels around each corner: the top of the shape for
			-- a flowing liquid, and the top of the voxel for a source, which
			-- is what a neighbour's corner rises to.
			vdef.is_liquid = true
			local top = 0.5
			if shape then
				top = -0.5
				for _, quad in ipairs(shape) do
					for i = 2, 11, 3 do
						if quad.p[i] > top then
							top = quad.p[i]
						end
					end
				end
			end
			vdef.liquid_top = top
		end
		if shape then
			vdef.shape = shape
			if masked then
				vdef.shape_masked = masked
			end
			vdef.shape_double_sided = double_sided and true or false
			-- A shape whose voxel is solid ground keeps its six faces: they
			-- are the ground, and the shape standing on them is only what
			-- grows out of it
			if not solid_base then
				vdef.face_draw_type =
						buildat.VoxelDefinition.FACEDRAWTYPE_NEVER
			end
			-- A shaped voxel's neighbours draw their faces against it, which
			-- is what EMPTY says. A liquid keeps its own edge material
			-- instead: a lake's cubes must not draw their faces against the
			-- shaped surface on top of them. So does a shape that fills the
			-- voxel anyway; see rooted_quads().
			if not (liquid_group and liquid_group ~= 0) and
					not solid_base then
				vdef.edge_material_id =
						buildat.VoxelDefinition.EDGEMATERIALID_EMPTY
			end
			-- And such a shape is lit by the voxel it stands in rather than
			-- by its own, which is solid ground: a plant on the sea bed is
			-- under the water above it, not in the open.
			vdef.shape_lit_from_above = solid_base and true or false
		end
		if variants then
			vdef.variants = variants
		end
		return voxel_reg:add_voxel(vdef)
	end

	-- The registry as it is until the node definitions arrive: air, and one
	-- placeholder cube for everything else. set_node_definitions() replaces
	-- it with one built from what the server says the nodes are.
	local function base_registry()
		local voxel_reg = buildat.createVoxelRegistry()
		-- Luanti's own cut of a 32-bit node, which fits buildat's voxel
		-- word exactly: a 16-bit node id, param1 as two light nibbles, and
		-- param2. What the param buys is that a node's facing and a flowing
		-- liquid's level reach the mesher as data instead of as a voxel type
		-- per (definition, param2) pair; see build_variants().
		voxel_reg:set_format{
			plane_bits = 32,
			id = {shift = 0, width = 16},
			light_sky = {shift = 16, width = 4},
			light_lamp = {shift = 20, width = 4},
			param = {shift = 24, width = 8},
		}
		local vdef = buildat.VoxelDefinition()
		vdef.name.block_name = "air"
		vdef.handler_module = ""
		-- Air draws no faces of its own; the solid voxel next to it draws the
		-- face between them
		vdef.face_draw_type = buildat.VoxelDefinition.FACEDRAWTYPE_NEVER
		vdef.edge_material_id = buildat.VoxelDefinition.EDGEMATERIALID_EMPTY
		vdef.physically_solid = false
		vdef.fully_empty = true
		voxel_reg:add_voxel(vdef) -- VOXEL_AIR
		add_cube(voxel_reg, "placeholder",
				{texture, texture, texture, texture, texture, texture},
				"ground") -- VOXEL_PLACEHOLDER
		return voxel_reg
	end

	-- On self rather than in a local: set_node_definitions() replaces both,
	-- and mesh_block() has to use whichever is current
	self.voxel_reg = base_registry()
	local function new_atlas_registry()
		local reg = buildat.createAtlasRegistry()
		-- The PBR shader samples the normal and surface maps the registry
		-- derives from each texture; the unlit one samples the diffuse atlas
		-- and nothing else, and deriving the other two is two thirds of what
		-- adding a texture to an atlas costs. That loading time is what the
		-- connect dialog's checkbox spends.
		reg:set_surface_maps(pbr)
		return reg
	end

	self.atlas_reg = new_atlas_registry()

	-- key -> {x=, y=, z=, param0=, param1=, node=}
	local blocks = {}
	-- key -> true for blocks whose mesh is out of date
	local dirty = {}
	local dirty_count = 0

	self.node_map = PLACEHOLDER_MAP
	self.node_map_default = VOXEL_PLACEHOLDER
	-- pack_voxel_volume() compiles a map once per (id, version) rather than
	-- once per source: a map of a few thousand node ids costs more to compile
	-- than the whole block copy does, and every source of every block hands
	-- in the same two maps. The ids are ours to pick; the versions say when a
	-- map has changed. See doc/client_api.txt.
	local MAP_ID_NODE, MAP_ID_PAIR, MAP_ID_LIGHT = 1, 2, 3
	-- The PBR path's curve is a different table and so needs an id of its own;
	-- the compiled maps are cached by id
	local MAP_ID_LIGHT_PBR = 4
	local light_map = pbr and PBR_LIGHT_MAP or LIGHT_MAP
	local light_map_id = pbr and MAP_ID_LIGHT_PBR or MAP_ID_LIGHT
	self.node_map_version = 1
	self.pair_map_version = 1
	self.use_skylight = true
	-- id -> true for the nodes the player collides with, and for the ones it
	-- swims in. nil rather than a table means the definitions have not
	-- arrived and everything but air is solid; see is_solid().
	self.node_solid = nil
	self.node_liquid = {}
	-- The screen tint of the node the camera is in, per node id; see
	-- post_effect_at(). Only the nodes that have one are in here.
	self.node_post_effect = {}
	-- What the pointed-node outline goes around, per node id; see
	-- selection_at(). A node that is not in here is outlined as a whole
	-- voxel.
	self.node_selection = {}
	-- id -> false for the nodes a pointing ray goes through; nil means the
	-- definitions have not arrived and everything but air stops one
	self.node_pointable = nil

	-- One voxel id per (definition, palette colour), for the pairs that turn
	-- up in a block that arrives. The map is keyed the way the paired lookup
	-- wants; pair_voxel is keyed by what actually decides the look, so two
	-- param2 values that pick the same palette colour share a voxel id.
	--
	-- A colour is the only thing param2 says that still costs a voxel type:
	-- it tints the texture, and the tint has to be composed into one. The
	-- rest -- which way a voxel faces, how high its liquid stands -- reaches
	-- the mesher as the param itself; see build_variants().
	self.pair_map = {}
	self.pair_count = 0
	local pair_voxel = {}
	-- Bumped when the definitions change: every block has to be looked at
	-- again, because what its param2 means has changed
	local pair_epoch = 0
	-- id -> {def =, step =, colors =, variants =} for the definitions whose
	-- param2 is a palette index; nil for everything else. What param2 says
	-- about a voxel's shape does not come through here any more -- that is
	-- what the definitions' variants carry -- so this is only about colour.
	local param2_look = {}
	-- Set by set_node_definitions(), which is what knows how to build one
	local build_pair = nil

	-- The pairs in one block that have no voxel id yet. Scanning 4096 voxels
	-- in Lua is not free, so it happens once per block rather than once per
	-- mesh, and only while some definition cares about param2 at all.
	local function register_pairs(block)
		if not build_pair or not block.param2 or not next(param2_look) then
			return
		end
		if block.pair_epoch == pair_epoch then
			return
		end
		block.pair_epoch = pair_epoch
		local param0, param2 = block.param0, block.param2
		local n = BLOCKSIZE * BLOCKSIZE * BLOCKSIZE
		for i = 0, n - 1 do
			local hi, lo = param0:byte(i * 2 + 1, i * 2 + 2)
			local entry = param2_look[hi * 256 + lo]
			if entry then
				local p2 = param2:byte(i + 1)
				local key = hi * 256 + lo + p2 * PAIR_SCALE
				if self.pair_map[key] == nil then
					build_pair(entry, hi * 256 + lo, p2, key)
				end
			end
		end
	end

	local function mark_dirty(key)
		if blocks[key] and not dirty[key] then
			dirty[key] = true
			dirty_count = dirty_count + 1
		end
	end

	-- Where the block's scene node goes. A voxel v of the block ends up at
	-- world blockpos * 16 + v, which is the Luanti node coordinate.
	local function block_node_position(x, y, z)
		local half = BLOCKSIZE / 2 - 0.5
		return magic.Vector3(x * BLOCKSIZE + half, y * BLOCKSIZE + half,
				z * BLOCKSIZE + half)
	end

	-- The seven box copies that make one block's volume: the block itself, and
	-- the one-node slice of each neighbour that has arrived.
	local function volume_sources(block)
		local sources = {
			{
				data = block.param0, format = "u16be",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0},
				map = self.node_map, map_default = self.node_map_default,
				map_id = MAP_ID_NODE, map_version = self.node_map_version,
			},
		}
		-- A second pass over the same box for the voxels whose param2 says
		-- what they look like: no map_default, so a pair that has no voxel id
		-- of its own leaves what the pass above wrote alone. That is what
		-- keeps this from having to hold an entry for every (id, param2)
		-- pair in the game.
		if self.pair_count > 0 and block.param2 then
			sources[#sources + 1] = {
				data = block.param0, format = "u16be",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0},
				second = {data = block.param2, format = "u8",
						scale = PAIR_SCALE},
				map = self.pair_map,
				map_id = MAP_ID_PAIR, map_version = self.pair_map_version,
			}
		end
		-- param2 itself, which the definitions interpret: which way a voxel
		-- faces, how high its liquid stands. No map -- it goes in as it is.
		if block.param2 then
			sources[#sources + 1] = {
				data = block.param2, format = "u8",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0}, field = "param",
			}
		end
		if self.use_skylight then
			sources[#sources + 1] = {
				data = block.param1, format = "u8",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0}, map = light_map, field = "light",
				map_id = light_map_id, map_version = 1,
			}
		end
		for _, d in ipairs(NEIGHBOURS) do
			local n = blocks[block_key(block.x + d[1], block.y + d[2],
					block.z + d[3])]
			if n then
				-- The slice facing us: the neighbour's last plane on a
				-- negative side, its first on a positive one
				local from, size, at = {0, 0, 0}, {BLOCKSIZE, BLOCKSIZE,
						BLOCKSIZE}, {0, 0, 0}
				for i = 1, 3 do
					if d[i] < 0 then
						from[i] = BLOCKSIZE - 1
						size[i] = 1
						at[i] = -1
					elseif d[i] > 0 then
						from[i] = 0
						size[i] = 1
						at[i] = BLOCKSIZE
					end
				end
				sources[#sources + 1] = {
					data = n.param0, format = "u16be",
					source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
					from = from, size = size, at = at,
					map = self.node_map, map_default = self.node_map_default,
					map_id = MAP_ID_NODE, map_version = self.node_map_version,
				}
				if self.pair_count > 0 and n.param2 then
					sources[#sources + 1] = {
						data = n.param0, format = "u16be",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						second = {data = n.param2, format = "u8",
								scale = PAIR_SCALE},
						map = self.pair_map,
						map_id = MAP_ID_PAIR,
						map_version = self.pair_map_version,
					}
				end
				if n.param2 then
					sources[#sources + 1] = {
						data = n.param2, format = "u8",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						field = "param",
					}
				end
				if self.use_skylight then
					sources[#sources + 1] = {
						data = n.param1, format = "u8",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						map = light_map, field = "light",
						map_id = light_map_id, map_version = 1,
					}
				end
			end
		end
		return sources
	end

	-- Microseconds the last block spent being packed and handed to the
	-- mesher. The meshing itself is on a worker thread; this is what it costs
	-- the frame.
	self.last_mesh_us = 0

	-- What colour a light source shines in: the average of its own first
	-- tile, brightest channel brought up to one so that how bright it is
	-- stays the light level's business. A torch is then warm and a soul
	-- torch is blue without anything having to know what either is.
	--
	-- Luanti has one number for this -- light_source -- and paints every
	-- source the same; the plan's "rendering does not have to match" is what
	-- this leans on.
	local light_color_cache = {}

	local function light_color(resource)
		if not resource or not read_image then
			return LIGHT_COLOR
		end
		local held = light_color_cache[resource]
		if held then
			return held
		end
		local color = LIGHT_COLOR
		local ok, w, h, rgba = pcall(read_image, resource)
		if ok and rgba and w and h and w > 0 and h > 0 then
			local r, g, b, weight = 0, 0, 0, 0
			-- Every fourth pixel is enough of an average and a 64x64 tile is
			-- four thousand of them
			for i = 0, w * h - 1, 4 do
				local pr, pg, pb, pa = rgba:byte(i * 4 + 1, i * 4 + 4)
				if pa and pa > 128 then
					r = r + pr
					g = g + pg
					b = b + pb
					weight = weight + 1
				end
			end
			if weight > 0 then
				local top = math.max(r, g, b)
				if top > 0 then
					color = {r = r / top, g = g / top, b = b / top}
				end
			end
		end
		light_color_cache[resource] = color
		return color
	end

	-- Where the voxels that give light are in a block, in world
	-- coordinates, and how bright: what a scene light is put at.
	--
	-- simplified: only the first MAX_LIGHTS_PER_BLOCK of a block are kept,
	-- and which those are is whichever the scan meets first rather than the
	-- brightest.
	local function find_lights(block)
		local levels = self.node_light
		if not levels or not next(levels) then
			return nil
		end
		local out = nil
		local param0 = block.param0
		local n = BLOCKSIZE * BLOCKSIZE * BLOCKSIZE
		for i = 0, n - 1 do
			local hi, lo = param0:byte(i * 2 + 1, i * 2 + 2)
			local light = levels[hi * 256 + lo]
			if light then
				out = out or {}
				-- The index order is x fastest, then y, then z
				local x = i % BLOCKSIZE
				local y = math.floor(i / BLOCKSIZE) % BLOCKSIZE
				local z = math.floor(i / (BLOCKSIZE * BLOCKSIZE))
				out[#out + 1] = {
					block.x * BLOCKSIZE + x,
					block.y * BLOCKSIZE + y,
					block.z * BLOCKSIZE + z,
					light.level,
					light.color,
				}
				if #out >= MAX_LIGHTS_PER_BLOCK then
					break
				end
			end
		end
		return out
	end

	-- The lights that are in the scene now, as scene nodes kept and reused:
	-- creating and destroying a light every time the player moves would cost
	-- more than the lighting does.
	local light_pool = {}
	local lights_stale = true
	local lights_at = nil

	-- Puts the scene's lights on the light-giving voxels nearest the camera.
	local function place_lights()
		local p = camera_node.position
		local reach = 60
		local best = {}
		for _, block in pairs(blocks) do
			if block.lights then
				for _, l in ipairs(block.lights) do
					local dx, dy, dz = l[1] - p.x, l[2] - p.y, l[3] - p.z
					local d = dx * dx + dy * dy + dz * dz
					if d < reach * reach then
						best[#best + 1] = {d = d, l = l}
					end
				end
			end
		end
		table.sort(best, function(a, b) return a.d < b.d end)
		for i = 1, MAX_SCENE_LIGHTS do
			local entry = best[i]
			local held = light_pool[i]
			if entry and not held then
				local node = scene:CreateChild("light_"..i)
				held = {node = node, light = node:CreateComponent("Light")}
				held.light.lightType = magic.LIGHT_POINT
				held.light.castShadows = false
				-- The world's own light is diffuse; a highlight moving
				-- about on a painted texture only looks wrong
				held.light.specularIntensity = 0
				light_pool[i] = held
			end
			if held then
				if entry then
					local l = entry.l
					held.node.position = magic.Vector3(l[1], l[2], l[3])
					held.light.range = l[4] * LIGHT_RANGE_PER_LEVEL
					-- Luanti's light levels run to 14, and a torch is 12.
					-- Kept low: this is added on top of the light the
					-- mesher already baked in, and a cave with a few
					-- torches in it washes out otherwise.
					held.light.brightness = 0.1 + l[4] / 14 * 0.3
					-- Setting a colour is a sandbox call; most of these
					-- keep the one they have from one frame to the next
					local color = l[5] or LIGHT_COLOR
					if color ~= held.color then
						held.color = color
						held.light.color = magic.Color(color.r, color.g,
								color.b)
					end
					held.node.enabled = true
				else
					held.node.enabled = false
				end
			end
		end
	end

	-- Defined with the rest of the sky-visibility cache below, which is after
	-- this because it packs a block the same way this does
	local vis_volumes_drop
	local function mesh_block(key)
		local block = blocks[key]
		if not block then
			return
		end
		local t0 = buildat.get_time_us()
		-- What the voxels in it look like may depend on their param2, and a
		-- pair that has no voxel id of its own draws as if its param2 were
		-- zero. Here rather than when the block arrives, because the blocks
		-- that were already there when the definitions came have to be
		-- looked at too, and meshing is already spread over frames.
		register_pairs(block)
		if not block.node then
			block.node = scene:CreateChild("block_"..key)
			block.node.position = block_node_position(block.x, block.y, block.z)
		end
		local data = buildat.pack_voxel_volume{
			region = {VOLUME_MIN, VOLUME_MIN, VOLUME_MIN,
					VOLUME_MAX, VOLUME_MAX, VOLUME_MAX},
			-- Whose format the field names mean; see base_registry()
			registry = self.voxel_reg,
			fill = VOXEL_AIR_LIT,
			sources = volume_sources(block),
		}
		-- Only when this block's own voxels have changed: scanning 4096 of
		-- them in Lua is not free, and a block is meshed again every time a
		-- neighbour arrives
		if block.lights == nil then
			block.lights = find_lights(block) or false
			if block.lights or block.had_lights then
				block.had_lights = block.lights and true or nil
				lights_stale = true
			end
		end
		-- The sky-visibility cache holds a copy of this block's voxels; it
		-- is rebuilt from the block the next time it is wanted
		vis_volumes_drop(key)
		local node = block.node
		buildat.set_voxel_geometry(node, data, self.voxel_reg,
				self.atlas_reg, self.use_skylight,
				function() apply_technique(node) end)
		self.last_mesh_us = buildat.get_time_us() - t0
		-- The worst single block of the frame, for the slow-frame line: one
		-- block that costs ten times what the others do is a different
		-- problem from eight that each cost their share
		if self.last_mesh_us > (self.worst_mesh_us or 0) then
			self.worst_mesh_us = self.last_mesh_us
		end
	end

	-- The voxel data the sky-visibility marching walks through, when the PBR
	-- path is on: a Volume per block near the camera, which is data this
	-- client does not otherwise keep -- it packs a block, hands it to the
	-- mesher and forgets it. Packing it again and deserializing is the way in.
	--
	-- Built a few blocks a frame rather than a set at a time. A ray that
	-- leaves the volumes it was given keeps the skylight of the last air it
	-- was in, so a block that is not built yet reads as whatever is around it
	-- rather than as a wall: the answers start open and tighten as the cache
	-- fills, which is the right way round for a player walking into a cave.
	local VIS_MARGIN = 32              -- Voxels around the camera
	local VIS_BUILD_PER_CALL = 8
	local vis_volumes = {}             -- key -> {x=, y=, z=, volume=}
	local vis_list = {}                -- The same entries, as collect wants
	local vis_chunk_size = {x = BLOCKSIZE, y = BLOCKSIZE, z = BLOCKSIZE}

	-- No border: the marching steps from block to block through the list, so
	-- the slice of a neighbour the mesher needs is somebody else's copy here
	local function vis_volume_of(block)
		return buildat.deserialize_volume(buildat.pack_voxel_volume{
			region = {0, 0, 0, BLOCKSIZE - 1, BLOCKSIZE - 1, BLOCKSIZE - 1},
			registry = self.voxel_reg,
			fill = VOXEL_AIR_LIT,
			sources = volume_sources(block),
		})
	end

	-- A block whose voxels have changed: the copy here is stale
	vis_volumes_drop = function(key)
		vis_volumes[key] = nil
	end

	local function collect_vis_volumes(origin)
		local r = math.ceil(VIS_MARGIN / BLOCKSIZE)
		local cx = math.floor(origin.x / BLOCKSIZE)
		local cy = math.floor(origin.y / BLOCKSIZE)
		local cz = math.floor(origin.z / BLOCKSIZE)
		local wanted = {}
		local n = 0
		local built = 0
		for z = cz - r, cz + r do
			for y = cy - r, cy + r do
				for x = cx - r, cx + r do
					local key = block_key(x, y, z)
					local block = blocks[key]
					if block then
						wanted[key] = true
						local entry = vis_volumes[key]
						if entry == nil and built < VIS_BUILD_PER_CALL then
							entry = {x = x, y = y, z = z,
									volume = vis_volume_of(block)}
							vis_volumes[key] = entry
							built = built + 1
						end
						if entry then
							n = n + 1
							vis_list[n] = entry
						end
					end
				end
			end
		end
		for i = #vis_list, n + 1, -1 do
			vis_list[i] = nil
		end
		-- What has gone out of range, or been dropped, or been replaced
		for key, _ in pairs(vis_volumes) do
			if not wanted[key] then
				vis_volumes[key] = nil
			end
		end
		if n == 0 then
			return nil
		end
		return {chunk_size = vis_chunk_size, registry = self.voxel_reg,
				volumes = vis_list}
	end

	-- Only with the PBR path: nothing else reads it, and it is a worker
	-- thread's worth of ray marching a frame
	local vis = pbr and skyvis.new(magic, buildat, collect_vis_volumes) or nil
	-- Where the camera was last frame, to tell a step from a teleport
	local vis_at = nil

	local function update_sky_visibility()
		if not vis then return end
		local p = camera_node.position
		-- A teleport, or the first frame: march the whole cube at once rather
		-- than easing towards it over the next second, so that what is on
		-- screen straight after is settled
		local moved = vis_at and math.max(math.abs(p.x - vis_at[1]),
				math.abs(p.y - vis_at[2]), math.abs(p.z - vis_at[3])) or nil
		vis_at = {p.x, p.y, p.z}
		vis:update(p, (moved ~= nil and moved < 8) and 1 or nil)
	end

	-- For the counters: how much sky the shader is being told there is
	-- straight up, and how many blocks' voxels that answer was marched
	-- through. nil when the PBR path is off, which is what says not to show
	-- the counter at all.
	function self:sky_visibility()
		if not vis then return nil end
		return vis:value_of(skyvis.cell_of(0, 1, 0)), #vis_list
	end

	-- A block that arrived from the server. Its own mesh and its neighbours'
	-- are then out of date, because their borders come from each other.
	function self:set_block(block)
		local key = block_key(block.x, block.y, block.z)
		local existing = blocks[key]
		if existing then
			existing.param0 = block.param0
			existing.param1 = block.param1
			existing.param2 = block.param2
			existing.meta = block.meta
			existing.lights = nil -- Its voxels have changed
			existing.pair_epoch = nil
		else
			blocks[key] = {
				x = block.x, y = block.y, z = block.z,
				param0 = block.param0, param1 = block.param1,
				param2 = block.param2, meta = block.meta,
			}
		end
		mark_dirty(key)
		for _, d in ipairs(NEIGHBOURS) do
			mark_dirty(block_key(block.x + d[1], block.y + d[2],
					block.z + d[3]))
		end
	end

	-- How many (definition, param2) pairs have a voxel id of their own, for
	-- the counters: this is what says whether the palettes are being used
	function self:pair_voxel_count()
		return self.pair_count
	end

	-- What hangs off the voxel at a node position: {fields =, lists =}, or
	-- nil. The metadata came with the block the voxel is in, keyed by the
	-- index into it.
	function self:node_meta(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block or not block.meta then
			return nil
		end
		local ix = x - bx * BLOCKSIZE
		local iy = y - by * BLOCKSIZE
		local iz = z - bz * BLOCKSIZE
		return block.meta[(iz * BLOCKSIZE + iy) * BLOCKSIZE + ix]
	end

	-- The metadata a server changed, keyed by "x,y,z": it goes into the block
	-- that holds each position, so that dropping the block drops it too.
	function self:set_node_meta(entries)
		for at, entry in pairs(entries) do
			local x, y, z = at:match("^(-?%d+),(-?%d+),(-?%d+)$")
			if x then
				x, y, z = tonumber(x), tonumber(y), tonumber(z)
				local bx = math.floor(x / BLOCKSIZE)
				local by = math.floor(y / BLOCKSIZE)
				local bz = math.floor(z / BLOCKSIZE)
				local block = blocks[block_key(bx, by, bz)]
				if block then
					block.meta = block.meta or {}
					local i = ((z - bz * BLOCKSIZE) * BLOCKSIZE +
							(y - by * BLOCKSIZE)) * BLOCKSIZE +
							(x - bx * BLOCKSIZE)
					block.meta[i] = entry
				end
			end
		end
	end

	function self:get_block(x, y, z)
		return blocks[block_key(x, y, z)]
	end

	-- The Luanti content id at a node position, or nil if the block holding
	-- it has not arrived. param0 is two big-endian bytes per node, x fastest.
	function self:node_at(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block then
			return nil
		end
		local i = (x - bx * BLOCKSIZE) +
				(y - by * BLOCKSIZE) * BLOCKSIZE +
				(z - bz * BLOCKSIZE) * BLOCKSIZE * BLOCKSIZE
		local hi, lo = block.param0:byte(i * 2 + 1, i * 2 + 2)
		return hi * 256 + lo
	end

	-- param1 (the two light nibbles) at a node position, or nil if the block
	-- holding it has not arrived.
	local function param1_at(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block then
			return nil
		end
		local i = (x - bx * BLOCKSIZE) +
				(y - by * BLOCKSIZE) * BLOCKSIZE +
				(z - bz * BLOCKSIZE) * BLOCKSIZE * BLOCKSIZE
		return block.param1:byte(i + 1)
	end

	-- What light a node that just became air has. The server does not send
	-- light for a removal and Luanti's own client runs a light flood there;
	-- this takes the brightest neighbour and dims it by one step instead,
	-- separately for sunlight and for lamplight, and keeps full sunlight
	-- undimmed so that a column dug down from the open sky stays lit.
	--
	-- simplified: one node deep. Digging a tunnel is right anyway, because
	-- each node in turn sees the one behind it, but a node that should have
	-- gone *darker* (or brighter through a corner) only catches up when the
	-- server resends the block. A real flood fill is the upgrade.
	-- The param2 of the voxel at a node position, or 0 when the block is not
	-- here: which way it faces, or what colour it is
	local function param2_at(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block or not block.param2 then
			return 0
		end
		local i = ((z - bz * BLOCKSIZE) * BLOCKSIZE +
				(y - by * BLOCKSIZE)) * BLOCKSIZE + (x - bx * BLOCKSIZE)
		return block.param2:byte(i + 1) or 0
	end

	local function removal_light(x, y, z)
		local day, night = 0, 0
		for _, d in ipairs(NEIGHBOURS) do
			local p = param1_at(x + d[1], y + d[2], z + d[3])
			if p then
				local nd, nn = p % 16, math.floor(p / 16)
				-- Straight down from the open sky does not dim
				if nd > 0 and not (nd == 15 and d[2] > 0) then
					nd = nd - 1
				end
				if nn > 0 then
					nn = nn - 1
				end
				if nd > day then day = nd end
				if nn > night then night = nn end
			end
		end
		return night * 16 + day
	end

	-- Whether a node stops the player. A node whose block has not arrived,
	-- and one the server says is not generated, both count as solid, which is
	-- what Luanti's own collision does with them: standing still in a world
	-- that has not loaded is better than falling through it.
	--
	-- Until the node definitions arrive nothing is known but air, and
	-- everything else is drawn as a placeholder cube, so that is what it
	-- collides as.
	-- What the player runs into at a node position: false for nothing, true
	-- for the whole voxel, or the boxes it is made of -- a slab, a stair, a
	-- fence post -- in the voxel's own -0.5...0.5 coordinates.
	function self:is_solid(x, y, z)
		local id = self:node_at(x, y, z)
		if id == nil or id == CONTENT_IGNORE then
			return true
		end
		if id == CONTENT_AIR then
			return false
		end
		if self.node_solid then
			-- A node the definitions did not cover is drawn as a placeholder
			-- cube, so it collides as one; only what the server says is not
			-- walkable is walked through
			if self.node_solid[id] == false then
				return false
			end
			local entry = self.node_collision and self.node_collision[id]
			if entry then
				-- The boxes turn with the voxel, the same way its shape does
				local facedir = entry.facing and shapes.facedir_of(
						entry.facing, param2_at(x, y, z)) or nil
				if not facedir or facedir == 0 then
					return entry.boxes
				end
				local key = facedir
				entry.turned = entry.turned or {}
				if not entry.turned[key] then
					entry.turned[key] = turn_boxes(entry.boxes, facedir)
				end
				return entry.turned[key]
			end
			return true
		end
		return true
	end

	-- The colour to paint over the whole screen because the camera is in this
	-- node, as Luanti's post_effect_color {a, r, g, b} in 0...255, or nil for
	-- a node that has none. What this is for is being under water.
	function self:post_effect_at(x, y, z)
		local id = self:node_at(x, y, z)
		if id == nil then
			return nil
		end
		return self.node_post_effect[id]
	end

	-- Whether a node is something to swim in
	function self:is_liquid(x, y, z)
		local id = self:node_at(x, y, z)
		return id ~= nil and self.node_liquid[id] == true
	end

	-- Whether a ray stops at a node. Air does not stop one and neither does
	-- a node the game says is not pointable; a node whose block has not
	-- arrived does not either, because pointing at nothing is better than
	-- digging at a guess.
	function self:is_pointable(x, y, z)
		local id = self:node_at(x, y, z)
		if id == nil or id == CONTENT_AIR or id == CONTENT_IGNORE then
			return false
		end
		if self.node_pointable then
			return self.node_pointable[id] ~= false
		end
		return true
	end

	-- What the camera is pointing at, up to range nodes away. Returns the
	-- node the ray stopped in and the last empty node before it, which is
	-- where a placed node would go, or nil for nothing in range.
	--
	-- Marching in steps a tenth of a node long and rounding to the nearest
	-- integer, which is what games/digger does: a node is the cube around
	-- its coordinate, so rounding is the whole test. A step that lands in the
	-- same node as the last one is skipped rather than asked about twice.
	local POINT_STEP = 0.1

	function self:point_ray(range)
		local p = camera_node.position
		local d = camera_node.direction
		local last = nil
		for i = 1, math.floor(range / POINT_STEP) do
			local x = math.floor(p.x + d.x * i * POINT_STEP + 0.5)
			local y = math.floor(p.y + d.y * i * POINT_STEP + 0.5)
			local z = math.floor(p.z + d.z * i * POINT_STEP + 0.5)
			if not last or x ~= last[1] or y ~= last[2] or z ~= last[3] then
				if self:is_pointable(x, y, z) then
					return {x, y, z}, last, i * POINT_STEP
				end
				last = {x, y, z}
			end
		end
		return nil
	end

	-- The nearest object the camera ray enters, up to range nodes away.
	-- Returns its id and how far along the ray its box begins, or nil.
	--
	-- An object is pointed at by its selection box, which is in nodes and is
	-- given around the object's own position. props.pointable is Luanti's
	-- PointabilityType: 0 is not pointable, 1 is, and 2 stops the ray
	-- without being pointed at itself -- so a 2 is tested for distance and
	-- then reported as nothing.
	--
	-- The player's own object is skipped: it stands where the camera is, so
	-- the ray starts inside its box and it would be pointed at all the
	-- time. init.lua marks it is_self.
	function self:point_objects(range, objects)
		local p = camera_node.position
		local d = camera_node.direction
		local best_id, best_t, best_blocks = nil, range, false
		for id, obj in pairs(objects) do
			local props = obj.props
			local pointable = props and props.pointable or 0
			if obj.position and pointable ~= 0 and not obj.is_self and
					props.is_visible ~= false and
					props.selection_min and props.selection_max then
				local lo = {
					obj.position[1] + props.selection_min[1],
					obj.position[2] + props.selection_min[2],
					obj.position[3] + props.selection_min[3],
				}
				local hi = {
					obj.position[1] + props.selection_max[1],
					obj.position[2] + props.selection_max[2],
					obj.position[3] + props.selection_max[3],
				}
				-- The slab test: the ray is inside the box between the
				-- largest near crossing and the smallest far one
				local origin = {p.x, p.y, p.z}
				local dir = {d.x, d.y, d.z}
				local t0, t1 = 0, range
				for axis = 1, 3 do
					if math.abs(dir[axis]) < 1e-9 then
						if origin[axis] < lo[axis] or
								origin[axis] > hi[axis] then
							t0, t1 = 1, 0 -- Parallel and outside
						end
					else
						local a = (lo[axis] - origin[axis]) / dir[axis]
						local b = (hi[axis] - origin[axis]) / dir[axis]
						if a > b then
							a, b = b, a
						end
						t0 = math.max(t0, a)
						t1 = math.min(t1, b)
					end
				end
				if t0 <= t1 and t0 < best_t then
					best_id = pointable == 1 and id or nil
					best_t = t0
					best_blocks = true
				end
			end
		end
		if not best_blocks then
			return nil
		end
		return best_id, best_t
	end

	-- The outline of the face the ray came through, on the node it stopped
	-- in. One flat outline that gets turned to whichever face it is, which is
	-- what games/digger does; NoTextureVColMultiply darkens what is behind it
	-- rather than drawing over it, so it reads on any texture.
	-- What is pointed at: a frame around every face of the voxel, which
	-- together read as the wire box Luanti draws around it. Two triangles
	-- per side of each frame, in one geometry, and the whole thing is moved
	-- to the voxel that is pointed at rather than built again.
	--
	-- simplified: the box is the voxel's cube, not its shape, so what is
	-- outlined around a stair or a torch is the whole voxel. Luanti outlines
	-- the selection box, which is what would have to be handed in here.
	local pointed_node = scene:CreateChild("Pointed")
	do
		local cg = pointed_node:CreateComponent("CustomGeometry")
		cg:BeginGeometry(0, magic.TRIANGLE_LIST)
		cg:SetNumGeometries(1)
		local color = magic.Color(0.06, 0.06, 0.06)
		-- Just outside the voxel, so the frame does not fight the face it is
		-- drawn on for the depth buffer
		local d = 0.502
		local w = 1.0 / 16

		-- One rectangle in a plane, given as the two axes it runs along and
		-- the constant of the third. axis is 1, 2 or 3 for x, y or z.
		-- Wound both ways: the frames on three of the six faces would
		-- otherwise face away from the middle of the voxel and be culled,
		-- which is the same as not drawing them at all.
		local function quad(axis, at, a0, b0, a1, b1)
			local corners = {
				{a0, b1}, {a1, b1}, {a1, b0}, {a1, b0}, {a0, b0}, {a0, b1},
				{a0, b1}, {a0, b0}, {a1, b0}, {a1, b0}, {a1, b1}, {a0, b1},
			}
			for _, c in ipairs(corners) do
				local p = {}
				if axis == 2 then
					p = {c[1], at, c[2]}
				elseif axis == 1 then
					p = {at, c[1], c[2]}
				else
					p = {c[1], c[2], at}
				end
				cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
				cg:DefineColor(color)
			end
		end

		-- The four bars of a frame in one plane
		local function frame(axis, at)
			quad(axis, at, -d, d - w, d, d)
			quad(axis, at, -d, -d, d, -d + w)
			quad(axis, at, d - w, -d + w, d, d - w)
			quad(axis, at, -d, -d + w, -d + w, d - w)
		end

		for axis = 1, 3 do
			frame(axis, d)
			frame(axis, -d)
		end
		cg:Commit()
		local m = magic.Material.new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/NoTextureVColMultiply.xml"))
		cg:SetMaterial(0, m)
		pointed_node.enabled = false
	end

	-- The crack over the voxel being dug. Luanti draws it as a second layer
	-- on the voxel's own tiles, which follows whatever shape it has; this is
	-- a cube just outside the voxel wearing one frame of the crack texture,
	-- which is the same picture on anything that is a cube.
	--
	-- simplified: so the crack on a stair or a torch is a cube around it.
	-- The faithful way is a voxel per (definition, crack frame) through the
	-- pair machinery, which is five more voxel types per definition -- and
	-- the definitions are already two and a half thousand.
	--
	-- One node per frame, enabled one at a time, rather than one node whose
	-- material is swapped: a Material lives only as long as something in the
	-- engine holds it, and a StaticModel that has been handed one is such a
	-- thing. Keeping materials in a Lua table and putting them back on the
	-- model later reads the freed one.
	local crack_nodes = {}
	local crack_worn = nil

	local function crack_node_for(resource)
		local node = crack_nodes[resource]
		if node then
			return node
		end
		node = scene:CreateChild("Crack")
		local model = node:CreateComponent("StaticModel")
		model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
		local material = magic.Material.new()
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/UnlitAlphaMask.xml"))
		material:SetTexture(0, game_texture(resource))
		model.material = material
		-- Just outside the voxel, so the crack does not fight the face it is
		-- drawn on for the depth buffer
		node.scale = magic.Vector3(1.004, 1.004, 1.004)
		node.enabled = false
		crack_nodes[resource] = node
		return node
	end

	-- set_crack(under, resource)
	--
	-- under is the voxel being dug and resource the texture of the frame the
	-- dig has got to; either being nil takes the crack away.
	function self:set_crack(under, resource)
		if crack_worn and crack_worn ~= resource then
			crack_nodes[crack_worn].enabled = false
			crack_worn = nil
		end
		if not under or not resource then
			return
		end
		local node = crack_node_for(resource)
		node.position = magic.Vector3(under[1], under[2], under[3])
		node.enabled = true
		crack_worn = resource
	end

	--
	-- The things in the world that are not nodes
	--

	local object_technique = magic.cache:GetResource("Technique",
			"luanti_client/res/UnlitAlphaMask.xml")
	local box_model = magic.cache:GetResource("Model", "Models/Box.mdl")
	-- Particles are blended rather than cut out -- smoke and a spark are
	-- soft-edged -- and unlit, like the objects. Urho3D ships the technique.
	local particle_technique = magic.cache:GetResource("Technique",
			"Techniques/DiffUnlitParticleAlpha.xml")

	-- The light an object is drawn in. Its texture goes on unlit -- the
	-- entities of this game are drawn unlit in Luanti's own client too, and
	-- their textures are full of holes -- so what stands in for the light is
	-- a colour the shader multiplies the texture by, worked out the same way
	-- the voxel around it is lit. Without this a mob is as bright at midnight
	-- as at noon.
	--
	-- Which way that is worked out depends on the path, because the two light
	-- a voxel differently and an object beside one has to agree with it. The
	-- vanilla path bakes the sunlight colour into the vertices and that is
	-- all there is; the PBR path has a sky for an ambient and a sun of its
	-- own on top, so an object gets both. There is no normal to take a real
	-- share of the sun by -- that is what unlit means -- so it gets a fixed
	-- one, which is what a thing standing in the sun shows on average.
	-- How much of the sun an object shows. One number has to serve for both
	-- a mob in the open and one under a tree, because an unlit thing has no
	-- normal to shadow: measured on the ground it stands on, sunlit grass
	-- renders at about twelve times the same grass in a shadow, and what is
	-- picked here lands an object between the two. It is the number to move
	-- if mobs read as glowing in a wood or as cut out in a field.
	local OBJECT_SUN = 1.0
	-- What something in the pitch dark is worth, so that it is a silhouette
	-- rather than nothing. Small, because the ambient it is added to is small
	-- at night and a mob that glows is worse than one that is hard to see.
	local OBJECT_DARK_FLOOR = 0.01
	-- What the sun is worth to an object now: its colour and how much of it
	-- there is, kept by apply_daylight() because that is where it is known
	local object_sun = nil

	local function object_color(x, y, z)
		local p1 = param1_at(math.floor(x + 0.5), math.floor(y + 0.5),
				math.floor(z + 0.5))
		if not p1 then
			return nil
		end
		local day = p1 % 16
		local night = math.floor(p1 / 16)
		local sky = (day > night and day - night or 0) / 15
		local lamp = night / 15
		-- A floor of a few percent, so that something in the pitch dark is a
		-- silhouette rather than nothing at all
		if pbr then
			local amb = zone.ambientColor
			local sun = object_sun
			local sr, sg, sb = 0, 0, 0
			if sun then
				sr = sun.r * sun.a * OBJECT_SUN
				sg = sun.g * sun.a * OBJECT_SUN
				sb = sun.b * sun.a * OBJECT_SUN
			end
			-- Not clipped at one: the frame is tone mapped and a voxel in
			-- the sun is well past it, so an object beside one has to be able
			-- to be as well
			return magic.Color(
					(amb.r + sr) * sky + lamp + OBJECT_DARK_FLOOR,
					(amb.g + sg) * sky + lamp + OBJECT_DARK_FLOOR,
					(amb.b + sb) * sky + lamp + OBJECT_DARK_FLOOR)
		end
		local sun = sunlight_color(daylight)
		return magic.Color(
				math.min(1, sun.r * sky + lamp + 0.03),
				math.min(1, sun.g * sky + lamp + 0.03),
				math.min(1, sun.b * sky + lamp + 0.03))
	end

	-- Setting a shader parameter costs a sandbox call, and there are a
	-- hundred objects: only a step the eye can see is worth one.
	local function light_object(entry, x, y, z)
		if not entry.material and not entry.materials then
			return
		end
		local c = object_color(x, y, z)
		if not c then
			return
		end
		local key = math.floor(c.r * 32)..","..math.floor(c.g * 32)..","..
				math.floor(c.b * 32)
		if key == entry.light_key then
			return
		end
		entry.light_key = key
		if entry.materials then
			-- A cube of tiles has one material per face
			for _, material in ipairs(entry.materials) do
				material:SetShaderParameter("MatDiffColor", c)
			end
			return
		end
		entry.material:SetShaderParameter("MatDiffColor", c)
	end

	-- The visuals drawn as a flat picture turned to the camera rather than
	-- as a box: Luanti's sprite, and the two an item entity uses. A dropped
	-- item's picture is the one an inventory draws for it, which for a node
	-- is already the little isometric cube -- the same picture Luanti's
	-- wielditem comes out as.
	--
	-- simplified: upright_sprite is in here too, where Luanti turns it with
	-- the object's own yaw rather than to the camera.
	local SPRITE_VISUALS = {
		sprite = true,
		upright_sprite = true,
		item = true,
		wielditem = true,
	}

	-- The six faces of a unit cube, each as two triangles with the tile's
	-- own image on it: what a dropped node looks like in Luanti, where it is
	-- a small cube of the node's tiles turning on the spot. The order is
	-- Luanti's tile order -- +Y, -Y, +X, -X, +Z, -Z -- and each face is
	-- given as its four corners in the order the uv corners go, so the
	-- picture comes out the right way up.
	local CUBE_FACES = {
		{{-0.5, 0.5, -0.5}, {0.5, 0.5, -0.5}, {0.5, 0.5, 0.5},
				{-0.5, 0.5, 0.5}},
		{{-0.5, -0.5, 0.5}, {0.5, -0.5, 0.5}, {0.5, -0.5, -0.5},
				{-0.5, -0.5, -0.5}},
		{{0.5, 0.5, 0.5}, {0.5, 0.5, -0.5}, {0.5, -0.5, -0.5},
				{0.5, -0.5, 0.5}},
		{{-0.5, 0.5, -0.5}, {-0.5, 0.5, 0.5}, {-0.5, -0.5, 0.5},
				{-0.5, -0.5, -0.5}},
		{{0.5, 0.5, 0.5}, {-0.5, 0.5, 0.5}, {-0.5, -0.5, 0.5},
				{0.5, -0.5, 0.5}},
		{{-0.5, 0.5, -0.5}, {0.5, 0.5, -0.5}, {0.5, -0.5, -0.5},
				{-0.5, -0.5, -0.5}},
	}
	local CUBE_UV = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}

	-- One geometry per face, so each can wear its own tile. The materials
	-- are handed to the component and nothing else holds them, which is what
	-- keeps them alive; see the crack above.
	local function build_item_cube(node, tiles)
		local cg = node:CreateComponent("CustomGeometry")
		cg:SetNumGeometries(6)
		for face = 1, 6 do
			cg:BeginGeometry(face - 1, magic.TRIANGLE_LIST)
			local corners = CUBE_FACES[face]
			-- Both windings, so which way round a face was given does not
			-- decide whether it is drawn: the frame outline above does the
			-- same thing for the same reason
			for _, i in ipairs({1, 2, 3, 1, 3, 4, 1, 3, 2, 1, 4, 3}) do
				local p = corners[i]
				cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
				cg:DefineTexCoord(magic.Vector2(CUBE_UV[i][1],
						CUBE_UV[i][2]))
			end
		end
		cg:Commit()
		cg.castShadows = false
		local materials = {}
		for face = 1, 6 do
			local material = magic.Material.new()
			material:SetTechnique(0, object_technique)
			material:SetTexture(0, game_texture(
					tiles[face] or tiles[1] or texture))
			cg:SetMaterial(face - 1, material)
			materials[face] = material
		end
		return cg, materials
	end

	-- An object drawn as its own model: the quads objmesh or b3dmesh read,
	-- one geometry per material so that each wears the texture the object
	-- gave for that material. Both windings, like the item cube above, for
	-- the same reason: a model's winding is not something to rely on.
	local function build_object_mesh(node, quads, tiles)
		local by_group = {}
		local order = {}
		for _, q in ipairs(quads) do
			local g = q.group or 1
			if not by_group[g] then
				by_group[g] = {}
				order[#order + 1] = g
			end
			local into = by_group[g]
			into[#into + 1] = q
		end
		table.sort(order)
		local cg = node:CreateComponent("CustomGeometry")
		cg:SetNumGeometries(#order)
		for i = 1, #order do
			cg:BeginGeometry(i - 1, magic.TRIANGLE_LIST)
			for _, q in ipairs(by_group[order[i]]) do
				for _, c in ipairs({1, 2, 3, 1, 3, 4, 1, 3, 2, 1, 4, 3}) do
					local o = (c - 1) * 3
					cg:DefineVertex(magic.Vector3(q.p[o + 1], q.p[o + 2],
							q.p[o + 3]))
					cg:DefineTexCoord(magic.Vector2(q.uv[(c - 1) * 2 + 1],
							q.uv[(c - 1) * 2 + 2]))
				end
			end
		end
		cg:Commit()
		cg.castShadows = false
		local materials = {}
		for i = 1, #order do
			local material = magic.Material.new()
			material:SetTechnique(0, object_technique)
			material:SetTexture(0, game_texture(
					tiles[order[i]] or tiles[1] or texture))
			cg:SetMaterial(i - 1, material)
			materials[i] = material
		end
		return cg, materials
	end

	-- The template node of one kind of object mesh: mesh name and textures
	-- -> a node that is not drawn, holding the geometry and its materials.
	--
	-- Every vertex of an object's mesh is a sandbox call
	-- (CustomGeometry:DefineVertex), which for a mob of a few thousand quads
	-- is a quarter of a second -- measured on VoxeLibre: a skeleton took 250
	-- ms, and every skeleton in the world paid it again. So the first of a
	-- kind is built once and the rest are clones of it, which Urho3D copies
	-- inside the engine. The materials are shared with the template, which
	-- is also what keeps them alive: a Material made in Lua lives only while
	-- something in the engine holds it.
	local object_templates = {}

	local function object_template(mesh)
		local key = (mesh.name or "?").."|"..
				table.concat(mesh.tiles or {}, "|")
		local entry = object_templates[key]
		if not entry then
			local node = scene:CreateChild("object_template")
			node.enabled = false
			local cg, materials = build_object_mesh(node, mesh.quads,
					mesh.tiles)
			entry = {node = node, materials = materials}
			object_templates[key] = entry
		end
		return entry
	end

	-- What an object is drawn as.
	--
	-- simplified: an object whose visual is a mesh this can read is drawn as
	-- that mesh in its rest pose -- BONE, KEYS and ANIM are not read, so a
	-- mob stands still -- a sprite visual is a billboard, and everything
	-- else is a box with the object's first texture on it. A box wearing a
	-- cow's texture reads as a cow where nothing at all reads as nothing at
	-- all, which is what the models Urho3D cannot read fall back to.
	--
	-- obj is what objects.lua parsed; resource(obj) says what it is drawn
	-- wearing, as a resource name, or nil for an object whose texture is not
	-- there yet, and as the six tiles of a node or the quads of a model when
	-- it is one of those.
	function self:set_object(obj, resource)
		local props = obj.props
		-- An item that is a node comes back with the six tiles it is drawn
		-- with as well; then it is a small cube of them rather than a
		-- picture of one
		local own, tiles, mesh = resource(obj)
		local cube = tiles ~= nil
		local meshed = not cube and mesh ~= nil
		local sprite = not cube and not meshed and props ~= nil and
				SPRITE_VISUALS[props.visual] or false
		local entry = object_nodes[obj.id]
		-- A visual that changed changes which component draws it
		if entry and (entry.sprite ~= sprite or entry.cube ~= cube or
				entry.meshed ~= meshed) then
			scene:RemoveChild(entry.node)
			entry = nil
			object_nodes[obj.id] = nil
		end
		if not entry then
			-- A mesh is a copy of its kind's template, which carries the
			-- geometry and the materials already; everything else is built
			-- on a node of its own
			local template = meshed and object_template(mesh) or nil
			local node = template and template.node:Clone() or
					scene:CreateChild("object_"..obj.id)
			entry = {node = node, sprite = sprite, cube = cube,
					meshed = meshed}
			if template then
				node.enabled = true
				entry.textured = true
				entry.materials = template.materials
				entry.model = node:GetComponent("CustomGeometry")
				-- The clone's own materials: a Material made in Lua has no
				-- resource name, so it is not an attribute Urho3D can copy
				for i = 1, #template.materials do
					entry.model:SetMaterial(i - 1, template.materials[i])
				end
			elseif cube then
				entry.model, entry.materials = build_item_cube(node, tiles)
				entry.textured = true
			elseif sprite then
				local set = node:CreateComponent("BillboardSet")
				set.numBillboards = 1
				-- Turned about Y only: a sprite that also leans back when
				-- the camera looks down does not read as standing in the
				-- world
				set.faceCameraMode = magic.FC_ROTATE_Y
				set.castShadows = false
				set.sorted = true
				local billboard = set:GetBillboard(0)
				billboard.position = magic.Vector3(0, 0, 0)
				billboard.enabled = true
				set:Commit()
				entry.model = set
				entry.billboard = billboard
			else
				local model = node:CreateComponent("StaticModel")
				model:SetModel(box_model)
				model.castShadows = false
				entry.model = model
			end
			object_nodes[obj.id] = entry
		end
		-- Where it is and how big: the object's collision box, which is in
		-- nodes and is not centred on the object's own position
		local sx, sy, sz = 0.6, 1.8, 0.6
		local cy = 0.9
		if props and props.collision_min and props.collision_max then
			sx = math.max(0.05, props.collision_max[1] - props.collision_min[1])
			sy = math.max(0.05, props.collision_max[2] - props.collision_min[2])
			sz = math.max(0.05, props.collision_max[3] - props.collision_min[3])
			cy = (props.collision_max[2] + props.collision_min[2]) / 2
		end
		entry.offset = cy
		if cube then
			-- Drawn at the size the object asked for rather than at what
			-- it collides with, the same as a sprite. visual_size is what
			-- Luanti scales the item mesh by, and a dropped node comes out
			-- at about a third of a node, which is what its 0.4 is.
			--
			-- simplified: Luanti's own chain to a final size runs through
			-- the wield mesh's own scale factors; this takes visual_size as
			-- it is, which lands in the same place for a dropped node.
			local v = props and props.visual_size or nil
			entry.node.scale = magic.Vector3(
					math.max(0.05, v and v[1] or 1),
					math.max(0.05, v and v[2] or 1),
					math.max(0.05, v and v[3] or v and v[1] or 1))
			-- How fast it turns, in degrees a second; automatic_rotate is
			-- radians a second
			entry.spin = (props and props.automatic_rotate or 0) *
					180 / math.pi
		elseif meshed then
			-- A model is drawn at the size the object asked for, the same as
			-- a sprite: what it collides with is not what it looks like.
			--
			-- An object's model is authored in Luanti's own scene units,
			-- where a node is ten across, and visual_size scales it in those.
			-- Everything here is in nodes, so the tenth is the conversion. A
			-- node's "mesh" drawtype is the other way round -- authored one
			-- unit to the node -- which is why shapes.lua does not do this.
			local v = props and props.visual_size or nil
			local to_nodes = 1 / 10
			entry.node.scale = magic.Vector3(
					math.max(0.005, (v and v[1] or 1) * to_nodes),
					math.max(0.005, (v and v[2] or 1) * to_nodes),
					math.max(0.005, (v and v[3] or v and v[1] or 1) *
							to_nodes))
		elseif sprite then
			-- A billboard is sized by itself, and by what the object asked
			-- for rather than by what it collides with: a dropped item's
			-- collision box is a whole node and its picture is not
			local w = props.visual_size and props.visual_size[1] or 1
			local h = props.visual_size and props.visual_size[2] or 1
			entry.node.scale = magic.Vector3(1, 1, 1)
			entry.billboard.size = magic.Vector2(math.max(0.05, w) / 2,
					math.max(0.05, h) / 2)
			entry.model:Commit()
		else
			entry.node.scale = magic.Vector3(sx, sy, sz)
		end
		entry.node.position = magic.Vector3(obj.position[1],
				obj.position[2] + cy, obj.position[3])
		entry.at_x, entry.at_y, entry.at_z = obj.position[1], obj.position[2],
				obj.position[3]
		-- A cube of its own is turned by its spin below and by nothing else
		if not entry.spin or entry.spin == 0 then
			entry.node.rotation = magic.Quaternion(0, -(obj.yaw or 0), 0)
			entry.at_yaw = obj.yaw or 0
		end
		entry.lit_at = daylight
		light_object(entry, obj.position[1], obj.position[2], obj.position[3])

		-- Cleared whatever the object is drawn as: a cube's tiles go on
		-- once, and a flag left set would rebuild it every frame
		local was_stale = obj.visual_stale
		obj.visual_stale = false
		if not cube and not meshed and (was_stale or not entry.textured) then
			-- An object whose texture is not there yet wears the placeholder
			-- rather than nothing: a box with no material at all is drawn
			-- flat white, which reads as a hole in the world
			local name = own or (not entry.material and texture)
			if name then
				local material = magic.Material.new()
				material:SetTechnique(0, object_technique)
				material:SetTexture(0, game_texture(name))
				entry.model.material = material
				entry.material = material
				entry.light_key = nil
				-- The placeholder does not count as textured: the object's
				-- own texture may still turn up
				entry.textured = own ~= nil
			end
		end
	end

	-- The particle emitters in the scene: the spawners by the id the server
	-- deletes them by, and the single particles, each of which is an emitter
	-- of one that fires once.
	local particle_nodes = {}
	local single_particles = {}
	-- Enough for a game's digging and footsteps at once. A batch beyond this
	-- is dropped rather than queued: a particle that turns up late is worse
	-- than one that does not turn up.
	local SINGLE_PARTICLE_MAX = 128

	-- The spawners that have been taken away and whose particles are living
	-- out their lives; see set_particle_spawner(). Each holds an emitter's
	-- pool of billboards, so there is a cap on how many are kept: at the
	-- twenty a second VoxeLibre's rain churns through, this is a second and
	-- a half of drops, which is about how long one takes to fall.
	local dying_spawners = {}
	local DYING_SPAWNERS_MAX = 32

	-- One Urho3D emitter out of one Luanti particle description.
	--
	-- The two do not line up field for field, and this is where they are
	-- made to. Luanti gives, per field, a tween of a range: a start range
	-- and an end range and a way of moving between them over the spawner's
	-- life. Urho3D gives one emitter box, one box of directions, one
	-- constant force and one size range for the whole emitter.
	--
	-- simplified: the tween is dropped -- the starting range is what the
	-- whole spawner runs at -- and so are the bias inside a range, the
	-- collision flags, the glow, the drag, the jitter, the bounce and the
	-- attractors. What that costs is a spawner that grows or shrinks over
	-- its life, and particles that stop at the ground; the upgrade path is
	-- either a manager of this client's own or more of Urho3D's own fields.
	-- Luanti's tile animation on a particle, as Urho3D's texture frames: the
	-- part of the image each frame is, and how many seconds into a
	-- particle's life it is shown from. How many frames a vertical strip
	-- holds comes out of the image's own shape against the aspect the game
	-- gave, which is Luanti's own arithmetic.
	--
	-- Urho3D stops on the last frame rather than looping, so the frames are
	-- laid out again and again until the longest life the particle can have
	-- is covered. The cap is what keeps a one-frame-a-millisecond animation
	-- on a minute-long particle from filling memory.
	local PARTICLE_FRAMES_MAX = 64
	local function particle_frames(effect, tex, animation, ttl)
		if not tex or not animation or animation.type == 0 then
			return
		end
		local frames = {}
		local step = nil
		if animation.type == 1 then
			-- A vertical strip. One frame is as tall as the image is wide,
			-- times the aspect the game asked for.
			local aspect_w = animation.aspect_w or 1
			local aspect_h = animation.aspect_h or 1
			local frame_h = tex.width / aspect_w * aspect_h
			local count = frame_h > 0 and
					math.floor(tex.height / frame_h + 0.5) or 1
			if count < 2 then
				return
			end
			for i = 0, count - 1 do
				frames[#frames + 1] = {0, i / count, 1, (i + 1) / count}
			end
			-- Luanti's length is the whole animation
			step = (animation.length or 1) / count
		elseif animation.type == 2 then
			-- A sheet, left to right and then down, which is the order
			-- Luanti numbers its frames in
			local across = math.max(1, animation.frames_w or 1)
			local down = math.max(1, animation.frames_h or 1)
			if across * down < 2 then
				return
			end
			for y = 0, down - 1 do
				for x = 0, across - 1 do
					frames[#frames + 1] = {x / across, y / down,
							(x + 1) / across, (y + 1) / down}
				end
			end
			-- And here it is the length of one frame
			step = animation.length or 0.1
		end
		if not step or step <= 0 then
			return
		end
		local at = 0
		local i = 1
		local added = 0
		while at < ttl and added < PARTICLE_FRAMES_MAX do
			local f = frames[i]
			effect:AddTextureTime(magic.Rect(f[1], f[2], f[3], f[4]), at)
			at = at + step
			i = i % #frames + 1
			added = added + 1
		end
	end

	-- A particle's size crosses the wire in Luanti's scene units, where a
	-- node is ten across; everything here is in nodes
	local PARTICLE_SIZE_TO_NODES = 1 / 10

	-- The effect is handed to the emitter by the caller, once it has set the
	-- fields that differ between a spawner and a single particle: assigning
	-- the same effect twice is a no-op in Urho3D, so everything has to be on
	-- it before it goes on.
	local function particle_effect(texture_name, amount, ttl_min,
			ttl_max, size_min, size_max, vel_min, vel_max, acc, active_time,
			animation)
		local effect = magic.ParticleEffect.new()
		local material = magic.Material.new()
		local tex = game_texture(texture_name, magic.FILTER_NEAREST_ANISOTROPIC)
		material:SetTechnique(0, particle_technique)
		material:SetTexture(0, tex)
		effect.material = material
		effect.numParticles = amount
		effect.relative = false
		effect.scaled = true
		effect.sorted = true
		-- A fresh emitter is not in view until it has a particle in it, and
		-- Urho3D does not update an emitter that is out of view: without
		-- this the first particle is never emitted and nothing is ever seen
		effect.updateInvisible = true
		-- White, and only white: a particle with no colour frame at all
		-- comes out as one anyway, but saying so is what keeps it that way
		effect:AddColorTime(magic.Color(1, 1, 1, 1), 0)
		particle_frames(effect, tex, animation, ttl_max)
		effect.minTimeToLive = ttl_min
		effect.maxTimeToLive = ttl_max
		-- Luanti's size is the whole particle across, in the scene units its
		-- own client draws in -- ten to the node, the same as an object's
		-- visual_size -- and a billboard's is half of one side. So a rain
		-- drop's size of 4 is four tenths of a node, not four nodes.
		local half = PARTICLE_SIZE_TO_NODES / 2
		effect:SetMinParticleSize(magic.Vector2(size_min * half,
				size_min * half))
		effect:SetMaxParticleSize(magic.Vector2(size_max * half,
				size_max * half))
		-- The velocity: the box the direction is picked from, and the speeds
		-- that box holds. Without the speeds every particle leaves at one
		-- node a second whatever the game asked for, which reads as all of
		-- them flying away from wherever they started.
		effect:SetMinDirection(magic.Vector3(vel_min[1], vel_min[2],
				vel_min[3]))
		effect:SetMaxDirection(magic.Vector3(vel_max[1], vel_max[2],
				vel_max[3]))
		local near, far = particles.speed_range(vel_min, vel_max)
		effect.minVelocity = near
		effect.maxVelocity = far
		effect:SetConstantForce(magic.Vector3(acc[1], acc[2], acc[3]))
		effect.dampingForce = 0
		-- An active time with no inactive time after it is one burst and
		-- then nothing, which is what a spawner with a time and a single
		-- particle both are. Zero active time never stops, which is what a
		-- spawner with no time is.
		effect.activeTime = active_time
		effect.inactiveTime = 0
		return effect, material
	end

	-- set_particle_spawner(id, p, resolve): p nil takes the spawner away,
	-- which is what DELETE_PARTICLESPAWNER does. resolve(name) turns a
	-- texture string into a resource name, or nil for one that has not
	-- arrived.
	--
	-- What makes two spawners the same spawner: everything about them that
	-- this draws. A game that takes its spawner away and adds it again --
	-- VoxeLibre's weather does, twenty times a second -- gets the emitter it
	-- had back rather than a new one, which is what keeps its rain falling
	-- in a stream instead of in fifty-millisecond bursts.
	local function spawner_signature(p, texture_name)
		local n = {texture_name, p.amount, p.time, p.attached,
				p.vertical and 1 or 0}
		for _, range in ipairs({p.pos.start, p.vel.start, p.acc.start}) do
			for i = 1, 3 do
				n[#n + 1] = string.format("%g", range.min[i])
				n[#n + 1] = string.format("%g", range.max[i])
			end
		end
		for _, range in ipairs({p.exptime.start, p.size.start}) do
			n[#n + 1] = string.format("%g", range.min)
			n[#n + 1] = string.format("%g", range.max)
		end
		return table.concat(n, "/")
	end

	-- A spawner attached to an object has its positions relative to that
	-- object and follows it, which is what update_particles() moves; the
	-- weather of a game is a spawner attached to the player.
	function self:set_particle_spawner(id, p, resolve)
		local old = particle_nodes[id]
		if old then
			-- The particles a spawner has already made outlive it, which is
			-- what Luanti does: its own particles are not owned by the
			-- spawner that made them. It matters more than it sounds --
			-- VoxeLibre's weather takes its rain spawner away and adds it
			-- again twenty times a second, so a client that drops the
			-- particles with the spawner erases its own rain fifty
			-- milliseconds after making it, which is why the sky was empty.
			-- So the emitter stops emitting and the node goes when the last
			-- particle it made has expired.
			if old.emitter then
				old.emitter.emitting = false
			end
			old.life = (old.ttl_max or 0) + 0.2
			old.attached = nil
			dying_spawners[#dying_spawners + 1] = old
			-- A cap, because each of these holds a pool of billboards: the
			-- oldest goes, which is the one whose particles are nearest the
			-- end of their lives anyway
			while #dying_spawners > DYING_SPAWNERS_MAX do
				scene:RemoveChild(table.remove(dying_spawners, 1).node)
			end
			particle_nodes[id] = nil
		end
		if p == nil then
			return
		end
		local texture_name = p.texture ~= "" and resolve(p.texture) or nil
		if not texture_name then
			return
		end
		local pos = particles.middle(p.pos.start)
		local size = p.size.start
		local exptime = p.exptime.start
		-- The same spawner as one that was taken away a moment ago: pick its
		-- emitter back up where it left off
		local signature = spawner_signature(p, texture_name)
		for i, e in ipairs(dying_spawners) do
			if e.signature == signature then
				table.remove(dying_spawners, i)
				if e.emitter then
					e.emitter.emitting = true
				end
				e.life = p.time > 0 and
						(p.time + math.max(0.01, exptime.max) + 0.5) or nil
				e.attached = p.attached ~= 0 and p.attached or nil
				e.offset = pos
				e.at_x, e.at_y, e.at_z = nil, nil, nil
				particle_nodes[id] = e
				return
			end
		end
		local node = scene:CreateChild("particles_"..id)
		node.position = magic.Vector3(pos[1], pos[2], pos[3])
		local amount = math.max(1, math.min(p.amount, 1000))
		local effect, material = particle_effect(texture_name,
				amount, math.max(0.01, exptime.min),
				math.max(0.01, exptime.max),
				math.max(0.001, size.min), math.max(0.001, size.max),
				p.vel.start.min, p.vel.start.max,
				particles.middle(p.acc.start), p.time, p.animation)
		-- What the emitter box is: the position range, which the node sits
		-- in the middle of
		effect.emitterType = 1 -- EMITTER_BOX
		effect:SetEmitterSize(magic.Vector3(
				math.max(0, p.pos.start.max[1] - p.pos.start.min[1]),
				math.max(0, p.pos.start.max[2] - p.pos.start.min[2]),
				math.max(0, p.pos.start.max[3] - p.pos.start.min[3])))
		-- Luanti spawns amount particles over time seconds, and amount a
		-- second when there is no time at all
		local rate = p.time > 0 and amount / p.time or amount
		effect.minEmissionRate = rate
		effect.maxEmissionRate = rate
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		-- Luanti's `vertical` particle is an upright quad turned to the
		-- player about Y rather than one facing the camera, which is what
		-- makes a rain drop look like a falling drop rather than a blob
		if p.vertical then
			emitter.faceCameraMode = magic.FC_ROTATE_Y
		end
		-- A spawner that ends takes itself away once the last particle it
		-- made has expired; one with no time waits for the server
		local life = nil
		if p.time > 0 then
			life = p.time + exptime.max + 0.5
		end
		-- Attached to an object: the position read above is an offset from
		-- where that object is, and update_particles() keeps up with it
		local attached = p.attached ~= nil and p.attached ~= 0 and
				p.attached or nil
		-- The effect and its material are kept here for as long as the
		-- emitter is: both were made in Lua, and a Lua-made Urho3D object is
		-- destroyed when the last Lua reference to it goes, whatever the
		-- engine still holds. An emitter whose effect has been collected
		-- reads freed memory: on this one it came out as Urho3D's defaults,
		-- so every particle flew off in a random direction at the default
		-- size instead of falling, which is what made rain invisible.
		particle_nodes[id] = {node = node, life = life, attached = attached,
				offset = pos, emitter = emitter, signature = signature,
				effect = effect, material = material,
				ttl_max = math.max(0.01, exptime.max)}
	end

	-- One particle the server picked itself: an emitter of one that fires
	-- once and is taken away when it has expired.
	function self:add_particle(p, resolve)
		if #single_particles >= SINGLE_PARTICLE_MAX then
			return
		end
		local texture_name = p.texture ~= "" and resolve(p.texture) or nil
		if not texture_name then
			return
		end
		local ttl = math.max(0.01, p.exptime)
		local node = scene:CreateChild("particle")
		node.position = magic.Vector3(p.pos[1], p.pos[2], p.pos[3])
		local effect, material = particle_effect(texture_name, 1,
				ttl, ttl, math.max(0.001, p.size), math.max(0.001, p.size),
				p.vel, p.vel, p.acc, 0.05, p.animation)
		effect.emitterType = 0 -- EMITTER_SPHERE, of no size
		effect:SetEmitterSize(magic.Vector3(0, 0, 0))
		effect.minEmissionRate = 100
		effect.maxEmissionRate = 100
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		-- The effect and the material live as long as the emitter does; see
		-- set_particle_spawner()
		single_particles[#single_particles + 1] =
				{node = node, life = ttl + 0.5, effect = effect,
				material = material}
	end

	-- Ages the emitters and takes away the ones that are done with. A
	-- spawner with no time of its own is not aged: the server deletes it.
	-- objects is what the client has parsed, keyed by object id, so that a
	-- spawner attached to one can be moved to where that one is now; it may
	-- be nil for a caller that has none.
	function self:update_particles(dtime, objects)
		for id, entry in pairs(particle_nodes) do
			if entry.attached then
				local obj = objects and objects[entry.attached] or nil
				local x, y, z = nil, nil, nil
				if obj and obj.is_self then
					-- The player's own object: the server sends no position
					-- for it, and where the player is is where the camera is
					local p = camera_node.position
					x, y, z = p.x, p.y, p.z
				elseif obj and obj.position then
					x, y, z = obj.position[1], obj.position[2],
							obj.position[3]
				end
				if not x and not entry.said_missing then
					-- A spawner whose object the client does not know draws
					-- where the offset alone puts it, which is somewhere
					-- around the world's origin: worth one line rather than
					-- being a mystery
					entry.said_missing = true
					log:warning("particles: spawner "..tostring(id)..
							" is attached to object "..
							tostring(entry.attached)..
							", which is not one this client has")
				end
				if x and (x ~= entry.at_x or y ~= entry.at_y or
						z ~= entry.at_z) then
					entry.at_x, entry.at_y, entry.at_z = x, y, z
					entry.node.position = magic.Vector3(
							x + entry.offset[1], y + entry.offset[2],
							z + entry.offset[3])
				end
			end
			if entry.life then
				entry.life = entry.life - dtime
				if entry.life <= 0 then
					scene:RemoveChild(entry.node)
					particle_nodes[id] = nil
				end
			end
		end
		local d = 1
		while d <= #dying_spawners do
			local entry = dying_spawners[d]
			entry.life = entry.life - dtime
			if entry.life <= 0 then
				scene:RemoveChild(entry.node)
				table.remove(dying_spawners, d)
			else
				d = d + 1
			end
		end
		local i = 1
		while i <= #single_particles do
			local entry = single_particles[i]
			entry.life = entry.life - dtime
			if entry.life <= 0 then
				scene:RemoveChild(entry.node)
				table.remove(single_particles, i)
			else
				i = i + 1
			end
		end
	end

	-- For the counters line
	function self:particle_count()
		local n = #single_particles + #dying_spawners
		for _, _ in pairs(particle_nodes) do
			n = n + 1
		end
		return n
	end

	function self:remove_object(id)
		local entry = object_nodes[id]
		if entry then
			scene:RemoveChild(entry.node)
			object_nodes[id] = nil
		end
	end

	-- Moves the objects' scene nodes to where they are now
	-- Where every object is, once a frame.
	--
	-- Each of these writes is a sandbox call and there are a hundred objects,
	-- which is milliseconds a frame if they all get written; most of them are
	-- standing still at any one time, so what has not moved is left alone.
	-- The light an object is drawn in only changes when it moves or when the
	-- day does.
	function self:place_objects(objects, dtime)
		for id, obj in pairs(objects) do
			local entry = object_nodes[id]
			if entry and obj.position then
				local x = obj.position[1]
				local y = obj.position[2]
				local z = obj.position[3]
				local yaw = obj.yaw or 0
				if x ~= entry.at_x or y ~= entry.at_y or z ~= entry.at_z then
					entry.at_x, entry.at_y, entry.at_z = x, y, z
					entry.node.position = magic.Vector3(x,
							y + (entry.offset or 0), z)
					entry.lit_at = nil
				end
				if entry.spin and entry.spin ~= 0 and dtime then
					-- A dropped node turns on the spot; the server sends no
					-- yaw for it, so this is the only thing that moves it
					entry.at_yaw = (entry.at_yaw or 0) +
							entry.spin * dtime
					entry.node.rotation = magic.Quaternion(0,
							entry.at_yaw % 360, 0)
				elseif yaw ~= entry.at_yaw then
					entry.at_yaw = yaw
					entry.node.rotation = magic.Quaternion(0, -yaw, 0)
				end
				if entry.lit_at ~= daylight then
					entry.lit_at = daylight
					light_object(entry, x, y, z)
				end
			end
		end
	end

	function self:object_count()
		local n = 0
		for _, _ in pairs(object_nodes) do
			n = n + 1
		end
		return n
	end

	-- Shows the outline on a node, or hides it when there is nothing pointed
	-- at. above is which way the face points.
	-- Which voxel the frame is around. above is which side of it the ray
	-- came in through, which the frame does not care about any more; it is
	-- still taken so that "nothing is pointed at" is one call.
	-- The box to outline when a node is pointed at, in the node's own
	-- -0.5...0.5 coordinates as {x0, y0, z0, x1, y1, z1}, or nil for a node
	-- that is outlined as a whole voxel.
	--
	-- simplified: a node whose selection is several boxes -- a fence with its
	-- rails, a plant with its stem -- gets the one box around all of them,
	-- where Luanti draws each of them.
	function self:selection_at(x, y, z)
		local id = self:node_at(x, y, z)
		local entry = id and self.node_selection and self.node_selection[id]
		if not entry then
			return nil
		end
		local boxes = entry.boxes
		-- The boxes turn with the voxel, the same way its shape does
		local facedir = entry.facing and shapes.facedir_of(
				entry.facing, param2_at(x, y, z)) or nil
		if facedir and facedir ~= 0 then
			entry.turned = entry.turned or {}
			if not entry.turned[facedir] then
				entry.turned[facedir] = turn_boxes(entry.boxes, facedir)
			end
			boxes = entry.turned[facedir]
		end
		local out = {boxes[1][1], boxes[1][2], boxes[1][3],
				boxes[1][4], boxes[1][5], boxes[1][6]}
		for i = 2, #boxes do
			local b = boxes[i]
			for k = 1, 3 do
				if b[k] < out[k] then out[k] = b[k] end
				if b[k + 3] > out[k + 3] then out[k + 3] = b[k + 3] end
			end
		end
		return out
	end

	function self:set_pointed(under, above)
		if not under or not above then
			pointed_node.enabled = false
			return
		end
		local box = self:selection_at(under[1], under[2], under[3])
		if box then
			self:set_pointed_box(
					{under[1] + box[1], under[2] + box[2], under[3] + box[3]},
					{under[1] + box[4], under[2] + box[5], under[3] + box[6]})
			return
		end
		pointed_node.scale = magic.Vector3(1, 1, 1)
		pointed_node.position = magic.Vector3(under[1], under[2], under[3])
		pointed_node.enabled = true
	end

	-- The same outline around an arbitrary box, given in world coordinates,
	-- which is what a pointed object wants.
	--
	-- simplified: the frame is the voxel one scaled, so its bars are
	-- thicker on a big box and thinner on a small one.
	function self:set_pointed_box(min, max)
		if not min or not max then
			pointed_node.enabled = false
			return
		end
		local sx = math.max(0.05, max[1] - min[1])
		local sy = math.max(0.05, max[2] - min[2])
		local sz = math.max(0.05, max[3] - min[3])
		pointed_node.scale = magic.Vector3(sx, sy, sz)
		pointed_node.position = magic.Vector3((min[1] + max[1]) / 2,
				(min[2] + max[2]) / 2, (min[3] + max[3]) / 2)
		pointed_node.enabled = true
	end

	-- The blocks whose light a node change may have moved, waiting to be
	-- asked for again; see set_node() below and refresh_wanted().
	local refresh = {}
	-- Where the camera is, for deciding which of those are worth asking for
	local camera_at = nil
	-- How far away a block can be and still be worth a resend, in blocks.
	-- Asking for a block again costs the server a send, and on a busy server
	-- other players' digging is a constant stream of node changes: what is
	-- gained is the light of what the player is looking at, and beyond a few
	-- blocks that is not worth taking sends away from the map that has not
	-- arrived yet.
	local REFRESH_RANGE_BLOCKS = 3
	-- And a cap on how many are ever waiting. A storm of changes -- a
	-- thousand nodes at once, which a game's own bulk edits do -- leaves the
	-- light stale rather than the world unsent.
	local REFRESH_MAX = 24

	-- Whether a node changing from one id to another can move the light
	-- around it: only a change in what a node gives or in what it lets
	-- through can. A rail replaced by air is neither.
	local function light_changed(from, to)
		if from == to then
			return false
		end
		local lights = self.node_light or {}
		local through = self.node_light_through or {}
		local from_light = lights[from] and lights[from].level or 0
		local to_light = lights[to] and lights[to].level or 0
		if from_light ~= to_light then
			return true
		end
		-- A node the definitions do not cover is drawn as a placeholder
		-- cube, which is what it blocks light as
		local from_through = through[from]
		local to_through = through[to]
		if from_through == nil then from_through = false end
		if to_through == nil then to_through = false end
		return from_through ~= to_through
	end

	-- The light around a node change, worked out here rather than asked for
	-- again; light.lua is the algorithm and this is what it reads and
	-- writes. The writes are held until the flood is done and then go into
	-- each block in one pass, because a block's param1 is a string and
	-- rebuilding it once per node would be thousands of copies of four
	-- kilobytes. The reads see the writes, so the flood sees its own work.
	local light_writes = {}
	local light_dirty = {}

	local function light_index(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		return block_key(bx, by, bz),
				(x - bx * BLOCKSIZE) +
				(y - by * BLOCKSIZE) * BLOCKSIZE +
				(z - bz * BLOCKSIZE) * BLOCKSIZE * BLOCKSIZE,
				bx, by, bz
	end

	local light_access = {
		node = function(x, y, z)
			return self:node_at(x, y, z)
		end,
		light = function(x, y, z)
			local key, i = light_index(x, y, z)
			local writes = light_writes[key]
			local p = writes and writes[i]
			if p == nil then
				p = param1_at(x, y, z)
			end
			if p == nil then
				return nil
			end
			return p % 16, math.floor(p / 16)
		end,
		set_light = function(x, y, z, day, night)
			local key, i, bx, by, bz = light_index(x, y, z)
			if not blocks[key] then
				return
			end
			local writes = light_writes[key]
			if not writes then
				writes = {}
				light_writes[key] = writes
			end
			writes[i] = (day % 16) + (night % 16) * 16
			light_dirty[key] = true
			-- A node on a block's edge is in the neighbour's border, so
			-- that mesh is out of date as well
			local lx = x - bx * BLOCKSIZE
			local ly = y - by * BLOCKSIZE
			local lz = z - bz * BLOCKSIZE
			for _, d in ipairs(NEIGHBOURS) do
				if (d[1] < 0 and lx == 0) or
						(d[1] > 0 and lx == BLOCKSIZE - 1) or
						(d[2] < 0 and ly == 0) or
						(d[2] > 0 and ly == BLOCKSIZE - 1) or
						(d[3] < 0 and lz == 0) or
						(d[3] > 0 and lz == BLOCKSIZE - 1) then
					light_dirty[block_key(bx + d[1], by + d[2],
							bz + d[3])] = true
				end
			end
		end,
		source = function(id)
			local entry = self.node_light and self.node_light[id]
			return entry and entry.level or 0
		end,
		through = function(id)
			return (self.node_light_through or {})[id] == true
		end,
		sun_through = function(id)
			return (self.node_sun_through or {})[id] == true
		end,
	}

	-- The light of everything around one node that changed. What comes back
	-- is whether anything was left unresolved -- a node in a block we do not
	-- have, or the flood running out of budget -- which is when asking the
	-- server for the block is still worth it.
	local function flood_light(x, y, z, from_id, to_id, old_param1)
		local visited, unresolved = light_flood.update(light_access,
				x, y, z, from_id, to_id,
				old_param1 % 16, math.floor(old_param1 / 16))
		for key, writes in pairs(light_writes) do
			local block = blocks[key]
			if block then
				-- One pass over the string per block: the pieces between
				-- the writes, with the new bytes between them
				local indices = {}
				for i in pairs(writes) do
					indices[#indices + 1] = i
				end
				table.sort(indices)
				local parts = {}
				local last = 0
				for _, i in ipairs(indices) do
					parts[#parts + 1] = block.param1:sub(last + 1, i)
					parts[#parts + 1] = string.char(writes[i])
					last = i + 1
				end
				parts[#parts + 1] = block.param1:sub(last + 1)
				block.param1 = table.concat(parts)
			end
			light_writes[key] = nil
		end
		for key in pairs(light_dirty) do
			if blocks[key] then
				mark_dirty(key)
			end
			light_dirty[key] = nil
		end
		return visited, unresolved
	end

	-- One node the server changed, in node coordinates. Patches the block's
	-- parameter arrays in place; a node on a block's edge is part of the
	-- neighbour's border, so that mesh goes out of date too.
	-- param1 may be nil, which means the node became air and its light has
	-- to be worked out here.
	--
	-- The light of everything *around* the node is worked out here, the way
	-- Luanti's own client works it out: take away the light that came from
	-- what changed and spread what is left back in. See light.lua. What that
	-- cannot finish -- a node in a block we do not have, or a flood that ran
	-- out of budget -- falls back to asking the server for the block again.
	function self:set_node(x, y, z, param0, param1, param2)
		param1 = param1 or removal_light(x, y, z)
		param2 = param2 or 0
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local key = block_key(bx, by, bz)
		local block = blocks[key]
		if not block then
			return false -- Not a block we are drawing
		end
		local lx = x - bx * BLOCKSIZE
		local ly = y - by * BLOCKSIZE
		local lz = z - bz * BLOCKSIZE
		local i = lx + ly * BLOCKSIZE + lz * BLOCKSIZE * BLOCKSIZE
		-- What was there, for the light: see light_changed() and
		-- flood_light() above
		local was = block.param0:byte(i * 2 + 1) * 256 +
				block.param0:byte(i * 2 + 2)
		local was_param1 = block.param1:byte(i + 1) or 0
		block.param0 = block.param0:sub(1, i * 2)..
				string.char(math.floor(param0 / 256) % 256, param0 % 256)..
				block.param0:sub(i * 2 + 3)
		block.param1 = block.param1:sub(1, i)..string.char(param1 % 256)..
				block.param1:sub(i + 2)
		block.lights = nil -- One of its voxels may have been a light
		if block.param2 then
			block.param2 = block.param2:sub(1, i)..
					string.char(param2 % 256)..block.param2:sub(i + 2)
			-- What it looks like may be a pair that has no voxel id yet
			if build_pair then
				local entry = param2_look[param0]
				local key = param0 + (param2 % 256) * PAIR_SCALE
				if entry and self.pair_map[key] == nil then
					build_pair(entry, param0, param2 % 256, key)
				end
			end
		end
		mark_dirty(key)
		for _, d in ipairs(NEIGHBOURS) do
			-- Only the neighbour the node is up against sees it in its border
			if (d[1] < 0 and lx == 0) or (d[1] > 0 and lx == BLOCKSIZE - 1) or
					(d[2] < 0 and ly == 0) or
					(d[2] > 0 and ly == BLOCKSIZE - 1) or
					(d[3] < 0 and lz == 0) or
					(d[3] > 0 and lz == BLOCKSIZE - 1) then
				mark_dirty(block_key(bx + d[1], by + d[2], bz + d[3]))
			end
		end
		if light_changed(was, param0) then
			local visited, unresolved = flood_light(x, y, z, was, param0,
					was_param1)
			self.last_light_visited = visited
			if unresolved then
				-- The flood ran into a block we do not have, or out of
				-- budget: the server's own light is the way out, and it
				-- sends a block again when we say we no longer have it
				local waiting = 0
				for _ in pairs(refresh) do
					waiting = waiting + 1
				end
				if waiting < REFRESH_MAX then
					refresh[key] = {bx, by, bz}
				end
			end
		end
		return true
	end

	-- The blocks to ask the server for again, at most a handful at a time:
	-- one node change can name seven blocks and a spree of them more than a
	-- packet holds. What is left waits for the next call, and what is too
	-- far from the camera is dropped rather than waited for.
	function self:refresh_wanted(limit)
		local out = {}
		local cx, cy, cz = 0, 0, 0
		if camera_at then
			cx = math.floor(camera_at[1] / BLOCKSIZE)
			cy = math.floor(camera_at[2] / BLOCKSIZE)
			cz = math.floor(camera_at[3] / BLOCKSIZE)
		end
		for key, at in pairs(refresh) do
			refresh[key] = nil
			local near = camera_at == nil or
					(math.abs(at[1] - cx) <= REFRESH_RANGE_BLOCKS and
					math.abs(at[2] - cy) <= REFRESH_RANGE_BLOCKS and
					math.abs(at[3] - cz) <= REFRESH_RANGE_BLOCKS)
			if near then
				out[#out + 1] = at
				if #out >= (limit or 8) then
					break
				end
			end
		end
		return out
	end

	-- The colour of the sky, for a day/night factor of 0...1. This is the one
	-- thing that moves the sun: the mesher put how much of the sky each
	-- surface sees into its vertex colours, and the shader multiplies that by
	-- the zone's ambient colour.
	-- Luanti's own default sky colours, from its skyparams.h. A game that
	-- says its own replaces them, and this one does.
	local SKY_DEFAULT = {
		day_sky = {97, 181, 245},
		day_horizon = {144, 211, 246},
		dawn_sky = {180, 186, 250},
		dawn_horizon = {186, 193, 240},
		night_sky = {0, 107, 255},
		night_horizon = {64, 144, 255},
		indoors = {100, 100, 100},
		sun_tint = {244, 125, 29},
	}

	-- Where the sun is, as a direction to it. Luanti's own: the day is
	-- stretched so that the night takes less than half of it
	-- (getWickedTimeOfDay), and then the sun rises towards +X, stands
	-- overhead at noon and sets towards -X.
	local function sun_direction(time_of_day)
		local t = ((time_of_day or 12000) % 24000) / 24000
		local wn = 0.415 / 2
		local w
		if t > wn and t < 1 - wn then
			w = (t - wn) / (1 - wn * 2) * 0.5 + 0.25
		elseif t < 0.5 then
			w = t / wn * 0.25
		else
			w = 1 - (1 - t) / wn * 0.25
		end
		local a = math.rad(w * 360 - 90)
		return math.cos(a), math.sin(a), 0
	end

	-- The sun's own colour at noon. Luanti's sunlight_color() is the colour
	-- of the sun and the sky together, because together is the only way
	-- Luanti has them; on the PBR path the sky is a light of its own, so what
	-- is left for the sun is what the sun is. Only a little warm: what makes
	-- sunlight read as golden is the blue ambient beside it, and a light
	-- warmer than this shows up undisguised in what a glint reflects.
	-- games/voxel_lighting's sun is the same colour.
	local SUN_COLOR = {1.0, 0.96, 0.88}
	-- How much of the horizon's own tint the light takes when the sun is down
	-- among it. Not all of it: sun_tint is the colour a band of sky is
	-- painted, which is deeper than the light that paints it.
	-- How much of the horizon's colour the light takes at the reddest of it.
	-- The window above says when; this says how much, and it is weighted
	-- towards the crossing itself -- squared from the far end -- so that it
	-- comes on gently at the edge of the window and is most of the way there
	-- by the quarter hour. A sun a quarter of an hour off the horizon is
	-- already red, and a share that only rose with the window was still a
	-- warm white there.
	local SUN_TINT_SHARE = 0.9
	-- And how much of the sun's colour the clouds take while it is down
	-- there. More than the light itself takes, because a cloud at dawn is
	-- lit by nothing else and the sun is lighting it from below, where the
	-- ground is lit by the sky as well.
	local CLOUD_SUN_TINT = 0.75
	-- How far past white a cloud in full sun is drawn, and the band of the
	-- game's own cloud colour over which that is given: a white cloud gets
	-- all of it, a rain cloud none, and nothing in between jumps
	-- Enough room to come out white rather than grey, and not so much that a
	-- cloud is as bright as the sun is: the disc is drawn at six times its
	-- colour, and after the tone curve this lands about a tenth under it
	local CLOUD_DAY_GAIN = 1.4
	local CLOUD_WHITE_LOW = 0.5
	local CLOUD_WHITE_HIGH = 0.9

	-- One of the game's colours, or Luanti's default for it, as 0...1
	local function sky_color(name, brightness)
		local c = (sky and sky[name]) or SKY_DEFAULT[name]
		if not c then
			return magic.Color(0, 0, 0)
		end
		local b = brightness or 1
		return magic.Color(c[1] / 255 * b, c[2] / 255 * b, c[3] / 255 * b)
	end

	-- How light it is, from the day/night ratio. Luanti runs the ratio
	-- through its light curve (decode_light_f) to get this; a gamma of 2.2 is
	-- the same shape without the table -- 1 stays 1, the 0.175 the ramp
	-- bottoms out at comes to about 0.02.
	local function brightness_of(factor)
		return factor ^ 2.2
	end

	-- How much of the sun and the moon the clouds keep. A directional light
	-- does not know there is a layer of cloud between it and the ground; the
	-- ambient does, because a game darkens the sky colours it sends when the
	-- weather turns, and only the direct light is left saying it is a clear
	-- day.
	--
	-- Two things say overcast and a game uses one or the other. Density is
	-- how much of the sky is cloud, and 0.4 is what every game gets whether
	-- or not it asks, so only what is above that is weather. The other is the
	-- colour: VoxeLibre never touches the density and says it with the cloud
	-- colour instead, #FFF0F0 for a clear sky against #5D5D5F for rain and
	-- #3D3D3F for a thunderstorm. Reading both is what makes this work on a
	-- game that has not been looked at.
	local CLOUD_DIM = 0.8          -- what a full overcast takes from the sun
	local CLOUD_SHADE_GAIN = 1.3   -- a cloud need not be black to be opaque

	local function cloud_cover_of(density, color_bright)
		-- Whether there is a layer there at all, which is what the colour
		-- has to be weighed by: a black cloud that covers nothing shades
		-- nothing
		local have = clamp01(density / CLOUD_DENSITY_DEFAULT)
		local dense = clamp01((density - CLOUD_DENSITY_DEFAULT) /
				(1 - CLOUD_DENSITY_DEFAULT))
		local shade = 0
		local c = color_bright
		if c then
			local luma = (0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]) / 255
			shade = clamp01((1 - luma) * CLOUD_SHADE_GAIN * have)
		end
		-- Two ways of covering the sky, neither of which excuses the other
		return 1 - (1 - dense) * (1 - shade)
	end

	-- What the weather has to come out as, checked at load against what a
	-- VoxeLibre server actually sends: it leaves the density at Luanti's own
	-- 0.4 throughout and says the weather in the colour alone.
	do
		local clear = cloud_cover_of(0.4, {255, 240, 240})
		local rain = cloud_cover_of(0.4, {93, 93, 95})
		local thunder = cloud_cover_of(0.4, {61, 61, 63})
		assert(clear < 0.1, "a clear sky keeps the sun")
		assert(rain > 0.6 and rain < thunder, "rain takes most of it")
		assert(thunder > 0.9, "a thunderstorm takes nearly all of it")
		-- And a game that says it the other way, with the density
		assert(cloud_cover_of(1.0, {255, 255, 255}) > 0.9,
				"a sky full of cloud covers it whatever colour the cloud is")
		assert(cloud_cover_of(0.0, {0, 0, 0}) == 0,
				"a cloud that is not there covers nothing")

		-- And which of those the sun is allowed to whiten
		local function white_of(c)
			return smoothstep01(luminance({c[1] / 255, c[2] / 255,
					c[3] / 255}), CLOUD_WHITE_LOW, CLOUD_WHITE_HIGH)
		end
		assert(white_of({255, 240, 240}) == 1, "a white cloud takes the sun")
		assert(white_of({93, 93, 95}) == 0, "a rain cloud is left grey")
		assert(white_of({61, 61, 63}) == 0, "and a thunderhead darker still")
		assert(white_of({173, 173, 173}) > 0.1 and
				white_of({173, 173, 173}) < 0.9,
				"and what is between them is between them")
	end

	local function cloud_cover()
		if sky and sky.clouds == false then
			return 0
		end
		local clouds = sky_bodies.clouds or {}
		return cloud_cover_of(clouds.density or CLOUD_DENSITY_DEFAULT,
				clouds.color_bright)
	end

	-- A game that hides a body has said the plainest thing it can say about
	-- it: VoxeLibre turns the sun, the moon and the stars off together when
	-- the weather turns, before it darkens a single colour, and a dimension
	-- with no sky turns them off for good. Something that cannot be seen
	-- casts no light, so this is a gate rather than a dimming; what is left
	-- is the sky, which is what an overcast day is lit by.
	local function body_is_up(body)
		return (body and body.visible ~= false) and 1 or 0
	end

	-- What the sun shines with now: its own colour, going the colour of the
	-- horizon over the hour it is crossing it, which is where that colour
	-- belongs and is the same handover the sky shader does to the disc.
	local function sun_light_color(time_of_day)
		local tint = sky_color("sun_tint", 1)
		local low = low_sun(time_of_day)
		low = (1 - (1 - low) * (1 - low)) * SUN_TINT_SHARE
		return magic.Color(
				SUN_COLOR[1] * (1 - low) + tint.r * low,
				SUN_COLOR[2] * (1 - low) + tint.g * low,
				SUN_COLOR[3] * (1 - low) + tint.b * low)
	end

	-- That the clock and the horizon agree, checked here rather than where
	-- the clocks are written because sun_direction() is defined between the
	-- two: the sun's ramp begins where the sun is level with the horizon and
	-- ends where it is level again, so neither rule has to fight the other.
	do
		local function elevation(t)
			local _, sy = sun_direction(t)
			return sy
		end
		assert(math.abs(elevation(SUN_RISE)) < 0.02, "the sun rises at 05:00")
		assert(math.abs(elevation(SUN_DOWN)) < 0.02, "the sun sets at 19:00")
		assert(elevation(12000) > 0.9, "the sun is overhead at noon")
		assert(elevation(0) < -0.9, "the sun is under the world at midnight")
		-- And that a quarter of an hour off the horizon the light is red
		-- rather than a warm white, which is the whole of what the window is
		-- for
		local setting = sun_light_color(SUN_DOWN - 250)
		assert(setting.r - setting.b > 0.5, "a quarter hour from setting")
		local rising = sun_light_color(SUN_RISE + 250)
		assert(rising.r - rising.b > 0.5, "and a quarter hour after rising")
		local noon = sun_light_color(12000)
		assert(noon.r - noon.b < 0.15, "and its own colour the rest of the day")
	end

	-- Luanti eases the sky rather than setting it: Sky::update() keeps the
	-- colours and the brightness it is drawing and moves each a fixed share
	-- of the way to the target every frame, so a band changing under it comes
	-- out as a minute of sunrise instead of a jump. The same thing here, with
	-- the share worked out from the frame's own length so that it does not
	-- depend on how fast the frames come, and with a jump too big to be the
	-- day moving -- a game setting its clock, or a sky arriving -- taken at
	-- once rather than eased, which is Luanti's rule as well.
	local SKY_EASE_SECONDS = 0.8
	local SKY_EASE_SNAP = 0.35

	local sky_eased = {}

	local function sky_share(dtime)
		if dtime <= 0 then
			return 1
		end
		-- 1 - e^-t/tau, but without exp: this is within a few per cent of it
		-- over a frame and cannot overshoot
		return clamp01(dtime / (SKY_EASE_SECONDS + dtime))
	end

	local function sky_ease(dtime, key, target)
		local at = sky_eased[key]
		if at == nil or math.abs(target - at) > SKY_EASE_SNAP then
			sky_eased[key] = target
			return target
		end
		at = at + (target - at) * sky_share(dtime)
		sky_eased[key] = at
		return at
	end

	-- The same for a colour, eased in the band's own full-strength colours
	-- and scaled by the brightness afterwards, so that what is being eased is
	-- which sky it is rather than how dark it is
	local function sky_ease_color(dtime, key, target, brightness)
		local at = sky_eased[key]
		if at == nil or math.abs(target.r - at[1]) > SKY_EASE_SNAP or
				math.abs(target.g - at[2]) > SKY_EASE_SNAP or
				math.abs(target.b - at[3]) > SKY_EASE_SNAP then
			at = {target.r, target.g, target.b}
			sky_eased[key] = at
		else
			local k = sky_share(dtime)
			at[1] = at[1] + (target.r - at[1]) * k
			at[2] = at[2] + (target.g - at[2]) * k
			at[3] = at[3] + (target.b - at[3]) * k
		end
		return magic.Color(at[1] * brightness, at[2] * brightness,
				at[3] * brightness)
	end

	-- What the easing has to do, checked at load: arrive where it was sent,
	-- take its time getting there, and not take its time over a jump that is
	-- a game setting its clock rather than the day passing.
	do
		assert(sky_ease(0.1, "check", 0.5) == 0.5, "the first is where it is")
		local half = sky_ease(SKY_EASE_SECONDS, "check", 0.7)
		assert(half > 0.58 and half < 0.62,
				"a tau of it is about half the way")
		for _ = 1, 200 do
			sky_ease(0.05, "check", 0.7)
		end
		assert(math.abs(sky_ease(0.05, "check", 0.7) - 0.7) < 0.001,
				"and it arrives")
		assert(sky_ease(0.05, "check", 0.0) == 0.0, "a jump is taken at once")
		sky_eased.check = nil
	end

	local function apply_daylight(dtime)
		local factor = daylight
		if not pbr then
			zone.ambientColor = sunlight_color(factor)
		end

		local brightness = brightness_of(factor)
		-- Which set of colours, by the same bands Luanti's Sky::update()
		-- uses: night, dawn, or the day's own. The set changes at a step,
		-- there as here; what makes the change not read as one is that
		-- nothing below is the target, it is where the sky has got to on its
		-- way there. See sky_ease() above.
		--
		-- simplified: Luanti has a fourth set for a player who cannot see the
		-- sky at all, which is not read here.
		local band = "day"
		if brightness < 0.13 then
			band = "night"
		elseif brightness >= 0.20 and brightness < 0.35 then
			band = "dawn"
		end
		local top = sky_color(band.."_sky", 1)
		local horizon = sky_color(band.."_horizon", 1)
		if sky and sky.type == "skybox" then
			-- A game that gave its own textures gets its bgcolor, which is
			-- the one thing of its sky that is understood here
			top = sky_color("bgcolor", 1)
			horizon = top
		elseif sky and not sky.day_sky and sky.bgcolor then
			top = sky_color("bgcolor", 1)
			horizon = top
		end

		-- Where the sky has actually got to, which is what everything below
		-- is drawn from. The brightness the band is scaled by is eased too,
		-- so a sunrise is a sunrise and not a set of colours being swapped.
		brightness = sky_ease(dtime, "brightness", brightness)
		top = sky_ease_color(dtime, "top", top, brightness)
		horizon = sky_ease_color(dtime, "horizon", horizon, brightness)

		-- What is behind the world, which the fog fades into: the horizon
		-- the sky is drawn with, so the two meet
		zone.fogColor = horizon

		-- On the PBR path the ambient light is the sky itself rather than the
		-- colour of sunlight. The shader's ambient is
		-- cAmbientColor.rgb * color.a + color.rgb, so what a surface gets is
		-- the sky in proportion to how much of it it can see: open ground is
		-- sky-blue-white, under an overhang is the same blue but dimmer, and a
		-- cave is only the warm rgb the torches baked in. That is the three
		-- tints -- sun, shade, cave -- and it costs this one line.
		if pbr then
			zone.ambientColor = ambient_from_sky(top,
					1 - sun_amount(daylight_time))
		end

		-- What the PBR path's reflections are worth now: the cube map beside
		-- the shader is one static noon gradient and this is the colour it is
		-- multiplied by, so a sunset reflects orange and a night reflects
		-- almost nothing. The sky's own top colour, which is most of what a
		-- surface pointed upwards reflects.
		if vis then
			vis:set_param("SkyColor", magic.Vector3(top.r, top.g, top.b))
		end

		if sun_light then
			-- The light travels the other way from the body it comes from,
			-- and the moon is opposite the sun, so one direction gives both.
			-- Whichever of the two is under the world is taken out of the
			-- scene rather than dimmed: a directional light does not know
			-- about the horizon, and one below it lights the undersides of
			-- everything and puts the night's sparkle on the wrong side of
			-- the sky.
			-- Where they are is stepped; whether they are up, how bright
			-- and what colour is not, so nothing about the light itself
			-- steps, only the direction the shadow is cast from
			local sx, sy, sz = sun_direction(stepped_time(daylight_time))
			local _, smooth_sy = sun_direction(daylight_time)
			local through_cloud = 1 - CLOUD_DIM * cloud_cover()
			local up = sun_amount(daylight_time) * above_horizon(smooth_sy) *
					through_cloud * body_is_up(sky_bodies.sun)
			sun_node.enabled = up > 0
			local sun_color = sun_light_color(daylight_time)
			if up > 0 then
				sun_node.direction = magic.Vector3(-sx, -sy, -sz)
				sun_light.brightness = SUN_BRIGHTNESS * up
				sun_light.color = sun_color
			end
			local moon_up = moon_amount(daylight_time) *
					above_horizon(-smooth_sy) * through_cloud *
					body_is_up(sky_bodies.moon)
			moon_node.enabled = moon_up > 0
			if moon_up > 0 then
				moon_node.direction = magic.Vector3(sx, sy, sz)
				moon_light.brightness = MOON_BRIGHTNESS * moon_up
			end
			-- What the two are worth to something drawn unlit, which has no
			-- normal to take a share of them by: the colour of whichever is
			-- up, and in the alpha how much of it there is, the moon counted
			-- at what it is worth against the sun
			object_sun = magic.Color(sun_color.r, sun_color.g, sun_color.b,
					up + moon_up * MOON_BRIGHTNESS / SUN_BRIGHTNESS)
		end

		if sky_material then
			local sx, sy, sz = sun_direction(daylight_time)
			sky_material:SetShaderParameter("SkyTop", top)
			sky_material:SetShaderParameter("SkyHorizon", horizon)
			sky_material:SetShaderParameter("SunDirection",
					magic.Vector3(sx, sy, sz))
			-- The tint the sun paints the horizon with, at its own strength
			-- rather than the sky's: it is what dawn and dusk are
			sky_material:SetShaderParameter("SunTint",
					sky_color("sun_tint", 0.35 + brightness * 0.65))
			-- Luanti's clouds are the daylight's own colour, unless the
			-- game gave them one; either way they go dark with the day. And
			-- over the hour the sun spends crossing the horizon they take its
			-- colour, because at that hour the sun is what is lighting them
			-- and it is lighting them from underneath: that is what makes a
			-- sunrise a sunrise rather than a sky that has got brighter.
			local sun_now = sun_light_color(daylight_time)
			local lit = low_sun(daylight_time) * CLOUD_SUN_TINT
			local cloud = sky_bodies.clouds.color_bright
			local own = cloud and
					{cloud[1] / 255, cloud[2] / 255, cloud[3] / 255} or
					{0.9, 0.92, 0.95}
			-- A cloud in the sun is not a light grey thing, it is a white
			-- one, and on the PBR path the tone curve is between it and the
			-- screen: a colour that arrives at one leaves it at about nine
			-- tenths and reads as grey. So it is given some room to be
			-- clipped out of, while the sun is up to do it -- ramped with the
			-- sun's own hour at each end of the day -- and only as far as the
			-- game's own colour says it is a white cloud. A game that wants
			-- grey clouds, which is how VoxeLibre says it is raining, is
			-- taken at its word and left alone.
			local day = pbr and sun_amount(daylight_time) * above_horizon(sy) *
					body_is_up(sky_bodies.sun) or 0
			local white = smoothstep01(luminance(own), CLOUD_WHITE_LOW,
					CLOUD_WHITE_HIGH)
			local gain = 1 + (CLOUD_DAY_GAIN - 1) * day * white
			local function cloud_channel(i, from_sun)
				return (own[i] * (1 - lit) + from_sun * lit) *
						brightness * gain
			end
			if cloud then
				sky_material:SetShaderParameter("CloudColor", magic.Color(
						cloud_channel(1, sun_now.r),
						cloud_channel(2, sun_now.g),
						cloud_channel(3, sun_now.b)))
			else
				sky_material:SetShaderParameter("CloudColor", magic.Color(
						cloud_channel(1, sun_now.r) + 0.05,
						cloud_channel(2, sun_now.g) + 0.05,
						cloud_channel(3, sun_now.b) + 0.06))
			end
			-- The stars come out as the sky goes dark, and a game can say
			-- they are out in the day as well
			local day_opacity = sky_bodies.stars.day_opacity or 0
			sky_material:SetShaderParameter("StarFade", math.max(day_opacity,
					math.max(0, math.min(1, (0.25 - brightness) * 6))))

			-- What the game says is up there, and how much of it
			local sun = sky_bodies.sun
			local moon = sky_bodies.moon
			local stars = sky_bodies.stars
			-- The textures, if the game gave any and the media has arrived.
			-- A body whose texture is not there wears the shader's own
			-- colour until it is: the sky is drawn from the first frame and
			-- the media comes later.
			local sun_texture = sun.visible and sun.texture and
					sun.texture ~= "" and media_texture and
					media_texture(sun.texture) or nil
			local moon_texture = moon.visible and moon.texture and
					moon.texture ~= "" and media_texture and
					media_texture(moon.texture) or nil
			if sun_texture then
				sky_material:SetTexture(0, game_texture(sun_texture))
			end
			if moon_texture then
				sky_material:SetTexture(1, game_texture(moon_texture))
			end
			sky_material:SetShaderParameter("SunTextured",
					sun_texture and 1 or 0)
			sky_material:SetShaderParameter("MoonTextured",
					moon_texture and 1 or 0)
			-- How far past white the disc is drawn. On the PBR path the
			-- frame is tone mapped, so this is a real multiplier and what
			-- the bloom around the sun comes from; on the vanilla path the
			-- frame clips at one and a little past it is all that is wanted.
			sky_material:SetShaderParameter("SunOverexposure",
					pbr and SUN_DISC_OVEREXPOSURE or 1.5)
			sky_material:SetShaderParameter("SunSize",
					sun.visible and SUN_HALF * (sun.scale or 1) or 0)
			sky_material:SetShaderParameter("MoonSize",
					moon.visible and MOON_HALF * (moon.scale or 1) or 0)
			sky_material:SetShaderParameter("StarDensity",
					stars.visible and STAR_DENSITY_DEFAULT *
					(stars.count or STARS_DEFAULT) / STARS_DEFAULT or 0)
			local star_color = stars.color or {133, 140, 158}
			sky_material:SetShaderParameter("StarColor", magic.Color(
					star_color[1] / 255, star_color[2] / 255,
					star_color[3] / 255))
			-- How fast they drift, which a game changes with the weather
			local wind = sky_bodies.clouds.speed or CLOUD_SPEED_DEFAULT
			sky_material:SetShaderParameter("CloudWind", magic.Vector2(
					wind[1] * CLOUD_WIND_PER_NODE,
					wind[2] * CLOUD_WIND_PER_NODE))
			-- The density goes to the shader as it came. Luanti fills a
			-- cloud cell where its own 0...1 noise falls below the density,
			-- so the number is a quantile of that noise; the shader beside
			-- this file fills where its noise rises above one minus the
			-- coverage, which is a quantile of its own. Both are value noise
			-- of much the same shape and both are even about a half, so the
			-- quantile carries straight across and the coverage is the
			-- density. Sampled over two hundred thousand points, what
			-- Luanti's client covers and what this one covers agree to within
			-- two parts in a hundred the whole way from nothing to a full
			-- sky. What was here before scaled the density by 0.85 first,
			-- which at Luanti's own default covered a sixth of the sky where
			-- Luanti covers a quarter.
			local cloud_color = sky_bodies.clouds.color_bright
			sky_material:SetShaderParameter("CloudAlpha",
					(cloud_color and cloud_color[4] and
					cloud_color[4] / 255) or CLOUD_ALPHA_DEFAULT)
			sky_material:SetShaderParameter("CloudCoverage",
					(sky and sky.clouds == false) and 0 or
					(sky_bodies.clouds.density or CLOUD_DENSITY_DEFAULT))
		end
	end

	-- What the light and the time are now. Nothing is drawn from here: the
	-- sky is drawn every frame by apply_daylight(), easing towards whatever
	-- this last said, which is what makes the day pass rather than step.
	function self:set_daylight(factor, time_of_day)
		daylight = factor
		daylight_time = time_of_day or daylight_time
	end

	function self:set_sky(new_sky)
		sky = new_sky
	end

	-- What the game says is in the sky, each out of its own packet. The
	-- fields are the ones client.lua read; what is not there is left as it
	-- was, which is how Luanti treats them too.
	function self:set_sky_body(which, what)
		if not sky_bodies[which] or not what then
			return
		end
		for key, value in pairs(what) do
			sky_bodies[which][key] = value
		end
	end

	-- Builds the voxel registry from Luanti's node definitions.
	--
	-- defs is what nodedef.parse() returned. resolve_tile(def, i) turns one of
	-- a node's six faces into a resource name the cache can find, or nil for
	-- one that cannot be built: what a tile is drawn as is the game's own
	-- business -- the texture expression, the overlay, the colour -- and this
	-- only needs the name that comes out. A node with any face unresolved
	-- keeps the placeholder: half a cube's textures is worse to look at than
	-- none of them.
	--
	-- One definition as a voxel in a registry, or nil for one whose textures
	-- are not all there. override is a colour that stands in for the
	-- definition's own, which is what a palette index comes to.
	-- name has to be different for every voxel in a registry: the registry
	-- keys them by it, and adding a second voxel under a name it already has
	-- is an error. A pair's name carries what makes it different.
	--
	-- variants is what the voxel's param2 does to it -- turned one way, its
	-- liquid at one of eight levels -- as build_variants() worked it out.
	-- The voxel itself is built facing 0, with its liquid full, which is what
	-- a param2 that means nothing draws as.
	local function build_voxel(reg, def, resolve_tile, override, name,
			variants)
		local kind = CUBE_DRAWTYPES[def.drawtype]
		local group = liquid_group(def)
		-- What the mesher needs to work out this voxel's connections per
		-- voxel: which family it is in, which families it reaches out to,
		-- and whether it also reaches into a solid neighbour
		local connect = nil
		if (def.connect_group or 0) ~= 0 or (def.connect_mask or 0) ~= 0 then
			connect = {group = def.connect_group, mask = def.connect_mask,
					solid = (def.connect_sides or 0) ~= 0}
		end
		-- Luanti draws a liquid from its *special* tiles and not from its
		-- six: special 1 is the still texture and special 2 the flowing
		-- one, which is why water drawn from the ordinary tiles wears its
		-- still texture everywhere. A liquid with no special tile of its
		-- own falls back to the face, which is what resolve_face does.
		local liquid_face = nil
		if group ~= 0 then
			liquid_face = def.drawtype == DRAWTYPE_FLOWINGLIQUID and
					{7, 7, 8, 8, 8, 8} or {7, 7, 7, 7, 7, 7}
		end
		local function resolve_face(d, i, o)
			if liquid_face and i <= 6 then
				return resolve_tile(d, liquid_face[i], o) or
						resolve_tile(d, i, o)
			end
			return resolve_tile(d, i, o)
		end
		local shape, double_sided, masked, solid_base = shapes.for_node(def,
				nil, nil, read_mesh and read_mesh(def) or nil, nil)
		if def.drawtype == DRAWTYPE_AIRLIKE then
			return VOXEL_AIR
		end
		if shape then
			-- Only the tiles the shape uses have to be there: a plant wears
			-- one texture and would be held back by the other five
			local resources = {}
			for _, quad in ipairs(shape) do
				local i = quad.tile
				if not resources[i] then
					-- A shape can name a tile the definition does not give:
					-- a torch has three, a sign one. Luanti falls back to
					-- the first as well.
					resources[i] = resolve_face(def, i, override) or
							resolve_face(def, 1, override)
					if not resources[i] then
						return nil
					end
				end
			end
			-- A shape per mask wears more tiles than the one shape does: a
			-- rail's straight, curve, junction and crossing are four of them
			if masked then
				for m = 0, 19 do
					for _, quad in ipairs(masked[m] or {}) do
						local i = quad.tile
						if not resources[i] then
							resources[i] = resolve_face(def, i, override) or
									resolve_face(def, 1, override)
							if not resources[i] then
								return nil
							end
						end
					end
				end
			end
			-- A shape that keeps its faces needs all six of them; the rest
			-- take whatever the shape's own tiles gave, as Luanti falls back
			-- to the first tile as well
			if solid_base then
				for i = 1, 6 do
					resources[i] = resources[i] or resolve_face(def, i,
							override)
					if not resources[i] then
						return nil
					end
				end
			end
			local first = nil
			for i = 1, 6 do
				first = first or resources[i]
			end
			for i = 1, 6 do
				resources[i] = resources[i] or first
			end
			return add_cube(reg, name or def.name, resources, kind, shape,
					double_sided, nil, group, connect, masked, variants,
					def.alpha_mode == NODEDEF_ALPHAMODE_BLEND, solid_base,
					surface.for_node(def))
		end
		if not kind then
			return nil
		end
		local resources = {}
		for i = 1, 6 do
			resources[i] = resolve_face(def, i, override)
			if not resources[i] then
				return nil
			end
		end
		return add_cube(reg, name or def.name, resources, kind, nil, nil,
				nil, group, connect, nil, variants,
				def.alpha_mode == NODEDEF_ALPHAMODE_BLEND, nil,
				surface.for_node(def))
	end

	-- Builds the registry for a set of node definitions a slice at a time.
	-- What comes back is a function to call with a microsecond budget until
	-- it says it is done; the new registry is swapped in when it is.
	--
	-- A slice at a time because this is two and a half thousand definitions
	-- with a texture expression each, which is more than a second in one go
	-- -- and it happens once the media has arrived, which is after the world
	-- is already on screen. Nothing of the old registry is touched until the
	-- swap, so the world goes on being drawn and meshed from it meanwhile.
	function self:begin_node_definitions(defs, resolve_tile, palette_colors)
		local new_reg = base_registry()
		local map = {
			[CONTENT_AIR] = VOXEL_AIR,
			[CONTENT_IGNORE] = VOXEL_AIR,
		}
		local cubes = 0
		extras_built = 0
		local light_ids = {}
		-- Air's own definition is not among the ones a server sends, so
		-- seed it the way the node map above seeds it: light and sunlight
		-- pass through air, and everything not in here is taken to block
		-- them, which is what a node drawn as the placeholder cube does.
		local light_through = {[CONTENT_AIR] = true}
		local sun_through = {[CONTENT_AIR] = true}
		local collision = {}
		local solid = {}
		local liquid = {}
		local post_effect = {}
		local selection = {}
		local pointable = {}
		local new_param2_look = {}

		local connect_group_of = connect_families(defs)

		local function one_definition(id, def)
			-- Which family of connecting nodes this one is in and which it
			-- reaches out to, as the mesher wants them: a number and a bit
			-- per family. On the definition rather than passed along,
			-- because the pair machinery builds voxels from it later too.
			def.connect_group = connect_group_of[id] or 0
			local bits = {}
			for _, to in ipairs(def.connects_to or {}) do
				local to_group = connect_group_of[to]
				if to_group then
					bits[to_group] = true
				end
			end
			-- A rail connects to its own family, which is what its group
			-- number is; nothing lists a rail in a connects_to
			if def.drawtype == DRAWTYPE_RAILLIKE and
					def.connect_group ~= 0 then
				bits[def.connect_group] = true
			end
			local mask = 0
			for bit in pairs(bits) do
				mask = mask + 2 ^ (bit - 1)
			end
			def.connect_mask = mask
			solid[id] = def.walkable
			if def.light_source and def.light_source > 0 then
				light_ids[id] = {level = def.light_source,
						color = light_color(resolve_tile(def, 1))}
			end
			-- Whether light travels through it, which with the light it
			-- gives is what decides the light around it; see
			-- light_changed()
			light_through[id] = def.light_propagates and true or false
			-- And whether the sun goes straight down through it, which is
			-- the one rule that tells glass from air
			sun_through[id] = def.sunlight_propagates and true or false
			-- Luanti's PointabilityType: 0 is not pointable, 1 is, and 2
			-- stops a ray without being pointed at. Those two values are
			-- that way round because they used to be a boolean.
			pointable[id] = def.pointable ~= 0
			liquid[id] = def.liquid_type ~= nil and
					def.liquid_type ~= NODEDEF_LIQUID_NONE
			if def.post_effect_color and def.post_effect_color.a > 0 then
				post_effect[id] = def.post_effect_color
			end
			local facing = FACING[def.param_type_2]
			-- A flowing liquid's param2 says how high its surface stands.
			-- The range is how many of the eight levels the liquid spends on
			-- the top of a voxel.
			local liquid_range = def.drawtype == DRAWTYPE_FLOWINGLIQUID and
					(def.liquid_range or 8) or nil
			local variants = build_variants(def, facing, liquid_range,
					read_mesh and read_mesh(def) or nil)
			local voxel = build_voxel(new_reg, def, resolve_tile, nil, nil,
					variants)
			if voxel then
				map[id] = voxel
				if voxel ~= VOXEL_AIR then
					cubes = cubes + 1
				end
			end
			-- Anything left out keeps map_default, the placeholder cube

			-- A definition whose param2 is a palette index is drawn in one
			-- colour per index, and which colour that is is only known once
			-- a voxel with that param2 turns up: see register_pairs(). This
			-- is the one thing param2 says that a variant cannot carry.
			local step = COLOR_STEP[def.param_type_2]
			local colors = nil
			if step and def.palette_name ~= "" and palette_colors then
				colors = palette_colors(def.palette_name)
				if colors and #colors < 2 then
					colors = nil
				end
			end
			-- What the player runs into. Luanti takes the collision box when
			-- the definition has one and the node box otherwise; a voxel
			-- whose boxes are not there at all is a whole cube, which is
			-- what is_solid() says by returning true.
			local cbox = def.collision_box
			if not cbox or #cbox.boxes == 0 then
				cbox = def.node_box
			end
			if def.walkable and cbox and #cbox.boxes > 0 then
				collision[id] = {boxes = cbox.boxes, facing = facing}
			end

			-- What the pointed-node outline goes around: Luanti's selection
			-- box, and the node box when the definition gives none. A node
			-- with neither is a whole voxel, which is what a node not in here
			-- is outlined as.
			local sbox = def.selection_box
			if not sbox or #sbox.boxes == 0 then
				sbox = def.node_box
			end
			if sbox and #sbox.boxes > 0 then
				selection[id] = {boxes = sbox.boxes, facing = facing}
			end

			-- Only a palette needs a voxel per param2 now; the rest of what
			-- param2 says is in the variants
			if voxel and colors then
				new_param2_look[id] = {def = def, step = step,
						colors = colors, variants = variants}
			end
		end

		-- What register_pairs() calls for a pair it has not seen. The voxel
		-- goes into the registry that is current, which is why this is made
		-- here rather than kept as a method: a new set of definitions
		-- replaces the registry and everything built into it.
		build_pair = function(entry, id, p2, key)
			-- Luanti stretches a palette to 256 entries by repeating each
			-- pixel, and indexes that with param2's high bits
			local index = math.floor((p2 - p2 % entry.step) *
					#entry.colors / 256) + 1
			-- Two param2 values that come to the same colour are the same
			-- voxel. What else their param2 says -- a facing, a liquid level
			-- -- is in the variants and does not make a voxel of its own.
			local cache_key = id.."/"..index
			-- Whatever this writes, the map is not the one that was
			-- compiled for the last block
			self.pair_map_version = self.pair_map_version + 1
			local voxel = pair_voxel[cache_key]
			if voxel == nil then
				voxel = build_voxel(self.voxel_reg, entry.def, resolve_tile,
						entry.colors[index],
						entry.def.name.."^"..cache_key,
						entry.variants) or false
				pair_voxel[cache_key] = voxel
			end
			-- false for a pair whose textures are not there: remembered so
			-- that it is not built again for every voxel in every block
			self.pair_map[key] = voxel or false
			if voxel then
				self.pair_count = self.pair_count + 1
			end
		end

		local function commit()
			self.voxel_reg = new_reg
			-- Which voxels give light is decided by the definitions, so what
			-- was worked out from the old ones says nothing
			for _, block in pairs(blocks) do
				block.lights = nil
			end
			-- A fresh atlas registry: the old one holds atlases built for
			-- the old registry's segment ids
			self.atlas_reg = new_atlas_registry()
			self.node_map = map
			self.node_light = light_ids
			self.node_light_through = light_through
			self.node_sun_through = sun_through
			self.node_collision = collision
			self.node_solid = solid
			self.node_liquid = liquid
			self.node_post_effect = post_effect
			self.node_selection = selection
			self.node_pointable = pointable
			-- Everything a param2 meant is decided by these definitions too,
			-- and the pairs were built into the registry that is going away
			self.pair_map = {}
			self.pair_count = 0
			pair_voxel = {}
			param2_look = new_param2_look
			pair_epoch = pair_epoch + 1
			self.pair_map_version = self.pair_map_version + 1
			self.node_map_version = self.node_map_version + 1
			self:invalidate_all()
		end

		local at = nil
		local done = false
		return function(budget_us)
			if done then
				return true, cubes
			end
			local t0 = buildat.get_time_us()
			while true do
				local id, def = next(defs, at)
				if id == nil then
					log:info(extras_built.." voxel types wear a texture "..
							"beyond their six faces")
					done = true
					commit()
					return true, cubes
				end
				at = id
				one_definition(id, def)
				if buildat.get_time_us() - t0 >= budget_us then
					return false, cubes
				end
			end
		end
	end

	-- The whole of the above in one call, for a caller with no frames to
	-- spread it over
	function self:set_node_definitions(defs, resolve_tile, palette_colors)
		local step = self:begin_node_definitions(defs, resolve_tile,
				palette_colors)
		local done, cubes
		repeat
			done, cubes = step(1000000000)
		until done
		return cubes
	end

	-- Everything is out of date; used when what a node id means changes, which
	-- is what arriving node definitions do
	function self:invalidate_all()
		for key, _ in pairs(blocks) do
			mark_dirty(key)
		end
	end

	-- Meshes the blocks nearest the camera first, up to MESH_PER_FRAME of
	-- them, and drops what has gone further away than drop_distance nodes.
	--
	-- drop_distance may be nil, and has to be until the camera is where the
	-- player is: a block the server sends before that is acknowledged as
	-- soon as it arrives, and the server does not send an acknowledged block
	-- again, so dropping it leaves a hole in the world for the rest of the
	-- session -- and the first blocks it sends are the ones around the
	-- player, which is exactly where a hole is worst.
	function self:update(dtime, drop_distance)
		-- Every frame, because easing towards a target is what it is for
		if daylight then
			apply_daylight(dtime)
		end
		local p = camera_node.position
		-- Which lights are the nearest changes as the player walks, but not
		-- so fast that it is worth working out every frame
		if not lights_at or lights_stale or
				(p.x - lights_at[1]) ^ 2 + (p.y - lights_at[2]) ^ 2 +
				(p.z - lights_at[3]) ^ 2 > 4 then
			lights_at = {p.x, p.y, p.z}
			lights_stale = false
			place_lights()
		end
		update_sky_visibility()
		if drop_distance then
			local limit = drop_distance / BLOCKSIZE
			for key, block in pairs(blocks) do
				local dx = block.x + 0.5 - p.x / BLOCKSIZE
				local dy = block.y + 0.5 - p.y / BLOCKSIZE
				local dz = block.z + 0.5 - p.z / BLOCKSIZE
				if math.sqrt(dx * dx + dy * dy + dz * dz) > limit then
					if block.node then
						scene:RemoveChild(block.node)
					end
					blocks[key] = nil
					if dirty[key] then
						dirty[key] = nil
						dirty_count = dirty_count - 1
					end
				end
			end
		end
		if dirty_count == 0 then
			return 0
		end
		-- The nearest few, rather than a sort of the whole set: the set is
		-- what arrived this frame plus a backlog, and a full sort of it every
		-- frame costs more than the meshing does
		local meshed = 0
		local t0 = buildat.get_time_us()
		self.worst_mesh_us = 0
		local pairs_before = self:pair_voxel_count()
		while meshed < MESH_PER_FRAME do
			if meshed > 0 and buildat.get_time_us() - t0 >= MESH_BUDGET_US then
				break
			end
			local best_key, best_d = nil, nil
			for key, _ in pairs(dirty) do
				local block = blocks[key]
				local dx = block.x * BLOCKSIZE - p.x
				local dy = block.y * BLOCKSIZE - p.y
				local dz = block.z * BLOCKSIZE - p.z
				local d = dx * dx + dy * dy + dz * dz
				if not best_d or d < best_d then
					best_key, best_d = key, d
				end
			end
			if not best_key then
				break
			end
			dirty[best_key] = nil
			dirty_count = dirty_count - 1
			mesh_block(best_key)
			meshed = meshed + 1
		end
		-- What the frame spent handing blocks over, and what it cost beyond
		-- the meshing itself: a voxel pair registered here builds an atlas
		-- segment and uploads a texture, which is a spike of its own
		self.last_frame_mesh_us = buildat.get_time_us() - t0
		self.last_frame_meshed = meshed
		self.last_frame_pairs = self:pair_voxel_count() - pairs_before
		return meshed
	end

	-- Give the screen back to whatever was drawing before, and drop the
	-- blocks' scene nodes. The scene itself goes when nothing points at it.
	function self:close()
		for key, block in pairs(blocks) do
			if block.node then
				scene:RemoveChild(block.node)
			end
			blocks[key] = nil
		end
		dirty = {}
		dirty_count = 0
		for id, entry in pairs(object_nodes) do
			scene:RemoveChild(entry.node)
			object_nodes[id] = nil
		end
		-- Dropping the viewport rather than replacing it: there is nothing
		-- else to show
		magic.set_preferred_viewports({})
		-- HDR and the render path are the renderer's, not the viewport's, so
		-- a world that has gone has to hand them back or the menu after it is
		-- drawn through a tone curve with nothing to tone map
		magic.renderer.HDRRendering = false
	end

	function self:block_count()
		local n = 0
		for _, _ in pairs(blocks) do
			n = n + 1
		end
		return n
	end

	function self:dirty_count()
		return dirty_count
	end

	-- Where the camera is and which way it looks, in Luanti's terms: pitch is
	-- degrees positive looking down and yaw is degrees counterclockwise from
	-- +Z seen from above.
	--
	-- Urho3D's pitch is positive looking down too, so that one goes as it
	-- is; its yaw turns the other way round -- clockwise from above, because
	-- it is left-handed where Luanti's rotateXZBy() is right-handed -- so
	-- that one is negated. Getting either sense wrong is not just a mirrored
	-- view: the server sends the blocks it thinks the player can see, so it
	-- would send the ones the player is looking away from.
	function self:set_camera(x, y, z, pitch, yaw)
		camera_node.position = magic.Vector3(x, y, z)
		camera_node.rotation = magic.Quaternion(pitch or 0, -(yaw or 0), 0)
		-- Kept for the light refresh, which only asks for blocks near enough
		-- to be worth a resend; see refresh_wanted()
		camera_at = {x, y, z}
	end

	return self
end

-- Checks build_variants(), which is where what Luanti's param2 means turns
-- into the variants buildat's mesher indexes by the param. init.lua runs it at
-- boot, next to the other self-tests.
function M.self_test()
	-- A cube that faces one of twenty-four directions. Every param2 but the
	-- ones that come to facedir 0 is claimed, and each claimed one gets the
	-- tile order and the turns its direction asks for.
	local vs = build_variants({drawtype = 0}, "facedir", nil)
	assert(vs, "a facedir cube got no variants")
	assert(#vs == 23, "a facedir cube got "..#vs.." variants, not 23")
	local claimed = {}
	local total = 0
	for _, v in ipairs(vs) do
		assert(v.tile_order and v.tile_turns,
				"a facedir variant has no tile order")
		assert(not v.shape, "a facedir cube variant has a shape")
		for _, p2 in ipairs(v.params) do
			assert(not claimed[p2], "param2 "..p2.." is claimed twice")
			claimed[p2] = v
			total = total + 1
		end
	end
	-- Luanti reads a facedir out of param2 as p2 % 32 % 24, so each of the
	-- 24 directions is claimed by the param2 values that come to it, and the
	-- ones that come to 0 are left for the definition itself
	local unclaimed = 0
	for p2 = 0, 255 do
		if shapes.facedir_of("facedir", p2) == 0 then
			assert(not claimed[p2], "param2 "..p2.." faces 0 and is claimed")
			unclaimed = unclaimed + 1
		else
			assert(claimed[p2], "param2 "..p2.." faces "..
					shapes.facedir_of("facedir", p2).." and is unclaimed")
		end
	end
	assert(total + unclaimed == 256,
			total.." + "..unclaimed.." param2 values, not 256")
	-- The tile order is the faces 0...5, permuted; two directions that are
	-- not the same do not get the same one
	local seen = {}
	for _, v in ipairs(vs) do
		local key = table.concat(v.tile_order, ",").."/"..
				table.concat(v.tile_turns, ",")
		assert(not seen[key], "two facedirs come to the same tiles: "..key)
		seen[key] = true
		local used = {}
		for i = 1, 6 do
			local f = v.tile_order[i]
			assert(f >= 0 and f <= 5, "tile order has face "..f)
			assert(not used[f], "tile order wears face "..f.." twice")
			used[f] = true
		end
	end

	-- 4dir is the same thing with four directions, so three variants
	local four = build_variants({drawtype = 0}, "4dir", nil)
	assert(four and #four == 3, "4dir got "..tostring(four and #four).." variants")

	-- A flowing liquid: one variant per level below the top, each a shape
	-- rather than a cube, and the levels rise with param2
	local liq = build_variants({drawtype = 10, liquid_range = 8}, nil, 8)
	assert(liq, "a flowing liquid got no variants")
	local tops = {}
	for _, v in ipairs(liq) do
		assert(v.liquid_top and v.liquid_top < 0.5,
				"a liquid variant stands at "..tostring(v.liquid_top))
		tops[#tops + 1] = v.liquid_top
	end
	assert(#liq >= 7, "a flowing liquid got "..#liq.." levels")
	for i = 2, #tops do
		assert(tops[i] > tops[i - 1],
				"liquid levels are not in order: "..tops[i - 1].." then "..
				tops[i])
	end

	-- Nothing to say about param2, nothing built
	assert(build_variants({drawtype = 0}, nil, nil) == nil,
			"a definition with no param2 meaning got variants")
end

M.BLOCKSIZE = BLOCKSIZE
M.VOXEL_AIR = VOXEL_AIR
M.VOXEL_PLACEHOLDER = VOXEL_PLACEHOLDER

return M
-- vim: set noet ts=4 sw=4:
