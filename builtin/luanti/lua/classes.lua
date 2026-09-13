-- Buildat: builtin/luanti/lua/classes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The globals Luanti's C API gives a mod that are classes rather than
-- functions: ItemStack and the random and noise generators. A mod builds
-- these while it is loading, so they have to be here before the first mod
-- runs.
--
-- simplified: ItemStack is written in Lua rather than being Luanti's
-- inventory.cpp behind a userdata. It holds a name, a count, a wear and a
-- metadata table and does the arithmetic on them, which is what a mod
-- loading needs and what most of them use at all. The ceiling is the
-- itemstring format -- the quoted and escaped forms Luanti parses in C++ are
-- not all read here -- and that inventories elsewhere do not share storage
-- with a stack taken out of them. The upgrade path is the one the plan
-- names: vendor inventory.cpp and tool.cpp at M4 and put this behind them.

--
-- Metadata, as an ItemStack carries it
--

local MetaData = {}
MetaData.__index = MetaData

local function new_metadata(fields)
	return setmetatable({fields = fields or {}}, MetaData)
end

function MetaData:contains(key)
	return self.fields[key] ~= nil
end

function MetaData:get(key)
	return self.fields[key]
end

function MetaData:get_string(key)
	return self.fields[key] or ""
end

function MetaData:set_string(key, value)
	if value == nil or value == "" then
		self.fields[key] = nil
	else
		self.fields[key] = tostring(value)
	end
end

function MetaData:get_int(key)
	return math.floor(tonumber(self.fields[key]) or 0)
end

function MetaData:set_int(key, value)
	self:set_string(key, string.format("%d", value))
end

function MetaData:get_float(key)
	return tonumber(self.fields[key]) or 0
end

function MetaData:set_float(key, value)
	self:set_string(key, tostring(value))
end

function MetaData:get_keys()
	local out = {}
	for k, _ in pairs(self.fields) do
		out[#out + 1] = k
	end
	return out
end

function MetaData:to_table()
	local fields = {}
	for k, v in pairs(self.fields) do
		fields[k] = v
	end
	local t = {fields = fields}
	if self.inventory then
		t.inventory = self.inventory:get_lists()
	end
	return t
end

-- Only a node's metadata has one -- an item stack's does not, and answers
-- with nothing rather than with an inventory nobody can reach. What makes
-- one is core.get_meta(); see bootstrap.lua.
function MetaData:get_inventory()
	return self.inventory
end

function MetaData:from_table(t)
	self.fields = {}
	for k, v in pairs((t or {}).fields or {}) do
		self.fields[k] = v
	end
	if self.inventory then
		self.inventory:set_lists((t or {}).inventory or {})
	end
	return true
end

function MetaData:equals(other)
	for k, v in pairs(self.fields) do
		if other.fields[k] ~= v then
			return false
		end
	end
	for k, v in pairs(other.fields) do
		if self.fields[k] ~= v then
			return false
		end
	end
	return true
end

function MetaData:set_tool_capabilities(caps)
	if caps == nil then
		self.fields.tool_capabilities = nil
	else
		self.fields.tool_capabilities = core.write_json({
			tool_capabilities = caps})
	end
end

-- Used by mod storage and by anything else that wants Luanti's metadata
-- interface over a table of strings
core.__new_metadata = new_metadata

--
-- ItemStack
--

local Stack = {}
Stack.__index = Stack

local function stack_definition(self)
	return core.registered_items[self.name] or
			core.registered_items["unknown"] or {}
end

-- "default:stone 3 100" and the plainer forms of it. The quoted name and the
-- trailing metadata Luanti's C++ parser also reads are the ceiling above.
local function parse_itemstring(s)
	local name, count, wear = nil, 1, 0
	local rest = s:match("^%s*(.-)%s*$")
	if rest == "" then
		return "", 0, 0
	end
	local parts = {}
	for part in rest:gmatch("%S+") do
		parts[#parts + 1] = part
	end
	name = parts[1]
	if parts[2] then
		count = tonumber(parts[2]) or 1
	end
	if parts[3] then
		wear = tonumber(parts[3]) or 0
	end
	return name, count, wear
end

local function new_stack(name, count, wear, meta_fields)
	local self = setmetatable({}, Stack)
	self.name = name or ""
	self.count = count or 0
	self.wear = wear or 0
	self.meta = new_metadata(meta_fields)
	if self.name == "" then
		self.count = 0
	end
	return self
end

function ItemStack(from)
	if from == nil then
		return new_stack("", 0, 0)
	end
	if type(from) == "string" then
		local name, count, wear = parse_itemstring(from)
		return new_stack(name, count, wear)
	end
	if getmetatable(from) == Stack then
		return new_stack(from.name, from.count, from.wear,
				from.meta:to_table().fields)
	end
	if type(from) == "table" then
		return new_stack(from.name, tonumber(from.count) or 1,
				tonumber(from.wear) or 0,
				(from.meta or from.metadata or {}).fields or from.meta)
	end
	error("ItemStack(): cannot make a stack of a " .. type(from))
end

function Stack:is_empty()
	return self.count <= 0 or self.name == ""
end

function Stack:get_name()
	return self.name
end

function Stack:set_name(name)
	self.name = name or ""
	if self.name == "" then
		self.count = 0
	end
	return not self:is_empty()
end

function Stack:get_count()
	return self.count
end

function Stack:set_count(count)
	self.count = math.floor(tonumber(count) or 0)
	if self.count <= 0 then
		self.name = ""
		self.count = 0
	end
	return not self:is_empty()
end

function Stack:get_wear()
	return self.wear
end

function Stack:set_wear(wear)
	self.wear = math.max(0, math.min(65535, math.floor(tonumber(wear) or 0)))
	if self.wear >= 65536 then
		self:clear()
		return false
	end
	return true
end

function Stack:get_meta()
	return self.meta
end

-- Deprecated in Luanti and still called by old mods
function Stack:get_metadata()
	return self.meta:get_string("")
end

function Stack:set_metadata(value)
	self.meta:set_string("", value)
	return true
end

function Stack:get_description()
	local def = stack_definition(self)
	local d = self.meta:get_string("description")
	if d ~= "" then
		return d
	end
	return def.description or self.name
end

function Stack:get_short_description()
	local d = self.meta:get_string("short_description")
	if d ~= "" then
		return d
	end
	local def = stack_definition(self)
	if def.short_description then
		return def.short_description
	end
	return (self:get_description():gsub("\n.*", ""))
end

function Stack:clear()
	self.name = ""
	self.count = 0
	self.wear = 0
	self.meta = new_metadata()
end

function Stack:replace(other)
	local s = ItemStack(other)
	self.name, self.count, self.wear, self.meta = s.name, s.count, s.wear, s.meta
end

function Stack:to_string()
	if self:is_empty() then
		return ""
	end
	local out = self.name
	if self.count ~= 1 or self.wear ~= 0 then
		out = out .. " " .. self.count
	end
	if self.wear ~= 0 then
		out = out .. " " .. self.wear
	end
	return out
end

Stack.__tostring = Stack.to_string

function Stack:to_table()
	if self:is_empty() then
		return nil
	end
	return {
		name = self.name,
		count = self.count,
		wear = self.wear,
		metadata = self.meta:get_string(""),
		meta = self.meta:to_table().fields,
	}
end

function Stack:get_stack_max()
	local def = stack_definition(self)
	return tonumber(def.stack_max) or 99
end

function Stack:get_free_space()
	return self:get_stack_max() - self.count
end

function Stack:is_known()
	return core.registered_items[self.name] ~= nil
end

function Stack:get_definition()
	return stack_definition(self)
end

function Stack:get_tool_capabilities()
	local def = stack_definition(self)
	return def.tool_capabilities or
			(core.registered_items[""] or {}).tool_capabilities or {}
end

function Stack:add_wear(amount)
	if self:get_stack_max() ~= 1 then
		return
	end
	self:set_wear(self.wear + (tonumber(amount) or 0))
end

function Stack:add_wear_by_uses(uses)
	uses = tonumber(uses) or 0
	if uses <= 0 then
		return
	end
	self:add_wear(math.floor(65535 / uses))
end

function Stack:item_fits(other)
	local s = ItemStack(other)
	if s:is_empty() then
		return true, nil
	end
	if self:is_empty() then
		return s.count <= s:get_stack_max(), nil
	end
	if self.name ~= s.name or self.wear ~= s.wear then
		return false, s
	end
	local room = self:get_free_space()
	if s.count <= room then
		return true, nil
	end
	local left = ItemStack(s)
	left:set_count(s.count - room)
	return false, left
end

function Stack:add_item(other)
	local s = ItemStack(other)
	if s:is_empty() then
		return ItemStack()
	end
	if self:is_empty() then
		local taken = math.min(s.count, s:get_stack_max())
		self:replace(s)
		self:set_count(taken)
		local left = ItemStack(s)
		left:set_count(s.count - taken)
		return left
	end
	if self.name ~= s.name or self.wear ~= s.wear then
		return s
	end
	local room = math.max(0, self:get_free_space())
	local taken = math.min(room, s.count)
	self:set_count(self.count + taken)
	local left = ItemStack(s)
	left:set_count(s.count - taken)
	return left
end

function Stack:take_item(n)
	n = math.floor(tonumber(n) or 1)
	if n <= 0 or self:is_empty() then
		return ItemStack()
	end
	n = math.min(n, self.count)
	local taken = ItemStack(self)
	taken:set_count(n)
	self:set_count(self.count - n)
	return taken
end

function Stack:peek_item(n)
	n = math.floor(tonumber(n) or 1)
	if n <= 0 or self:is_empty() then
		return ItemStack()
	end
	local out = ItemStack(self)
	out:set_count(math.min(n, self.count))
	return out
end

function Stack:equals(other)
	local s = ItemStack(other)
	return self.name == s.name and self.count == s.count and
			self.wear == s.wear and self.meta:equals(s.meta)
end

Stack.__eq = Stack.equals

--
-- Inventories
--
-- simplified: lists of ItemStacks in a table, with the same methods Luanti's
-- InvRef has. What it does not have is Luanti's inventory-changed
-- notifications to clients, because there are no clients yet; the
-- allow_/on_ callbacks a detached inventory carries are kept and will be run
-- by whatever drives them at M4.

local Inv = {}
Inv.__index = Inv

function core.__new_inventory(location)
	return setmetatable({lists = {}, widths = {},
			location = location or {type = "undefined"}}, Inv)
end

local function inv_list(self, listname)
	return self.lists[listname]
end

function Inv:is_empty(listname)
	for _, stack in ipairs(inv_list(self, listname) or {}) do
		if not stack:is_empty() then
			return false
		end
	end
	return true
end

function Inv:get_size(listname)
	local list = inv_list(self, listname)
	return list and #list or 0
end

function Inv:set_size(listname, size)
	size = math.floor(tonumber(size) or 0)
	if size < 0 then
		return false
	end
	local list = self.lists[listname] or {}
	for i = #list + 1, size do
		list[i] = ItemStack()
	end
	for i = #list, size + 1, -1 do
		list[i] = nil
	end
	if size == 0 then
		self.lists[listname] = nil
	else
		self.lists[listname] = list
	end
	return true
end

function Inv:get_width(listname)
	return self.widths[listname] or 0
end

function Inv:set_width(listname, width)
	self.widths[listname] = math.floor(tonumber(width) or 0)
	return true
end

function Inv:get_stack(listname, i)
	local list = inv_list(self, listname)
	if not list or not list[i] then
		return ItemStack()
	end
	return ItemStack(list[i])
end

function Inv:set_stack(listname, i, stack)
	local list = inv_list(self, listname)
	if not list or not list[i] then
		return false
	end
	list[i] = ItemStack(stack)
	return true
end

function Inv:get_list(listname)
	local list = inv_list(self, listname)
	if not list then
		return nil
	end
	local out = {}
	for i, stack in ipairs(list) do
		out[i] = ItemStack(stack)
	end
	return out
end

function Inv:set_list(listname, stacks)
	local list = inv_list(self, listname)
	if not list then
		return
	end
	for i = 1, #list do
		list[i] = ItemStack(stacks[i])
	end
end

function Inv:get_lists()
	local out = {}
	for name, _ in pairs(self.lists) do
		out[name] = self:get_list(name)
	end
	return out
end

function Inv:set_lists(lists)
	for name, stacks in pairs(lists) do
		if self.lists[name] then
			self:set_list(name, stacks)
		end
	end
end

function Inv:add_item(listname, stack)
	local left = ItemStack(stack)
	local list = inv_list(self, listname)
	if not list then
		return left
	end
	-- Into the stacks that already hold this item first, as Luanti does
	for pass = 1, 2 do
		for i = 1, #list do
			if left:is_empty() then
				return left
			end
			if (pass == 1) ~= list[i]:is_empty() then
				left = list[i]:add_item(left)
			end
		end
	end
	return left
end

function Inv:room_for_item(listname, stack)
	local probe = core.__new_inventory(self.location)
	probe:set_size(listname, self:get_size(listname))
	probe:set_list(listname, self:get_list(listname) or {})
	return probe:add_item(listname, stack):is_empty()
end

function Inv:contains_item(listname, stack, match_meta)
	local want = ItemStack(stack)
	if want:is_empty() then
		return true
	end
	local count = want:get_count()
	for _, have in ipairs(inv_list(self, listname) or {}) do
		if have:get_name() == want:get_name() and
				(not match_meta or have:get_meta():equals(want:get_meta())) then
			count = count - have:get_count()
			if count <= 0 then
				return true
			end
		end
	end
	return false
end

function Inv:remove_item(listname, stack)
	local want = ItemStack(stack)
	local taken = ItemStack()
	local list = inv_list(self, listname)
	if not list then
		return taken
	end
	-- From the end, which is the order Luanti takes them in
	for i = #list, 1, -1 do
		if taken:get_count() >= want:get_count() then
			break
		end
		if list[i]:get_name() == want:get_name() then
			local n = math.min(list[i]:get_count(),
					want:get_count() - taken:get_count())
			local got = list[i]:take_item(n)
			if taken:is_empty() then
				taken = got
			else
				taken:set_count(taken:get_count() + got:get_count())
			end
		end
	end
	return taken
end

function Inv:get_location()
	return self.location
end

--
-- Random and noise
--
-- PseudoRandom is Luanti's own generator and its numbers are part of what a
-- world looks like, so it is the one written out exactly. PcgRandom is Lua's
-- own randomness behind Luanti's interface, which is honest for anything that
-- is not a map.
--

local Pseudo = {}
Pseudo.__index = Pseudo

-- Thirty-two bits of it, which is more than a double multiplies exactly, so
-- the state goes round in two halves
local function lcg32(state)
	local a = 1103515245
	local lo = state % 65536
	local hi = math.floor(state / 65536)
	return ((hi * a) % 65536 * 65536 + lo * a + 12345) % 4294967296
end

function PseudoRandom(seed)
	return setmetatable({state = math.floor(seed or 0) % 4294967296}, Pseudo)
end

-- Luanti's own, exactly: the state is multiplied as an unsigned 32-bit
-- number and then divided as a signed one, which is a quirk it keeps for
-- the sake of the worlds already generated with it.
function Pseudo:next(min, max)
	self.state = lcg32(self.state)
	local signed = self.state
	if signed >= 2147483648 then
		signed = signed - 4294967296
	end
	-- C truncates towards zero, and the result is read back as unsigned
	local q = signed / 65536
	q = q >= 0 and math.floor(q) or -math.floor(-q)
	local value = (q % 4294967296) % 32768
	if min == nil then
		return value
	end
	max = max or 32767
	if max < min then
		error("PseudoRandom:next(): max < min")
	end
	if max - min == 32767 then
		return min + value
	end
	if max - min > 6553 then
		error("PseudoRandom:next(): range too large")
	end
	return min + (value % (max - min + 1))
end

function Pseudo:get_state()
	local v = self.state
	if v >= 2147483648 then
		v = v - 4294967296
	end
	return v
end

local Pcg = {}
Pcg.__index = Pcg

-- simplified: not Luanti's PCG32, so the numbers a mod gets out of this are
-- not the ones Luanti would give it. What it is instead is the generator
-- above behind PcgRandom's interface, including a state string that goes
-- out and comes back. Anything that is the map -- decorations, ores -- is
-- mapgen's, and the mapgen is a milestone away; when it arrives this is the
-- thing to write out exactly, in sixteen-bit limbs the way lcg32 above is.
function PcgRandom(seed, sequence)
	local self = setmetatable({}, Pcg)
	self.rng = PseudoRandom(seed)
	return self
end

function Pcg:next(min, max)
	if min == nil then
		return self.rng:next() * 65536 + self.rng:next() * 2
	end
	local span = max - min
	if span <= 32767 then
		return min + (self.rng:next() % (span + 1))
	end
	return min + (self.rng:next() * 32768 + self.rng:next()) % (span + 1)
end

function Pcg:rand_normal_dist(min, max, num_trials)
	num_trials = num_trials or 6
	local sum = 0
	for _ = 1, num_trials do
		sum = sum + self:next(min, max)
	end
	return math.floor(sum / num_trials + 0.5)
end

-- Luanti's is two 64-bit numbers as thirty-two hex digits. This one has
-- thirty-two bits of state, so it goes in the last eight of them and the
-- rest are zeroes -- which round-trips, which is what the interface is for.
function Pcg:get_state()
	return string.format("%024d%08x", 0, self.rng.state)
end

function Pcg:set_state(str)
	if type(str) ~= "string" or #str ~= 32 then
		error("PcgRandom:set_state(): expected 32 hex characters")
	end
	self.rng.state = tonumber(string.sub(str, 25), 16) or 0
end

function SecureRandom()
	return {next_bytes = function(self, count)
		local out = {}
		for i = 1, (count or 1) do
			out[i] = string.char(math.random(0, 255))
		end
		return table.concat(out)
	end}
end

-- The mapgen's noise is vendored at the milestone that needs a world; until
-- then a generator that answers zero is what keeps a mod that asks for one
-- loading.
local Noise = {}
Noise.__index = Noise

local function new_noise()
	return setmetatable({}, Noise)
end

function Noise:get_2d() return 0 end
function Noise:get_3d() return 0 end
Noise.get2d = Noise.get_2d
Noise.get3d = Noise.get_3d

function PerlinNoise() return new_noise() end
function ValueNoise() return new_noise() end

local NoiseMap = {}
NoiseMap.__index = NoiseMap

function NoiseMap:get_2d_map() return {} end
function NoiseMap:get_3d_map() return {} end
function NoiseMap:get_2d_map_flat() return {} end
function NoiseMap:get_3d_map_flat() return {} end
function NoiseMap:calc_2d_map() end
function NoiseMap:calc_3d_map() end
function NoiseMap:get_map_slice() return {} end

function PerlinNoiseMap() return setmetatable({}, NoiseMap) end
function ValueNoiseMap() return setmetatable({}, NoiseMap) end

-- A settings file of a mod's own
function Settings(path)
	local values = {}
	local f = io.open(path, "rb")
	if f then
		for line in f:read("*a"):gmatch("[^\r\n]+") do
			local key, value = line:match("^%s*([^#=][^=]-)%s*=%s*(.-)%s*$")
			if key then
				values[key] = value
			end
		end
		f:close()
	end
	local self = {}
	function self:get(key) return values[key] end
	function self:get_bool(key, default)
		local v = values[key]
		if v == nil then return default end
		return v == "true"
	end
	function self:get_np_group(key) return nil end
	function self:get_flags(key) return {} end
	function self:set(key, value) values[key] = tostring(value) end
	function self:set_bool(key, value) values[key] = tostring(value) end
	function self:remove(key) values[key] = nil return true end
	function self:get_names()
		local out = {}
		for k, _ in pairs(values) do out[#out + 1] = k end
		return out
	end
	function self:has(key) return values[key] ~= nil end
	function self:to_table()
		local out = {}
		for k, v in pairs(values) do out[k] = v end
		return out
	end
	function self:write()
		local lines = {}
		for k, v in pairs(values) do lines[#lines + 1] = k .. " = " .. v end
		return core.safe_file_write(path, table.concat(lines, "\n") .. "\n")
	end
	return self
end

-- vim: set noet ts=4 sw=4:
