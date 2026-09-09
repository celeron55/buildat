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
-- simplified: a node box, a mesh and a liquid are not cubes, and are drawn as
-- one anyway -- a slab is a whole block, a fence is a solid post -- because a
-- block of the right texture reads far better than the grey placeholder a
-- shape nothing can build gets. What stays a placeholder is the draw types
-- whose texture would be nonsense on a cube: plants, torches, signs, rails
-- and fire, which are quads rather than boxes. The upgrade path is a
-- per-voxel geometry primitive; see the plan's M12.
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
-- nodedef.lua's M.LIQUID_NONE, which is what a node that is not a liquid has
local NODEDEF_LIQUID_NONE = 0

-- How many blocks to mesh per frame. Meshing itself is on a worker thread, but
-- packing the volume and handing it over is not, so a burst of a hundred
-- blocks arriving at once would otherwise be one long frame.
local MESH_PER_FRAME = 4

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
			"Techniques/VoxelUnlit.xml")

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

	-- A voxel whose six faces are the given resource names, in buildat's face
	-- order (+Y, -Y, +X, -X, +Z, -Z), which is also Luanti's tile order.
	--
	-- With shape given it is not a cube at all: the quads are the voxel's own
	-- geometry, it draws no cube faces of its own, and its neighbours draw
	-- theirs against it. shapes.lua is what builds those.
	local function add_cube(voxel_reg, name, resources, kind, shape,
			double_sided)
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
	self.atlas_reg = buildat.createAtlasRegistry()

	-- key -> {x=, y=, z=, param0=, param1=, node=}
	local blocks = {}
	-- key -> true for blocks whose mesh is out of date
	local dirty = {}
	local dirty_count = 0

	self.node_map = PLACEHOLDER_MAP
	self.node_map_default = VOXEL_PLACEHOLDER
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
			}
		end
		if self.use_skylight then
			sources[#sources + 1] = {
				data = block.param1, format = "u8",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0}, map = LIGHT_MAP, field = "light",
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
				}
				if self.pair_count > 0 and n.param2 then
					sources[#sources + 1] = {
						data = n.param0, format = "u16be",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						second = {data = n.param2, format = "u8",
								scale = PAIR_SCALE},
						map = self.pair_map,
					}
				end
				if self.use_skylight then
					sources[#sources + 1] = {
						data = n.param1, format = "u8",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						map = LIGHT_MAP, field = "light",
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
			local level = levels[hi * 256 + lo]
			if level then
				out = out or {}
				-- The index order is x fastest, then y, then z
				local x = i % BLOCKSIZE
				local y = math.floor(i / BLOCKSIZE) % BLOCKSIZE
				local z = math.floor(i / (BLOCKSIZE * BLOCKSIZE))
				out[#out + 1] = {
					block.x * BLOCKSIZE + x,
					block.y * BLOCKSIZE + y,
					block.z * BLOCKSIZE + z,
					level,
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
				held.light.color = magic.Color(LIGHT_COLOR.r, LIGHT_COLOR.g,
						LIGHT_COLOR.b)
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
		block.lights = find_lights(block)
		lights_stale = true
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
			return self.node_solid[id] ~= false
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
	local pointed_node = scene:CreateChild("Pointed")
	do
		local cg = pointed_node:CreateComponent("CustomGeometry")
		cg:BeginGeometry(0, magic.TRIANGLE_LIST)
		cg:SetNumGeometries(1)
		local color = magic.Color(0.12, 0.36, 0.12)
		local function face(x0, z0, x1, z1)
			local y = 0.502 -- Just outside the node, so it does not z-fight
			local corners = {
				{x0, z1}, {x1, z1}, {x1, z0}, {x1, z0}, {x0, z0}, {x0, z1},
			}
			for _, c in ipairs(corners) do
				cg:DefineVertex(magic.Vector3(c[1], y, c[2]))
				cg:DefineColor(color)
			end
		end
		local d = 0.502
		local w = 1.0 / 16
		face(-d, d - w, d, d)
		face(-d, -d, d, -d + w)
		face(d - w, -d + w, d, d - w)
		face(-d, -d + w, -d + w, d - w)
		cg:Commit()
		local m = magic.Material.new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/NoTextureVColMultiply.xml"))
		cg:SetMaterial(0, m)
		pointed_node.enabled = false
	end

	--
	-- The things in the world that are not nodes
	--

	-- A scene node per object, kept by id
	local object_nodes = {}
	local object_technique = magic.cache:GetResource("Technique",
			"Techniques/UnlitAlphaMask.xml")
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

	-- What an object is drawn as.
	--
	-- simplified: a box with the object's first texture on it, whatever its
	-- visual says. Luanti draws a mesh for a mob, a billboard for a dropped
	-- item and a cube for a few things, and Urho3D reads none of the model
	-- formats Luanti's meshes come in -- but a box wearing a cow's texture
	-- reads as a cow, where nothing at all reads as nothing at all. The
	-- upgrade path is a billboard for the sprite visuals, which is a quad
	-- turned to the camera, and a converter or a loader for the meshes.
	--
	-- obj is what objects.lua parsed; resource(obj) says what it is drawn
	-- wearing, as a resource name, or nil for an object whose texture is not
	-- there yet.
	function self:set_object(obj, resource)
		local entry = object_nodes[obj.id]
		if not entry then
			local node = scene:CreateChild("object_"..obj.id)
			local model = node:CreateComponent("StaticModel")
			model:SetModel(box_model)
			model.castShadows = false
			entry = {node = node, model = model}
			object_nodes[obj.id] = entry
		end
		local props = obj.props
		-- Where the box is and how big: the object's collision box, which is
		-- in nodes and is not centred on the object's own position
		local sx, sy, sz = 0.6, 1.8, 0.6
		local cy = 0.9
		if props and props.collision_min and props.collision_max then
			sx = math.max(0.05, props.collision_max[1] - props.collision_min[1])
			sy = math.max(0.05, props.collision_max[2] - props.collision_min[2])
			sz = math.max(0.05, props.collision_max[3] - props.collision_min[3])
			cy = (props.collision_max[2] + props.collision_min[2]) / 2
		end
		entry.offset = cy
		entry.node.scale = magic.Vector3(sx, sy, sz)
		entry.node.position = magic.Vector3(obj.position[1],
				obj.position[2] + cy, obj.position[3])
		entry.node.rotation = magic.Quaternion(0, -(obj.yaw or 0), 0)
		light_object(entry, obj.position[1], obj.position[2], obj.position[3])

		if obj.visual_stale or not entry.textured then
			obj.visual_stale = false
			local name = resource(obj)
			if name then
				local material = magic.Material.new()
				material:SetTechnique(0, object_technique)
				material:SetTexture(0, magic.cache:GetResource("Texture2D",
						name))
				entry.model.material = material
				entry.material = material
				entry.light_key = nil
				entry.textured = true
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
	function self:place_objects(objects)
		for id, obj in pairs(objects) do
			local entry = object_nodes[id]
			if entry and obj.position then
				entry.node.position = magic.Vector3(obj.position[1],
						obj.position[2] + (entry.offset or 0),
						obj.position[3])
				entry.node.rotation = magic.Quaternion(0,
						-(obj.yaw or 0), 0)
				light_object(entry, obj.position[1], obj.position[2],
						obj.position[3])
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
	function self:set_pointed(under, above)
		if not under or not above then
			pointed_node.enabled = false
			return
		end
		pointed_node.position = magic.Vector3(under[1], under[2], under[3])
		local dx = above[1] - under[1]
		local dy = above[2] - under[2]
		local dz = above[3] - under[3]
		if dx > 0 then
			pointed_node.rotation = magic.Quaternion(90, 0, -90)
		elseif dx < 0 then
			pointed_node.rotation = magic.Quaternion(90, 0, 90)
		elseif dy > 0 then
			pointed_node.rotation = magic.Quaternion(0, 0, 0)
		elseif dy < 0 then
			pointed_node.rotation = magic.Quaternion(0, 0, -180)
		elseif dz > 0 then
			pointed_node.rotation = magic.Quaternion(90, 0, 0)
		else
			pointed_node.rotation = magic.Quaternion(-90, 0, 0)
		end
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
	function self:set_daylight(factor)
		daylight = factor
		zone.ambientColor = sunlight_color(factor)
		-- What is behind the world, which the fog fades into. The game's own
		-- horizon colour when it has said one, between its night and day
		-- shades by how much daylight there is; the ramp bottoms out at
		-- 0.175, so that is what counts as night.
		local r, g, b = FOG.r * factor, FOG.g * factor, FOG.b * factor
		if sky and sky.day_horizon and sky.night_horizon then
			local t = (factor - 0.175) / (1 - 0.175)
			t = t < 0 and 0 or (t > 1 and 1 or t)
			r = (sky.night_horizon[1] + (sky.day_horizon[1] -
					sky.night_horizon[1]) * t) / 255
			g = (sky.night_horizon[2] + (sky.day_horizon[2] -
					sky.night_horizon[2]) * t) / 255
			b = (sky.night_horizon[3] + (sky.day_horizon[3] -
					sky.night_horizon[3]) * t) / 255
		elseif sky and sky.bgcolor then
			r = sky.bgcolor[1] / 255 * factor
			g = sky.bgcolor[2] / 255 * factor
			b = sky.bgcolor[3] / 255 * factor
		end
		zone.fogColor = magic.Color(r, g, b)
	end

	-- What the game says the sky looks like; client.lua's on_sky hands this
	-- over. Only the colours are used: the sun, the moon, the stars and a
	-- skybox's six textures are not drawn.
	function self:set_sky(new_sky)
		sky = new_sky
		self:set_daylight(daylight)
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
	-- end up on.
	local function build_voxel(reg, def, resolve_tile, override, name,
			facedir, wall)
		local kind = CUBE_DRAWTYPES[def.drawtype]
		local shape, double_sided = shapes.for_node(def, facedir, wall)
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
		return add_cube(reg, name or def.name, resources, kind)
	end

	-- Returns how many node ids came out as their own cube.
	function self:set_node_definitions(defs, resolve_tile, palette_colors)
		local new_reg = base_registry()
		local map = {
			[CONTENT_AIR] = VOXEL_AIR,
			[CONTENT_IGNORE] = VOXEL_AIR,
		}
		local cubes = 0
		local light_ids = {}
		local solid = {}
		local liquid = {}
		local pointable = {}
		self.pair_map = {}
		self.pair_count = 0
		pair_voxel = {}
		param2_look = {}
		pair_epoch = pair_epoch + 1
		for id, def in pairs(defs) do
			solid[id] = def.walkable
			if def.light_source and def.light_source > 0 then
				light_ids[id] = def.light_source
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
			if voxel and (colors or facing) then
				param2_look[id] = {def = def, step = step, colors = colors,
						facing = facing}
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
			-- Two param2 values that come to the same colour and the same
			-- facing are the same voxel
			local cache_key = id.."/"..tostring(index).."/"..
					tostring(facedir).."/"..tostring(wall)
			-- Nothing different about it: the voxel the id already has, which
			-- was built facing 0 and, if wallmounted, on the floor
			if not index and (not facedir or facedir == 0) then
				self.pair_map[key] = self.node_map[id] or false
				return
			end
			local voxel = pair_voxel[cache_key]
			if voxel == nil then
				voxel = build_voxel(self.voxel_reg, entry.def, resolve_tile,
						index and entry.colors[index] or nil,
						entry.def.name.."^"..cache_key,
						facedir, wall) or false
				pair_voxel[cache_key] = voxel
			end
			-- false for a pair whose textures are not there: remembered so
			-- that it is not built again for every voxel in every block
			self.pair_map[key] = voxel or false
			if voxel then
				self.pair_count = self.pair_count + 1
			end
		end

		self.voxel_reg = new_reg
		-- A fresh atlas registry: the old one holds atlases built for the old
		-- registry's segment ids
		self.atlas_reg = buildat.createAtlasRegistry()
		self.node_map = map
		self.node_light = light_ids
		self.node_solid = solid
		self.node_liquid = liquid
		self.node_pointable = pointable
		self:invalidate_all()
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
		while meshed < MESH_PER_FRAME do
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
