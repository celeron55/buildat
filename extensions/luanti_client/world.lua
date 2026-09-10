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

-- What the volume is before the block and its neighbours are copied into it:
-- air that sees the full sky. A face against a neighbour that has not arrived
-- is then lit as if it were out in the open, which is wrong in a cave but
-- only until the neighbour comes, and a wrongly lit face reads better than
-- the black one that unlit air would give. Skylight is bits 24..27.
local VOXEL_AIR_LIT = VOXEL_AIR + 15 * 0x1000000

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

	local self = {}

	-- One of the game's own textures, drawn without smoothing. A Luanti
	-- game's textures are pixel art and interpolating them is wrong at every
	-- size: the voxel atlas already says so in the engine (see
	-- SetFilterMode in src/impl/atlas.cpp) and everything else a game's
	-- texture goes on -- an object, a dropped item, the sun -- wants the
	-- same. The mode is on the texture rather than on the material, so
	-- setting it once per use is setting it for good; it is cheap and there
	-- is nowhere better.
	local function game_texture(name)
		local tex = magic.cache:GetResource("Texture2D", name)
		if tex then
			tex.filterMode = magic.FILTER_NEAREST
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
	local CLOUD_COVERAGE_DEFAULT = 0.34

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
	-- directional light to reach.
	local technique = magic.cache:GetResource("Technique",
			"luanti_client/res/VoxelUnlit.xml")
	local alpha_technique = magic.cache:GetResource("Technique",
			"luanti_client/res/VoxelUnlitAlpha.xml")

	-- The mesher sets no technique on skylit geometry -- only the game knows
	-- which shader reads what it packed -- so every block's materials get
	-- this one once they exist.
	local function apply_to(cg, tech)
		if not cg then
			return
		end
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
	magic.renderer:SetViewport(0, viewport)

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
	local function add_cube(voxel_reg, name, resources, kind, shape,
			double_sided, turns, liquid_group, connect, masked)
		local vdef = buildat.VoxelDefinition()
		vdef.name.block_name = name
		vdef.handler_module = ""
		local textures = {}
		for i = 1, 6 do
			local seg = buildat.AtlasSegmentDefinition()
			seg.resource_name = resources[i]
			seg.total_segments = magic.IntVector2(1, 1)
			seg.select_segment = magic.IntVector2(0, 0)
			-- A game's textures are painted, not photographed; a wide, weak
			-- highlight keeps them looking like what they are painted as
			seg.roughness = 0.95
			seg.spec_strength = 0.2
			seg.bumpiness = 0.3
			textures[i] = seg
		end
		vdef.textures = textures
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
		vdef.translucent = liquid_group ~= nil and liquid_group ~= 0
		if vdef.translucent then
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
			vdef.face_draw_type =
					buildat.VoxelDefinition.FACEDRAWTYPE_NEVER
			-- A shaped voxel's neighbours draw their faces against it, which
			-- is what EMPTY says. A liquid keeps its own edge material
			-- instead: a lake's cubes must not draw their faces against the
			-- shaped surface on top of them.
			if not (liquid_group and liquid_group ~= 0) then
				vdef.edge_material_id =
						buildat.VoxelDefinition.EDGEMATERIALID_EMPTY
			end
		end
		return voxel_reg:add_voxel(vdef)
	end

	-- The registry as it is until the node definitions arrive: air, and one
	-- placeholder cube for everything else. set_node_definitions() replaces
	-- it with one built from what the server says the nodes are.
	local function base_registry()
		local voxel_reg = buildat.createVoxelRegistry()
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
	-- The voxel shader here samples the diffuse atlas and nothing else, and
	-- deriving the normal and surface maps of a texture is two thirds of what
	-- adding one to an atlas costs
	local function new_atlas_registry()
		local reg = buildat.createAtlasRegistry()
		reg:set_surface_maps(false)
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

	-- One voxel id per (definition, param2) pair, for the pairs that turn up
	-- in a block that arrives. The map is keyed the way the paired lookup
	-- wants; pair_voxel is keyed by what actually decides the look, so two
	-- param2 values that pick the same palette colour share a voxel id.
	self.pair_map = {}
	self.pair_count = 0
	local pair_voxel = {}
	-- Bumped when the definitions change: every block has to be looked at
	-- again, because what its param2 means has changed
	local pair_epoch = 0
	-- id -> {def =, step =, colors =, facing =} for the definitions whose
	-- param2 changes what they look like; nil for everything else
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
		if self.use_skylight then
			sources[#sources + 1] = {
				data = block.param1, format = "u8",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0}, map = LIGHT_MAP, field = "light",
				map_id = MAP_ID_LIGHT, map_version = 1,
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
				if self.use_skylight then
					sources[#sources + 1] = {
						data = n.param1, format = "u8",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						map = LIGHT_MAP, field = "light",
						map_id = MAP_ID_LIGHT, map_version = 1,
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
		local node = block.node
		buildat.set_voxel_geometry(node, data, self.voxel_reg,
				self.atlas_reg, self.use_skylight,
				function() apply_technique(node) end)
		self.last_mesh_us = buildat.get_time_us() - t0
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
	-- the mesher works out a face's ambient: the sunlight colour times how
	-- much of the sky the voxel the object is in sees, plus its lamplight.
	-- Without this a mob is as bright at midnight as at noon.
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
		local sun = sunlight_color(daylight)
		-- A floor of a few percent, so that something in the pitch dark is a
		-- silhouette rather than nothing at all
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
			local node = scene:CreateChild("object_"..obj.id)
			entry = {node = node, sprite = sprite, cube = cube,
					meshed = meshed}
			if cube then
				entry.model, entry.materials = build_item_cube(node, tiles)
				entry.textured = true
			elseif meshed then
				entry.model, entry.materials = build_object_mesh(node,
						mesh.quads, mesh.tiles)
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

	-- The effect is handed to the emitter by the caller, once it has set the
	-- fields that differ between a spawner and a single particle: assigning
	-- the same effect twice is a no-op in Urho3D, so everything has to be on
	-- it before it goes on.
	local function particle_effect(texture_name, amount, ttl_min,
			ttl_max, size_min, size_max, vel_min, vel_max, acc, active_time,
			animation)
		local effect = magic.ParticleEffect.new()
		local material = magic.Material.new()
		local tex = game_texture(texture_name)
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
		-- Luanti's size is the whole particle across; a billboard's is half
		effect.minParticleSize = magic.Vector2(size_min / 2, size_min / 2)
		effect.maxParticleSize = magic.Vector2(size_max / 2, size_max / 2)
		-- The velocity: the box the direction is picked from, and the speeds
		-- that box holds. Without the speeds every particle leaves at one
		-- node a second whatever the game asked for, which reads as all of
		-- them flying away from wherever they started.
		effect.minDirection = magic.Vector3(vel_min[1], vel_min[2], vel_min[3])
		effect.maxDirection = magic.Vector3(vel_max[1], vel_max[2], vel_max[3])
		local near, far = particles.speed_range(vel_min, vel_max)
		effect.minVelocity = near
		effect.maxVelocity = far
		effect.constantForce = magic.Vector3(acc[1], acc[2], acc[3])
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
	-- simplified: a spawner attached to an object stays where the object was
	-- when it started, rather than following it.
	function self:set_particle_spawner(id, p, resolve)
		local old = particle_nodes[id]
		if old then
			scene:RemoveChild(old.node)
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
		local node = scene:CreateChild("particles_"..id)
		node.position = magic.Vector3(pos[1], pos[2], pos[3])
		local amount = math.max(1, math.min(p.amount, 1000))
		local effect = particle_effect(texture_name,
				amount, math.max(0.01, exptime.min),
				math.max(0.01, exptime.max),
				math.max(0.001, size.min), math.max(0.001, size.max),
				p.vel.start.min, p.vel.start.max,
				particles.middle(p.acc.start), p.time, p.animation)
		-- What the emitter box is: the position range, which the node sits
		-- in the middle of
		effect.emitterType = 1 -- EMITTER_BOX
		effect.emitterSize = magic.Vector3(
				math.max(0, p.pos.start.max[1] - p.pos.start.min[1]),
				math.max(0, p.pos.start.max[2] - p.pos.start.min[2]),
				math.max(0, p.pos.start.max[3] - p.pos.start.min[3]))
		-- Luanti spawns amount particles over time seconds, and amount a
		-- second when there is no time at all
		local rate = p.time > 0 and amount / p.time or amount
		effect.minEmissionRate = rate
		effect.maxEmissionRate = rate
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		-- A spawner that ends takes itself away once the last particle it
		-- made has expired; one with no time waits for the server
		local life = nil
		if p.time > 0 then
			life = p.time + exptime.max + 0.5
		end
		particle_nodes[id] = {node = node, life = life}
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
		local effect = particle_effect(texture_name, 1,
				ttl, ttl, math.max(0.001, p.size), math.max(0.001, p.size),
				p.vel, p.vel, p.acc, 0.05, p.animation)
		effect.emitterType = 0 -- EMITTER_SPHERE, of no size
		effect.emitterSize = magic.Vector3(0, 0, 0)
		effect.minEmissionRate = 100
		effect.maxEmissionRate = 100
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		single_particles[#single_particles + 1] =
				{node = node, life = ttl + 0.5}
	end

	-- Ages the emitters and takes away the ones that are done with. A
	-- spawner with no time of its own is not aged: the server deletes it.
	function self:update_particles(dtime)
		for id, entry in pairs(particle_nodes) do
			if entry.life then
				entry.life = entry.life - dtime
				if entry.life <= 0 then
					scene:RemoveChild(entry.node)
					particle_nodes[id] = nil
				end
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
		local n = #single_particles
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

	-- How far light reaches, which is how far from a change a block can be
	-- and still be wrong. Luanti's LIGHT_SUN is 15 and a light loses one per
	-- node, so this is the whole of it.
	local LIGHT_REACH = 15

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

	-- One node the server changed, in node coordinates. Patches the block's
	-- parameter arrays in place; a node on a block's edge is part of the
	-- neighbour's border, so that mesh goes out of date too.
	-- param1 may be nil, which means the node became air and its light has
	-- to be worked out here.
	--
	-- The light of everything *around* the node is the server's arithmetic
	-- and not ours: Luanti's own client relights locally, and a block's
	-- param1 here is a Lua string that a flood fill would rebuild once per
	-- node. So the blocks whose light may have moved are asked for again
	-- instead, and the stale ones are drawn until they arrive.
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
		-- What was there, for the light: see light_changed() above
		local was = block.param0:byte(i * 2 + 1) * 256 +
				block.param0:byte(i * 2 + 2)
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
			-- This block, and every neighbour the light could reach into
			refresh[key] = {bx, by, bz}
			for _, d in ipairs(NEIGHBOURS) do
				local near =
						(d[1] < 0 and lx < LIGHT_REACH) or
						(d[1] > 0 and lx >= BLOCKSIZE - LIGHT_REACH) or
						(d[2] < 0 and ly < LIGHT_REACH) or
						(d[2] > 0 and ly >= BLOCKSIZE - LIGHT_REACH) or
						(d[3] < 0 and lz < LIGHT_REACH) or
						(d[3] > 0 and lz >= BLOCKSIZE - LIGHT_REACH)
				if near then
					local nx, ny, nz = bx + d[1], by + d[2], bz + d[3]
					local nkey = block_key(nx, ny, nz)
					if blocks[nkey] then
						refresh[nkey] = {nx, ny, nz}
					end
				end
			end
		end
		return true
	end

	-- The blocks to ask the server for again, at most a handful at a time:
	-- one node change can name seven blocks and a spree of them more than a
	-- packet holds. What is left waits for the next call.
	function self:refresh_wanted(limit)
		local out = {}
		for key, at in pairs(refresh) do
			out[#out + 1] = at
			refresh[key] = nil
			if #out >= (limit or 16) then
				break
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

	function self:set_daylight(factor, time_of_day)
		daylight = factor
		daylight_time = time_of_day or daylight_time
		zone.ambientColor = sunlight_color(factor)

		local brightness = brightness_of(factor)
		-- Which set of colours, by the same bands Luanti's Sky::update()
		-- uses: night, dawn, or the day's own.
		--
		-- simplified: Luanti eases from one set to the next over a second or
		-- so of its own frames rather than switching between them, and it
		-- has a fourth set for a player who cannot see the sky at all. Here
		-- the brightness is what carries dawn into day, and the set changes
		-- when the band does.
		local band = "day"
		if brightness < 0.13 then
			band = "night"
		elseif brightness >= 0.20 and brightness < 0.35 then
			band = "dawn"
		end
		local top = sky_color(band.."_sky", brightness)
		local horizon = sky_color(band.."_horizon", brightness)
		if sky and sky.type == "skybox" then
			-- A game that gave its own textures gets its bgcolor, which is
			-- the one thing of its sky that is understood here
			top = sky_color("bgcolor", brightness)
			horizon = top
		elseif sky and not sky.day_sky and sky.bgcolor then
			top = sky_color("bgcolor", brightness)
			horizon = top
		end

		-- What is behind the world, which the fog fades into: the horizon
		-- the sky is drawn with, so the two meet
		zone.fogColor = horizon

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
			-- game gave them one; either way they go dark with the day.
			local cloud = sky_bodies.clouds.color_bright
			if cloud then
				sky_material:SetShaderParameter("CloudColor", magic.Color(
						cloud[1] / 255 * brightness,
						cloud[2] / 255 * brightness,
						cloud[3] / 255 * brightness))
			else
				sky_material:SetShaderParameter("CloudColor", magic.Color(
						0.9 * brightness + 0.05, 0.92 * brightness + 0.05,
						0.95 * brightness + 0.06))
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
			sky_material:SetShaderParameter("CloudCoverage",
					(sky and sky.clouds == false) and 0 or
					CLOUD_COVERAGE_DEFAULT *
					(sky_bodies.clouds.density or CLOUD_DENSITY_DEFAULT) /
					CLOUD_DENSITY_DEFAULT)
		end
	end

	function self:set_sky(new_sky)
		sky = new_sky
		self:set_daylight(daylight, daylight_time)
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
		self:set_daylight(daylight, daylight_time)
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
	-- facedir and wall are which way the voxel faces, out of its param2: a
	-- shape is turned by them and a cube's tiles are moved to the faces they
	-- end up on. liquid_top is how high a flowing liquid's surface stands,
	-- which is the other thing param2 says about what a voxel looks like.
	local function build_voxel(reg, def, resolve_tile, override, name,
			facedir, wall, liquid_top)
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
		local shape, double_sided, masked = shapes.for_node(def, facedir,
				wall, read_mesh and read_mesh(def) or nil, liquid_top)
		local tiles = facedir and facedir ~= 0 and
				shapes.FACEDIR_TILES[facedir + 1] or nil
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
					resources[i] = resolve_tile(def, i, override) or
							resolve_tile(def, 1, override)
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
							resources[i] = resolve_tile(def, i, override) or
									resolve_tile(def, 1, override)
							if not resources[i] then
								return nil
							end
						end
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
					double_sided, nil, group, connect, masked)
		end
		if not kind then
			return nil
		end
		local resources = {}
		for i = 1, 6 do
			-- tiles says which of the definition's tiles this face wears,
			-- which is what a facedir comes to for a cube
			resources[i] = resolve_tile(def, tiles and tiles[i] or i, override)
			if not resources[i] then
				return nil
			end
		end
		-- And how far the texture is turned inside the face it ended up on
		local turns = facedir and facedir ~= 0 and
				shapes.FACEDIR_TILE_TURNS[facedir + 1] or nil
		return add_cube(reg, name or def.name, resources, kind, nil, nil,
				turns, group, connect)
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
		local light_ids = {}
		-- Air's own definition is not among the ones a server sends, so
		-- seed it the way the node map above seeds it: light passes through
		-- air, and everything not in here is taken to block it, which is
		-- what a node drawn as the placeholder cube does.
		local light_through = {[CONTENT_AIR] = true}
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
			-- Luanti's PointabilityType: 0 is not pointable, 1 is, and 2
			-- stops a ray without being pointed at. Those two values are
			-- that way round because they used to be a boolean.
			pointable[id] = def.pointable ~= 0
			liquid[id] = def.liquid_type ~= nil and
					def.liquid_type ~= NODEDEF_LIQUID_NONE
			if def.post_effect_color and def.post_effect_color.a > 0 then
				post_effect[id] = def.post_effect_color
			end
			local voxel = build_voxel(new_reg, def, resolve_tile, nil)
			if voxel then
				map[id] = voxel
				if voxel ~= VOXEL_AIR then
					cubes = cubes + 1
				end
			end
			-- Anything left out keeps map_default, the placeholder cube

			-- A definition whose param2 is a palette index is drawn in one
			-- colour per index, and which colour that is is only known once
			-- a voxel with that param2 turns up: see register_pairs().
			local step = COLOR_STEP[def.param_type_2]
			local colors = nil
			if step and def.palette_name ~= "" and palette_colors then
				colors = palette_colors(def.palette_name)
				if colors and #colors < 2 then
					colors = nil
				end
			end
			local facing = FACING[def.param_type_2]
			-- A flowing liquid's param2 says how high its surface stands, so
			-- it wants a voxel per level the same way a facedir wants one per
			-- direction. The range is how many of the eight levels the liquid
			-- spends on the top of a voxel.
			local liquid_range = def.drawtype == DRAWTYPE_FLOWINGLIQUID and
					(def.liquid_range or 8) or nil

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

			if voxel and (colors or facing or liquid_range) then
				new_param2_look[id] = {def = def, step = step,
						colors = colors, facing = facing,
						liquid_range = liquid_range}
			end
		end

		-- What register_pairs() calls for a pair it has not seen. The voxel
		-- goes into the registry that is current, which is why this is made
		-- here rather than kept as a method: a new set of definitions
		-- replaces the registry and everything built into it.
		build_pair = function(entry, id, p2, key)
			-- Luanti stretches a palette to 256 entries by repeating each
			-- pixel, and indexes that with param2's high bits
			local index = entry.colors and
					math.floor((p2 - p2 % entry.step) *
					#entry.colors / 256) + 1 or nil
			local facedir = shapes.facedir_of(entry.facing, p2)
			-- A wallmounted shape wants the direction itself, not only the
			-- facedir it comes to: which of its three boxes it is made of
			-- depends on it
			local wall = entry.facing == "wallmounted" and p2 % 8 or nil
			-- A liquid at the top level is a whole cube, which the id's own
			-- voxel already is -- and one whose faces against the next one
			-- are culled, which a shape's are not
			local liquid_top = entry.liquid_range and
					shapes.liquid_top(entry.liquid_range, p2) or nil
			if liquid_top and liquid_top >= 0.5 then
				liquid_top = nil
			end
			-- Two param2 values that come to the same colour, the same facing
			-- and the same liquid level are the same voxel
			local cache_key = id.."/"..tostring(index).."/"..
					tostring(facedir).."/"..tostring(wall).."/"..
					tostring(liquid_top)
			-- Nothing different about it: the voxel the id already has, which
			-- was built facing 0 and, if wallmounted, on the floor
			-- Whatever this writes, the map is not the one that was
			-- compiled for the last block
			self.pair_map_version = self.pair_map_version + 1
			if not index and not liquid_top and
					(not facedir or facedir == 0) then
				self.pair_map[key] = self.node_map[id] or false
				return
			end
			local voxel = pair_voxel[cache_key]
			if voxel == nil then
				voxel = build_voxel(self.voxel_reg, entry.def, resolve_tile,
						index and entry.colors[index] or nil,
						entry.def.name.."^"..cache_key,
						facedir, wall, liquid_top) or false
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
		-- else to show, and SetViewport() takes no nil
		magic.renderer.numViewports = 0
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
	end

	return self
end

M.BLOCKSIZE = BLOCKSIZE
M.VOXEL_AIR = VOXEL_AIR
M.VOXEL_PLACEHOLDER = VOXEL_PLACEHOLDER

return M
-- vim: set noet ts=4 sw=4:
