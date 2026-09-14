-- Buildat: builtin/luanti/lua/vmanip.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- VoxelManip, and the mapgen seam it is the map half of.
--
-- A VoxelManip is a box of the map in three flat arrays -- the content ids,
-- param1 and param2 -- read in one call and written in one. That is what
-- makes a Lua mapgen affordable: a chunk is a quarter of a million voxels,
-- and reading them one at a time across the Lua boundary is a module lock
-- each. The arrays are x fastest and then y and then z, which is what
-- VoxelArea indexes and what voxelworld's region calls already produce, so
-- a mod's own VoxelArea arithmetic goes straight through.
--
-- simplified: no emerging. Luanti reads whole mapblocks around the box asked
-- for and hands back the corners it really read; here the box is the box,
-- and a mod that uses the corners it is given -- which is every mod, because
-- that is the documented way -- does not notice. What it costs is that a
-- write cannot straddle what was never read.

local VoxelManipRef = {}
VoxelManipRef.__index = VoxelManipRef

local function to_xyz(p)
	if p == nil then
		return nil
	end
	return math.floor(p.x or p[1] or 0), math.floor(p.y or p[2] or 0),
			math.floor(p.z or p[3] or 0)
end

local function sorted_box(p1, p2)
	local x1, y1, z1 = to_xyz(p1)
	local x2, y2, z2 = to_xyz(p2)
	if x1 > x2 then x1, x2 = x2, x1 end
	if y1 > y2 then y1, y2 = y2, y1 end
	if z1 > z2 then z1, z2 = z2, z1 end
	return x1, y1, z1, x2, y2, z2
end

function VoxelManipRef:read_from_map(p1, p2)
	local x1, y1, z1, x2, y2, z2 = sorted_box(p1, p2)
	self.emin = {x = x1, y = y1, z = z1}
	self.emax = {x = x2, y = y2, z = z2}
	self.ystride = x2 - x1 + 1
	self.zstride = (x2 - x1 + 1) * (y2 - y1 + 1)
	self.ids, self.param1, self.param2 =
			__luanti_get_region_data(x1, y1, z1, x2, y2, z2)
	self.modified = false
	return self.emin, self.emax
end

function VoxelManipRef:get_emerged_area()
	return self.emin, self.emax
end

-- Luanti fills the buffer it is given and returns it; the table here is the
-- VoxelManip's own either way, so a mod that changes it in place and never
-- calls set_data() still gets what it meant.
function VoxelManipRef:get_data(buffer)
	if buffer ~= nil and buffer ~= self.ids then
		for i = 1, #self.ids do
			buffer[i] = self.ids[i]
		end
		return buffer
	end
	return self.ids
end

function VoxelManipRef:set_data(data)
	self.ids = data
	self.modified = true
end

function VoxelManipRef:get_light_data(buffer)
	return self.param1
end

function VoxelManipRef:set_light_data(data)
	self.param1 = data
	self.modified = true
end

function VoxelManipRef:get_param2_data(buffer)
	return self.param2
end

function VoxelManipRef:set_param2_data(data)
	self.param2 = data
	self.modified = true
end

function VoxelManipRef:index(x, y, z)
	return (z - self.emin.z) * self.zstride +
			(y - self.emin.y) * self.ystride + (x - self.emin.x) + 1
end

function VoxelManipRef:contains(x, y, z)
	return x >= self.emin.x and x <= self.emax.x and
			y >= self.emin.y and y <= self.emax.y and
			z >= self.emin.z and z <= self.emax.z
end

function VoxelManipRef:get_node_at(pos)
	local x, y, z = to_xyz(pos)
	if not self:contains(x, y, z) then
		return {name = "ignore", param1 = 0, param2 = 0}
	end
	local i = self:index(x, y, z)
	return {name = core.get_name_from_content_id(self.ids[i] or 0),
			param1 = self.param1[i] or 0, param2 = self.param2[i] or 0}
end

function VoxelManipRef:set_node_at(pos, node)
	local x, y, z = to_xyz(pos)
	if not self:contains(x, y, z) then
		return
	end
	local i = self:index(x, y, z)
	self.ids[i] = core.get_content_id(node.name)
	self.param1[i] = node.param1 or 0
	self.param2[i] = node.param2 or 0
	self.modified = true
end

function VoxelManipRef:write_to_map(light)
	if self.emin == nil then
		return
	end
	__luanti_set_region_data(self.emin.x, self.emin.y, self.emin.z,
			self.emax.x, self.emax.y, self.emax.z,
			self.ids, self.param1, self.param2)
	self.modified = false
	-- What calc_lighting() asked for, now that there is terrain to work it
	-- out from. Luanti's own write_to_map(light) does the same thing when
	-- it is not told otherwise.
	local r = self.relight
	if r == nil and light ~= false then
		r = {x1 = self.emin.x, y1 = self.emin.y, z1 = self.emin.z,
				x2 = self.emax.x, y2 = self.emax.y, z2 = self.emax.z}
	end
	if r ~= nil then
		self.relight = nil
		__luanti_relight(r.x1, r.y1, r.z1, r.x2, r.y2, r.z2)
	end
end

function VoxelManipRef:was_modified()
	return self.modified and true or false
end

-- The light is voxelworld's, which is what makes these two different from
-- Luanti's: there the manipulator works the light out into its own param1
-- and writes it with the rest, and here the world floods it once the
-- terrain is in the map. So calc_lighting() records the box and the flood
-- happens after write_to_map(), which is the only order in which there is
-- terrain to work from.
--
-- A mod that writes a chunk of its own terrain needs this: what it wrote
-- carries no light, and a write with no light in it takes the light that
-- was there -- which, where the mod has just replaced the mapgen's terrain,
-- is nothing. VoxeLibre's world was black until this did something.
function VoxelManipRef:calc_lighting(p1, p2, propagate_shadow)
	if self.emin == nil then
		return
	end
	if p1 ~= nil and p2 ~= nil then
		local x1, y1, z1, x2, y2, z2 = sorted_box(p1, p2)
		self.relight = {x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2}
	else
		self.relight = {x1 = self.emin.x, y1 = self.emin.y,
				z1 = self.emin.z, x2 = self.emax.x, y2 = self.emax.y,
				z2 = self.emax.z}
	end
end

-- simplified: set_lighting() does write what it is told, because a mod that
-- fills a cave with its own value means it; update_liquids() is
-- voxelworld's job and the engine's.

function VoxelManipRef:set_lighting(light, p1, p2)
	if type(light) ~= "table" or self.emin == nil then
		return
	end
	local value = (light.day or 0) + (light.night or 0) * 16
	local x1, y1, z1, x2, y2, z2
	if p1 ~= nil and p2 ~= nil then
		x1, y1, z1, x2, y2, z2 = sorted_box(p1, p2)
	else
		x1, y1, z1 = self.emin.x, self.emin.y, self.emin.z
		x2, y2, z2 = self.emax.x, self.emax.y, self.emax.z
	end
	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				if self:contains(x, y, z) then
					self.param1[self:index(x, y, z)] = value
				end
			end
		end
	end
	self.modified = true
end

function VoxelManipRef:update_liquids()
end

function VoxelManipRef:update_map()
end

function VoxelManipRef:close()
	self.ids, self.param1, self.param2 = nil, nil, nil
end

local function new_vmanip(p1, p2)
	local vm = setmetatable({ids = {}, param1 = {}, param2 = {},
			modified = false}, VoxelManipRef)
	if p1 ~= nil and p2 ~= nil then
		vm:read_from_map(p1, p2)
	end
	return vm
end

function core.get_voxel_manip(p1, p2)
	return new_vmanip(p1, p2)
end

function VoxelManip(p1, p2)
	return new_vmanip(p1, p2)
end

--
-- The mapgen seam
--

-- What core.get_mapgen_object("voxelmanip") hands out while a generation
-- callback runs, and nothing outside one. Luanti gives a mod the VoxelManip
-- its mapgen just filled and writes back whatever the mod does to it when
-- the callback returns; so does this.
local mapgen_vm = nil
-- What the mapgen reported for the section being run over; see
-- core.__run_on_generated()
local mapgen_gennotify = nil

function core.get_mapgen_object(name)
	if name == "voxelmanip" then
		if mapgen_vm == nil then
			return nil
		end
		return mapgen_vm, mapgen_vm.emin, mapgen_vm.emax
	end
	if name == "gennotify" then
		-- Always a table, which is what Luanti answers: the mapgen reports
		-- what it made into it, and a mod indexes it without asking whether
		-- it is there -- VoxeLibre's mcl_mapgen_core does, and an answer of
		-- nil took its whole generator down every chunk. It is empty unless
		-- a mod asked with core.set_gen_notify() and this is a section the
		-- mapgen made something it was asked about in.
		return mapgen_gennotify or {}
	end
	-- heightmap, biomemap, heatmap and humiditymap are the mapgen's own
	-- workings, and singlenode has none of them. Luanti answers nil for an
	-- object the running mapgen does not produce, which is what a mod
	-- checks for.
	return nil
end

-- Called by the module once a section has been filled, with the box it
-- filled and the seed that box's randomness starts from.
-- What the mapgen reported for the section being run over, in Luanti's
-- shape: a name to the list of positions it happened at. Read from the line
-- per event the module leaves in __luanti_gennotify; see gennotify_of() in
-- luanti.cpp.
local function parse_gennotify(text)
	if text == nil or text == "" then
		return {}
	end
	local out = {}
	for name, x, y, z in text:gmatch("(%S+) (-?%d+) (-?%d+) (-?%d+)") do
		local list = out[name]
		if list == nil then
			list = {}
			out[name] = list
		end
		list[#list + 1] = vector.new(tonumber(x), tonumber(y), tonumber(z))
	end
	return out
end

function core.__run_on_generated(x0, y0, z0, x1, y1, z1, blockseed)
	local callbacks = core.registered_on_generateds
	if callbacks == nil or #callbacks == 0 then
		return
	end
	mapgen_gennotify = parse_gennotify(__luanti_gennotify)
	-- Vectors and not plain tables: a mod calls vector methods on what it
	-- is given, which is what Luanti hands it
	local minp = vector.new(x0, y0, z0)
	local maxp = vector.new(x1, y1, z1)
	-- Read lazily: a mod that only places a few nodes with core.set_node
	-- should not pay for a quarter of a million voxels crossing the
	-- boundary twice. The first core.get_mapgen_object() call is what
	-- reads them.
	mapgen_vm = setmetatable({ids = {}, param1 = {}, param2 = {},
			modified = false}, VoxelManipRef)
	local read = false
	local real_get = core.get_mapgen_object
	core.get_mapgen_object = function(name)
		if name == "voxelmanip" and not read then
			read = true
			mapgen_vm:read_from_map(minp, maxp)
		end
		return real_get(name)
	end
	for i = 1, #callbacks do
		local callback = callbacks[i]
		local origin = core.callback_origins and
				core.callback_origins[callback]
		if origin then
			core.set_last_run_mod(origin.mod)
		end
		local ok, err
		if core.__mapgen_env_callbacks[callback] then
			-- Registered by a core.register_mapgen_script(), whose
			-- environment hands the callback the VoxelManip first. There is
			-- one Lua state here, so which environment a callback came from
			-- is remembered rather than enforced.
			if not read then
				read = true
				mapgen_vm:read_from_map(minp, maxp)
			end
			ok, err = pcall(callback, mapgen_vm, minp, maxp, blockseed)
		else
			ok, err = pcall(callback, minp, maxp, blockseed)
		end
		if not ok then
			core.log("error", "on_generated: " .. tostring(err))
		end
	end
	core.get_mapgen_object = real_get
	-- What a mod did to the mapgen's own VoxelManip is written back when
	-- the callback returns, which is Luanti's rule for that one
	if read and mapgen_vm:was_modified() then
		mapgen_vm:write_to_map()
	end
	mapgen_vm = nil
	mapgen_gennotify = nil
end

--
-- What the mapgen is, as far as anything can ask
--

function core.get_mapgen_setting(name)
	if name == "seed" then
		return tostring(__luanti_world_seed)
	end
	if name == "mg_name" then
		-- What this world is actually generated with, which is written into
		-- the save the first time it is opened. It said "singlenode" here
		-- while that was all there was, and a game reads this to decide
		-- what to register: VoxeLibre registers no biomes at all for a
		-- singlenode world. An imported world's mapgen is its
		-- map_meta.txt's and is in no setting here, so the module's answer
		-- comes first and the settings are the fallback.
		return __luanti_mapgen_name or core.__mapgen_name()
	end
	if name == "chunksize" then
		return tostring(core.get_mapgen_chunksize().x)
	end
	if name == "water_level" and __luanti_water_level then
		-- The world's own, which is what it was made with: a save keeps it
		-- the way Luanti's map_meta.txt does, and the settings are only
		-- where it comes from the first time
		return tostring(__luanti_water_level)
	end
	return core.settings:get("mg" .. name) or core.settings:get(name)
end

function core.set_mapgen_setting(name, value, override_meta)
	core.settings:set(name, tostring(value))
end

function core.get_mapgen_params()
	-- Deprecated in Luanti and still called; the fields are the ones it
	-- answers with
	return {
		mgname = __luanti_mapgen_name or core.__mapgen_name(),
		seed = tonumber(__luanti_world_seed) or 0,
		water_level = tonumber(__luanti_water_level) or
				tonumber(core.settings:get("water_level")) or 1,
		chunksize = core.get_mapgen_chunksize().x,
		flags = core.settings:get("mg_flags") or "",
	}
end

function core.set_mapgen_params(params)
end

-- In mapblocks of sixteen, which is the unit Luanti answers this in: its own
-- chunk is five of them each way and a section here is four.
function core.get_mapgen_chunksize()
	local s = math.floor((tonumber(__luanti_section_size) or 64) / 16)
	return vector.new(s, s, s)
end

-- The world's own edges, which is what a mod asks before it generates past
-- them. The module's region is the map's limits; see create_world().
function core.get_mapgen_edges(mapgen_limit, chunksize)
	local limit = tonumber(core.settings:get("mapgen_limit")) or 31000
	if mapgen_limit ~= nil then
		limit = mapgen_limit
	end
	local s = tonumber(__luanti_section_size) or 64
	-- Whole sections, because a section is what is loaded and generated
	local n = math.floor(limit / s)
	return vector.new(-n * s, -n * s, -n * s),
			vector.new((n + 1) * s - 1, (n + 1) * s - 1, (n + 1) * s - 1)
end

-- vim: set noet ts=4 sw=4:
