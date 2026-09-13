-- Buildat: builtin/luanti/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The module's client half, and the first piece of it: the textures a
-- Luanti game names with an expression rather than with a file.
--
-- A tile in a node definition can be "default_dirt.png^grass_side.png" or
-- "[combine:32x16:0,0=a.png" -- a small language over raster operations. The
-- server cannot resolve them: what they are for is the client's own texture
-- size, filtering and texture packs, and two of them are resolved at runtime
-- (the crack over a node being dug, a palette's colour). So the server sends
-- the expressions and this composes them, under the same names the voxel
-- definitions were registered with.
--
-- texmod.lua reads the language and hands back compose_image() operations;
-- everything here is the files.
local log = buildat.Logger("luanti")
local cereal = require("buildat/extension/cereal")
local voxelworld = require("buildat/module/voxelworld")

local M = {}

-- Beside this file: a module's client half is served whole, and this is how
-- one file of it reaches another
local ok, err, texmod = buildat.run_script_file("luanti/texmod.lua")
if not ok or type(texmod) ~= "table" then
	error("luanti: could not load texmod.lua: " .. tostring(err))
end

-- Where the composed textures go: a resource directory of its own, under the
-- cache, which is the only place compose_image() writes and
-- add_resource_dir() adds. A file lies in it under its resource name, so the
-- prefix is a directory here too; both are made by the first write.
local RESOURCE_DIR = buildat.get_cache_path() .. "/luanti_res"
local RESOURCE_PREFIX = "luanti_texmod/"
-- What the server serves the game's own files as; see media_resource_name()
-- in builtin/luanti/luanti.cpp
local MEDIA_PREFIX = "luanti_media/"

local dir_added = false
-- The directory is a resource directory once there is something in it: the
-- first file made it, and what comes after it is looked up by name -- a
-- nested expression blits the pieces it is made of.
local function added_dir()
	if not dir_added then
		dir_added = buildat.add_resource_dir(RESOURCE_DIR)
	end
end
-- Expression -> the resource name it was composed under, for this run. The
-- files outlive it, but composing one twice costs only the work.
local composed = {}

local function hex_hash(s)
	return buildat.hex(buildat.sha1(s))
end

local function resource_of(expr)
	return RESOURCE_PREFIX .. hex_hash(expr) .. ".png"
end

local function path_of(resource)
	return RESOURCE_DIR .. "/" .. resource
end

-- A colour of the expression's own, for one that cannot be composed: the
-- node is then a flat colour rather than a hole in the world, which is what
-- it was before the client resolved anything.
local function fallback_colour(expr)
	local h = hex_hash(expr)
	local function byte(i)
		return 64 + tonumber(string.sub(h, i, i + 1), 16) % 160
	end
	return {byte(1), byte(3), byte(5), 255}
end

local function write_fallback(resource, expr)
	local okc, errc = pcall(buildat.compose_image, {
		size = {16, 16},
		ops = {{op = "fill", color = fallback_colour(expr)}},
		write = path_of(resource),
	})
	if not okc then
		log:warning("could not write a fallback for \"" .. expr .. "\": " ..
				tostring(errc))
		return
	end
	added_dir()
end

-- One expression into one file, and the pieces it is made of into files of
-- their own. The name the top one is written under is the server's, because
-- that is what the voxel definitions say; a piece is named after itself.
local function compose(top_expr, top_resource)
	local ctx
	ctx = {
		resource = function(name)
			return MEDIA_PREFIX .. name
		end,
		-- "[png:" carries a whole file; it becomes one, under a name of
		-- its own, and from there it is a file like any other
		png = function(bytes)
			local resource = RESOURCE_PREFIX .. hex_hash(bytes) .. ".png"
			if composed[resource] then
				return resource
			end
			local okc, errc = pcall(buildat.compose_image, {
				ops = {{op = "blit", src_data = bytes}},
				write = path_of(resource),
			})
			if not okc then
				log:warning("[png: could not be written: " .. tostring(errc))
				return nil
			end
			added_dir()
			composed[resource] = resource
			return resource
		end,
		compose = function(expr, ops, size)
			local resource = (expr == top_expr) and top_resource or
					resource_of(expr)
			if composed[expr] then
				return composed[expr]
			end
			local okc, errc = pcall(buildat.compose_image, {
				size = size,
				ops = ops,
				write = path_of(resource),
			})
			if not okc then
				log:warning("compose_image failed for \"" ..
						string.sub(expr, 1, 60) .. "\": " .. tostring(errc))
				return nil
			end
			added_dir()
			composed[expr] = resource
			return resource
		end,
	}
	return texmod.resolve(top_expr, ctx)
end

buildat.sub_packet("luanti:texmods", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local n = 0
	local failed = 0
	-- The pairs are flat: a resource name and then the expression it is for
	for i = 1, #values - 1, 2 do
		local resource = values[i]
		local expr = values[i + 1]
		if composed[expr] ~= resource then
			local got = compose(expr, resource)
			if got == resource then
				n = n + 1
			else
				-- Either the expression uses something texmod.lua does not
				-- build, or a file it names is not here
				log:info("texmod: a flat colour for \"" ..
						string.sub(expr, 1, 60) .. "\"")
				write_fallback(resource, expr)
				failed = failed + 1
			end
		end
	end
	log:info("luanti:texmods: " .. n .. " textures composed, " .. failed ..
			" could not be")
	for name, _ in pairs(texmod.unimplemented) do
		log:info("texmod: no \"" .. name .. "\" yet")
	end
	-- Whatever has been drawn already was drawn without these
	if n > 0 or failed > 0 then
		voxelworld.remesh_all()
	end
end)

--
-- What the player is carrying
--
-- The server sends this to one client -- the player's own -- whenever their
-- inventory has changed. What draws it is whoever is drawing: a formspec
-- once there is one, and the launcher's own line of text until then.

-- list name -> an array of item strings, one per slot; an empty slot is ""
M.inventory = {}

local inventory_subs = {}

-- sub_inventory(f) -> f(lists) every time the player's inventory changes,
-- and once now if one has already arrived
function M.sub_inventory(f)
	inventory_subs[#inventory_subs + 1] = f
	if next(M.inventory) then
		f(M.inventory)
	end
end

buildat.sub_packet("luanti:inventory", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local lists = {}
	local i = 1
	while i + 1 <= #values do
		local name = values[i]
		local size = tonumber(values[i + 1]) or 0
		local stacks = {}
		for slot = 1, size do
			stacks[slot] = values[i + 1 + slot] or ""
		end
		lists[name] = stacks
		i = i + 2 + size
	end
	M.inventory = lists
	for _, f in ipairs(inventory_subs) do
		f(lists)
	end
end)

-- Asked for rather than sent, because a packet that arrives before the
-- script that subscribes to it has nowhere to go
buildat.send_packet("luanti:get_texmods", "")

return M
-- vim: set noet ts=4 sw=4:
