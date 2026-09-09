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
	[16] = "ground", -- NDT_MESH
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

	local FOG = {r = 0.60, g = 0.72, b = 0.88}

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

	local function mesh_block(key)
		local block = blocks[key]
		if not block then
			return
		end
		local t0 = buildat.get_time_us()
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
		else
			blocks[key] = {
				x = block.x, y = block.y, z = block.z,
				param0 = block.param0, param1 = block.param1,
			}
		end
		mark_dirty(key)
		for _, d in ipairs(NEIGHBOURS) do
			mark_dirty(block_key(block.x + d[1], block.y + d[2],
					block.z + d[3]))
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
	-- obj is what objects.lua parsed; texture(name) turns one of its texture
	-- names into a resource name, or nil.
	function self:set_object(obj, texture)
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

		if obj.visual_stale or not entry.textured then
			obj.visual_stale = false
			local name = props and props.textures and props.textures[1]
			local resource = name and texture(name) or nil
			if resource then
				local material = magic.Material.new()
				material:SetTechnique(0, object_technique)
				material:SetTexture(0, magic.cache:GetResource("Texture2D",
						resource))
				entry.model.material = material
				entry.textured = true
			end
		end
		return entry.wanted_texture
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
	function self:set_node(x, y, z, param0, param1)
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
		zone.ambientColor = sunlight_color(factor)
		zone.fogColor = magic.Color(FOG.r * factor, FOG.g * factor,
				FOG.b * factor)
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
	-- Returns how many node ids came out as their own cube.
	function self:set_node_definitions(defs, resolve_tile)
		local new_reg = base_registry()
		local map = {
			[CONTENT_AIR] = VOXEL_AIR,
			[CONTENT_IGNORE] = VOXEL_AIR,
		}
		local cubes = 0
		local solid = {}
		local liquid = {}
		local pointable = {}
		for id, def in pairs(defs) do
			solid[id] = def.walkable
			-- Luanti's PointabilityType: 0 is not pointable, 1 is, and 2
			-- stops a ray without being pointed at. Those two values are
			-- that way round because they used to be a boolean.
			pointable[id] = def.pointable ~= 0
			liquid[id] = def.liquid_type ~= nil and
					def.liquid_type ~= NODEDEF_LIQUID_NONE
			local kind = CUBE_DRAWTYPES[def.drawtype]
			local shape, double_sided = shapes.for_node(def)
			if def.drawtype == DRAWTYPE_AIRLIKE then
				map[id] = VOXEL_AIR
			elseif shape then
				-- Only the tiles the shape uses have to be there: a plant
				-- wears one texture and would be held back by the other five
				local resources = {}
				local ok = true
				for _, quad in ipairs(shape) do
					local i = quad.tile
					if not resources[i] then
						resources[i] = resolve_tile(def, i)
						if not resources[i] then
							ok = false
							break
						end
					end
				end
				if ok then
					local first = nil
					for i = 1, 6 do
						first = first or resources[i]
					end
					for i = 1, 6 do
						resources[i] = resources[i] or first
					end
					map[id] = add_cube(new_reg, def.name, resources, kind,
							shape, double_sided)
					cubes = cubes + 1
				end
			elseif kind then
				local resources = {}
				for i = 1, 6 do
					resources[i] = resolve_tile(def, i)
					if not resources[i] then
						break
					end
				end
				if resources[6] then
					map[id] = add_cube(new_reg, def.name, resources, kind)
					cubes = cubes + 1
				end
			end
			-- Anything left out keeps map_default, the placeholder cube
		end
		self.voxel_reg = new_reg
		-- A fresh atlas registry: the old one holds atlases built for the old
		-- registry's segment ids
		self.atlas_reg = buildat.createAtlasRegistry()
		self.node_map = map
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
