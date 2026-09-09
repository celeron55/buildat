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

-- A texture name is either a plain file name or an expression in Luanti's
-- texture modifier language: "grass.png^[colorize:#ff0000:128", "[combine:...",
-- "(a.png^b.png)^c.png". A resource cache can only be handed a file name, so
-- what comes back here is the file name a texture is built on:
--
-- - a plain name, as it is
-- - the first element of a "^" chain, with the overlays dropped. This is what
--   a grass block's sides are ("default_dirt.png^mcl_dirt_grass_shadow.png"),
--   and dirt without its shading is much closer than no texture at all.
-- - nil for anything that does not start with a file name, which is where the
--   modifier language really begins: "[combine:...", "(a.png^b.png)^c.png".
--
-- simplified: dropping the overlays. Doing better means interpreting that
-- language and compositing images, which is its own piece of work; the
-- upgrade path is a modifier interpreter that produces an image, with this
-- function's result as the base it starts from.
function M.plain_texture_name(name)
	local base = name:match("^([^%^%[%(%)]+)")
	if not base or base == "" then
		return nil
	end
	-- A media name is a file name, never a path
	if base:find("[/\\]") then
		return nil
	end
	return base
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

-- One node's wrapper. Only what is needed to draw a cube is read; the caller
-- has already cut the wrapper to length, so what is left over is dropped.
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
	return def
end

-- parse(data) -> {[id] = {name=, drawtype=, tiles={6}, groups=, param_type_2=}}
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

-- Every plain texture name the definitions name, as a set. This is what has to
-- be asked of the server; the rest of its media is sounds, models and
-- textures nothing here draws.
function M.texture_names(defs)
	local names = {}
	for _, def in pairs(defs) do
		for _, tile in ipairs(def.tiles) do
			local name = M.plain_texture_name(tile.name)
			if name then
				names[name] = true
			end
		end
	end
	return names
end

return M
-- vim: set noet ts=4 sw=4:
