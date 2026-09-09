-- Buildat: extension/luanti_client/nodedef.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What a node id means, out of Luanti's NODEDEF.
--
-- The packet is
--   u8 version | u16 count | u32 string
-- and inside that string, per node,
--   u16 id | u16 string wrapper
-- Every node's definition is in its own length-prefixed wrapper, so only the
-- front of it has to be understood: the name, the draw type and the six tiles.
-- The rest of the wrapper -- physics, liquids, node boxes, sounds -- is skipped
-- whole, which is also what makes this survive a server that knows a newer
-- ContentFeatures version than the one written here.
--
-- The parsing goes down to TileDef because a tile is variable-length: what the
-- flags say decides whether a colour, a scale and an align style follow, and
-- the six tiles cannot be found without reading through them.

local M = {}

-- Luanti's NodeDrawType, in order
M.DRAWTYPE = {
	NORMAL = 0,
	AIRLIKE = 1,
	LIQUID = 2,
	FLOWINGLIQUID = 3,
	GLASSLIKE = 4,
	ALLFACES = 5,
	ALLFACES_OPTIONAL = 6,
	TORCHLIKE = 7,
	SIGNLIKE = 8,
	PLANTLIKE = 9,
	FENCELIKE = 10,
	RAILLIKE = 11,
	NODEBOX = 12,
	GLASSLIKE_FRAMED = 13,
	FIRELIKE = 14,
	GLASSLIKE_FRAMED_OPTIONAL = 15,
	MESH = 16,
	PLANTLIKE_ROOTED = 17,
}

-- The oldest ContentFeatures a server may send us; anything below this has a
-- different layout in the part that is read here
local CONTENTFEATURES_VERSION = 13

-- TileDef flags, from nodedef.cpp
local TILE_FLAG_HAS_COLOR = 8
local TILE_FLAG_HAS_SCALE = 16
local TILE_FLAG_HAS_ALIGN_STYLE = 32

local function has_flag(flags, flag)
	return flags % (flag * 2) >= flag
end

local function read_tiledef(r)
	local version = r:u8()
	if version < 6 then
		error("luanti_client/nodedef: TileDef version "..version)
	end
	local name = r:string()
	-- Animation: the type decides what follows it
	local animation_type = r:u8()
	if animation_type == 1 then -- Vertical frames
		r:u16()
		r:u16()
		r:f32()
	elseif animation_type == 2 then -- 2D sheet
		r:u8()
		r:u8()
		r:f32()
	end
	local flags = r:u16()
	if has_flag(flags, TILE_FLAG_HAS_COLOR) then
		r:skip(3)
	end
	if has_flag(flags, TILE_FLAG_HAS_SCALE) then
		r:u8()
	end
	if has_flag(flags, TILE_FLAG_HAS_ALIGN_STYLE) then
		r:u8()
	end
	return {name = name, animated = animation_type ~= 0}
end

-- Luanti's LiquidType
M.LIQUID_NONE = 0
M.LIQUID_FLOWING = 1
M.LIQUID_SOURCE = 2

-- How many extra tiles follow the six: six overlays, and six special tiles
-- (which is what a flowing liquid's surface and a rooted plant's top are)
local CF_SPECIAL_COUNT = 6

-- One node's wrapper. Read as far as the fields anything here uses; the
-- caller has already cut the wrapper to length, so the rest -- node boxes,
-- sounds, the legacy fields -- is dropped. The order is
-- ContentFeatures::serialize() in Luanti's nodedef.cpp.
local function read_node(r)
	local version = r:u8()
	if version < CONTENTFEATURES_VERSION then
		error("luanti_client/nodedef: ContentFeatures version "..version)
	end
	local def = {}
	def.name = r:string()
	def.groups = {}
	for _ = 1, r:u16() do
		local group_name = r:string()
		def.groups[group_name] = r:s16()
	end
	r:u8() -- param_type
	def.param_type_2 = r:u8()
	def.drawtype = r:u8()
	r:string() -- mesh
	r:f32() -- visual_scale
	local tile_count = r:u8()
	if tile_count ~= 6 then
		error("luanti_client/nodedef: "..tile_count.." tiles, expected 6")
	end
	-- Luanti's tile order is +Y, -Y, +X, -X, +Z, -Z, which is also the order
	-- buildat's VoxelDefinition.textures is in
	def.tiles = {}
	for i = 1, 6 do
		def.tiles[i] = read_tiledef(r)
	end
	-- The overlay of a tile is drawn on top of it; the special tiles belong to
	-- draw types that have surfaces the six do not cover
	def.overlays = {}
	for i = 1, 6 do
		def.overlays[i] = read_tiledef(r)
	end
	local special_count = r:u8()
	if special_count ~= CF_SPECIAL_COUNT then
		error("luanti_client/nodedef: "..special_count.." special tiles")
	end
	def.special = {}
	for i = 1, special_count do
		def.special[i] = read_tiledef(r)
	end
	r:u8() -- alpha for legacy clients; the real one is further down
	-- The colour a tile is multiplied by, for a node whose paramtype2 is not
	-- a palette index
	def.color = {r:u8(), r:u8(), r:u8()}
	-- The palette a "color" paramtype2 indexes, as a media name
	def.palette_name = r:string()
	def.waving = r:u8()
	r:u8() -- connect_sides
	for _ = 1, r:u16() do
		r:u16() -- connects_to ids
	end
	r:skip(4) -- post_effect_color
	def.leveled = r:u8()
	r:u8() -- light_propagates
	def.sunlight_propagates = r:u8() ~= 0
	def.light_source = r:u8()
	r:u8() -- is_ground_content
	-- Interaction: what the player can do to this node, and what it does back
	def.walkable = r:u8() ~= 0
	def.pointable = r:u8()
	def.diggable = r:u8() ~= 0
	def.climbable = r:u8() ~= 0
	def.buildable_to = r:u8() ~= 0
	def.rightclickable = r:u8() ~= 0
	def.damage_per_second = r:u32()
	def.liquid_type = r:u8()
	r:string() -- liquid_alternative_flowing
	r:string() -- liquid_alternative_source
	def.liquid_viscosity = r:u8()
	r:u8() -- liquid_renewable
	def.liquid_range = r:u8()
	def.drowning = r:u8()
	def.floodable = r:u8() ~= 0
	return def
end

-- parse(data) -> {[id] = def}, count
--
-- A def holds name, groups, param_type_2, drawtype, the six tiles and their
-- overlays, the colour and palette, and what the player can do to the node:
-- walkable, climbable, diggable, pointable, buildable_to, liquid_type.
--
-- data is the decompressed NODEDEF payload. A node whose definition cannot be
-- read is left out rather than stopping the rest: one node drawn as a
-- placeholder is better than no world.
function M.parse(serialize, data, log)
	local r = serialize.reader(data)
	local version = r:u8()
	if version < 1 then
		error("luanti_client/nodedef: version "..version)
	end
	local count = r:u16()
	local inner = serialize.reader(r:longstring())
	local defs = {}
	local failed = 0
	for _ = 1, count do
		local id = inner:u16()
		local wrapper = serialize.reader(inner:string())
		local ok, def = pcall(read_node, wrapper)
		if ok then
			defs[id] = def
		else
			failed = failed + 1
			if failed == 1 and log then
				log:warning("nodedef: could not read node "..id..": "..
						tostring(def))
			end
		end
	end
	if failed > 0 and log then
		log:warning("nodedef: "..failed.." of "..count..
				" node definitions could not be read")
	end
	return defs, count
end

return M
-- vim: set noet ts=4 sw=4:
