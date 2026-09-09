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
local EDGEMATERIAL_GLASS = 10
local CUBE_DRAWTYPES = {
	[0] = "ground",  -- NDT_NORMAL
	[2] = "ground",  -- NDT_LIQUID
	[3] = "ground",  -- NDT_FLOWINGLIQUID
	[4] = "glass",   -- NDT_GLASSLIKE
	[5] = "allfaces",-- NDT_ALLFACES, leaves
	[6] = "allfaces",-- NDT_ALLFACES_OPTIONAL
	[13] = "glass",  -- NDT_GLASSLIKE_FRAMED
	[15] = "glass",  -- NDT_GLASSLIKE_FRAMED_OPTIONAL
	[16] = "ground", -- NDT_MESH, drawn as its selection box; see shapes.lua
}
local DRAWTYPE_AIRLIKE = 1
local DRAWTYPE_FLOWINGLIQUID = 3
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

	local self = {}

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

	-- The mesher sets no technique on skylit geometry -- only the game knows
	-- which shader reads what it packed -- so every block's materials get
	-- this one once they exist.
	local function apply_technique(node)
		local cg = node:GetComponent("CustomGeometry")
		if not cg then
			return
		end
		local i = 0
		while true do
			local m = cg:GetMaterial(i)
			if m == nil then
				break
			end
			m:SetTechnique(0, technique)
			i = i + 1
		end
	end

	local camera_node = scene:CreateChild("Camera")
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.1
	camera.farClip = far_clip
	camera.fov = 72
	self.camera_node = camera_node
	self.camera = camera

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

	-- play_sound(id, spec, resource)
	--
	-- spec is what sounds.lua read out of PLAY_SOUND and resource the name
	-- of one file of the group it asked for -- picking which one is the
	-- caller's, because which files there are is the media's business.
	--
	-- simplified: a sound attached to an object plays where the object was
	-- when it started rather than following it, and start_time is ignored,
	-- because seeking is not in the sandbox's SoundSource. A game uses the
	-- first for a mob's noises, which are short, and the second for
	-- background music a player rejoins in the middle of.
	function self:play_sound(id, spec, resource)
		local sound = magic.cache:GetResource("Sound", resource)
		if not sound then
			return false
		end
		sound.looped = spec.loop and true or false
		local node = scene:CreateChild("sound_"..tostring(id))
		local source
		if spec.location == sounds_proto.LOCAL then
			source = node:CreateComponent("SoundSource")
		else
			node.position = magic.Vector3(spec.pos[1], spec.pos[2],
					spec.pos[3])
			source = node:CreateComponent("SoundSource3D")
			source.nearDistance = SOUND_NEAR
			source.farDistance = SOUND_FAR
		end
		source.soundType = magic.SOUND_EFFECT
		local gain = spec.gain or 1.0
		-- A fade on the packet means it starts silent and comes up to the
		-- gain it asked for
		local entry = {node = node, source = source, gain = gain,
				started = false}
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

	-- A voxel whose six faces are the given resource names, in buildat's face
	-- order (+Y, -Y, +X, -X, +Z, -Z), which is also Luanti's tile order.
	--
	-- With shape given it is not a cube at all: the quads are the voxel's own
	-- geometry, it draws no cube faces of its own, and its neighbours draw
	-- theirs against it. shapes.lua is what builds those.
	-- turns is nil or six quarter turns, one per face: how far the texture is
	-- turned inside its own face. See VoxelDefinition.tile_turns.
	local function add_cube(voxel_reg, name, resources, kind, shape,
			double_sided, turns)
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
		if kind == "glass" then
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
		if shape then
			vdef.shape = shape
			vdef.shape_double_sided = double_sided and true or false
			vdef.face_draw_type =
					buildat.VoxelDefinition.FACEDRAWTYPE_NEVER
			vdef.edge_material_id =
					buildat.VoxelDefinition.EDGEMATERIALID_EMPTY
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
					return {x, y, z}, last
				end
				last = {x, y, z}
			end
		end
		return nil
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
		material:SetTexture(0, magic.cache:GetResource("Texture2D", resource))
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

	-- A scene node per object, kept by id
	local object_nodes = {}
	local object_technique = magic.cache:GetResource("Technique",
			"luanti_client/res/UnlitAlphaMask.xml")
	local box_model = magic.cache:GetResource("Model", "Models/Box.mdl")

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
		if not entry.material then
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

	-- What an object is drawn as.
	--
	-- simplified: a sprite visual is a billboard and everything else is a
	-- box with the object's first texture on it, whatever its visual says.
	-- Luanti draws a mesh for a mob and a cube for a few things, and Urho3D
	-- reads none of the model formats Luanti's meshes come in -- but a box
	-- wearing a cow's texture reads as a cow, where nothing at all reads as
	-- nothing at all. The upgrade path is a converter or a loader for the
	-- meshes, which are .b3d.
	--
	-- obj is what objects.lua parsed; resource(obj) says what it is drawn
	-- wearing, as a resource name, or nil for an object whose texture is not
	-- there yet.
	function self:set_object(obj, resource)
		local props = obj.props
		local sprite = props ~= nil and SPRITE_VISUALS[props.visual] or false
		local entry = object_nodes[obj.id]
		-- A visual that changed changes which component draws it
		if entry and entry.sprite ~= sprite then
			scene:RemoveChild(entry.node)
			entry = nil
			object_nodes[obj.id] = nil
		end
		if not entry then
			local node = scene:CreateChild("object_"..obj.id)
			entry = {node = node, sprite = sprite}
			if sprite then
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
		if sprite then
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
		entry.node.rotation = magic.Quaternion(0, -(obj.yaw or 0), 0)
		entry.at_x, entry.at_y, entry.at_z = obj.position[1], obj.position[2],
				obj.position[3]
		entry.at_yaw = obj.yaw or 0
		entry.lit_at = daylight
		light_object(entry, obj.position[1], obj.position[2], obj.position[3])

		if obj.visual_stale or not entry.textured then
			obj.visual_stale = false
			-- An object whose texture is not there yet wears the placeholder
			-- rather than nothing: a box with no material at all is drawn
			-- flat white, which reads as a hole in the world
			local own = resource(obj)
			local name = own or (not entry.material and texture)
			if name then
				local material = magic.Material.new()
				material:SetTechnique(0, object_technique)
				material:SetTexture(0, magic.cache:GetResource("Texture2D",
						name))
				entry.model.material = material
				entry.material = material
				entry.light_key = nil
				-- The placeholder does not count as textured: the object's
				-- own texture may still turn up
				entry.textured = own ~= nil
			end
		end
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
	function self:place_objects(objects)
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
				if yaw ~= entry.at_yaw then
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
	function self:set_pointed(under, above)
		if not under or not above then
			pointed_node.enabled = false
			return
		end
		pointed_node.position = magic.Vector3(under[1], under[2], under[3])
		pointed_node.enabled = true
	end

	-- One node the server changed, in node coordinates. Patches the block's
	-- parameter arrays in place; a node on a block's edge is part of the
	-- neighbour's border, so that mesh goes out of date too.
	-- param1 may be nil, which means the node became air and its light has
	-- to be worked out here.
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
		return true
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
			-- Luanti's clouds are the daylight's own colour
			sky_material:SetShaderParameter("CloudColor", magic.Color(
					0.9 * brightness + 0.05, 0.92 * brightness + 0.05,
					0.95 * brightness + 0.06))
			-- The stars come out as the sky goes dark
			sky_material:SetShaderParameter("StarFade",
					math.max(0, math.min(1, (0.25 - brightness) * 6)))
		end
	end

	function self:set_sky(new_sky)
		sky = new_sky
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
		local shape, double_sided = shapes.for_node(def, facedir, wall,
				read_mesh and read_mesh(def) or nil, liquid_top)
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
			local first = nil
			for i = 1, 6 do
				first = first or resources[i]
			end
			for i = 1, 6 do
				resources[i] = resources[i] or first
			end
			return add_cube(reg, name or def.name, resources, kind, shape,
					double_sided)
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
				turns)
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
		local collision = {}
		local solid = {}
		local liquid = {}
		local pointable = {}
		local new_param2_look = {}

		local function one_definition(id, def)
			solid[id] = def.walkable
			if def.light_source and def.light_source > 0 then
				light_ids[id] = {level = def.light_source,
						color = light_color(resolve_tile(def, 1))}
			end
			-- Luanti's PointabilityType: 0 is not pointable, 1 is, and 2
			-- stops a ray without being pointed at. Those two values are
			-- that way round because they used to be a boolean.
			pointable[id] = def.pointable ~= 0
			liquid[id] = def.liquid_type ~= nil and
					def.liquid_type ~= NODEDEF_LIQUID_NONE
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
			self.node_collision = collision
			self.node_solid = solid
			self.node_liquid = liquid
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
