-- Buildat: builtin/luanti/lua/classes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
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

-- A value of "${other}" is what the other key holds, one step deep and no
-- further: Luanti resolves a reference and a reference inside that, and
-- leaves the third alone, so that two keys pointing at each other cannot
-- loop. get_string() is where the resolving happens and the field itself is
-- untouched.
local function resolve_field(self, value, depth)
	if depth <= 1 and type(value) == "string" and #value > 3 and
			string.sub(value, 1, 2) == "${" and
			string.sub(value, -1) == "}" then
		local key = string.sub(value, 3, -2)
		return resolve_field(self, self.fields[key] or "", depth + 1)
	end
	return value
end

function MetaData:get_string(key)
	return resolve_field(self, self.fields[key] or "", 0)
end

function MetaData:set_string(key, value)
	if value == nil or value == "" then
		self.fields[key] = nil
	else
		self.fields[key] = tostring(value)
	end
	-- A node's metadata knows where it is, and writing it is a change to the
	-- block it is in -- which is what Luanti's reportMetadataChange() marks
	-- and what core.register_on_mapblocks_changed() hears about
	if self.pos and core.__note_block_changed then
		core.__note_block_changed(self.pos.x, self.pos.y, self.pos.z)
	end
end

function MetaData:get_int(key)
	return math.floor(tonumber(self:get_string(key)) or 0)
end

function MetaData:set_int(key, value)
	self:set_string(key, string.format("%d", value))
end

function MetaData:get_float(key)
	return tonumber(self:get_string(key)) or 0
end

function MetaData:set_float(key, value)
	-- Every digit of it, which is what Luanti writes and what a mod that
	-- compares two of them across a save expects: 0.3 is not "0.3"
	self:set_string(key, string.format("%.17g", value))
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

-- Luanti sends a node's metadata to the clients that can see the node and
-- keeps back the fields a mod marked private. Nothing here sends node
-- metadata at all -- a client gets the formspec and the inventory the module
-- hands it and nothing else -- so a field is private already and this is the
-- list of the ones that were meant to be. Found through nodecore, which
-- wraps every set_* to mark what it writes.
--
-- simplified: the names are remembered and nothing reads them. If node
-- metadata is ever sent to a client, this list is what to leave out of it.
function MetaData:mark_as_private(name)
	self.private = self.private or {}
	if type(name) == "table" then
		for _, n in ipairs(name) do
			self.private[n] = true
		end
	else
		self.private[name] = true
	end
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

do
	local m = new_metadata({})
	m:mark_as_private("secret")
	m:mark_as_private({"a", "b"})
	assert(m.private.secret and m.private.a and m.private.b)
	-- And a field marked private is still a field
	m:set_string("secret", "x")
	assert(m:get_string("secret") == "x")
	assert(m:to_table().fields.secret == "x")
end

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
-- Name, count and wear, split on single spaces the way Luanti reads them --
-- so " 3" is three of the empty item and not one of an item called 3, and a
-- name with something after it that is not a number keeps the name
-- An itemstring's fourth field is the metadata, as Luanti writes it: a
-- quoted string of \1key\2value\3 pairs (ItemStackMetadata::serialize),
-- with the quotes and backslashes escaped; the older form is a bare
-- quoted string that is the description. Without it a worn tool's name,
-- a written book or an enchanted item lost its meta at every save, since
-- inventories are stored as itemstrings ([FEATURE_SWEEP] 2026-09-21).
local function unquote(s)
	if string.sub(s, 1, 1) ~= '"' then
		return nil
	end
	local out = {}
	local i = 2
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == "\\" then
			out[#out + 1] = string.sub(s, i + 1, i + 1)
			i = i + 2
		elseif c == '"' then
			break
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

local function quote(s)
	return '"' .. string.gsub(s, '[\\"]', "\\%0") .. '"'
end

local function meta_from_string(s)
	local fields = {}
	if string.sub(s, 1, 1) == "\1" then
		-- \1key\2value\3 per pair
		for k, v in string.gmatch(s, "\1([^\2]*)\2([^\3]*)\3") do
			fields[k] = v
		end
	elseif s ~= "" then
		fields.description = s
	end
	return fields
end

local function meta_to_string(fields)
	local keys = {}
	for k in pairs(fields) do
		keys[#keys + 1] = k
	end
	if #keys == 0 then
		return nil
	end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		out[#out + 1] = "\1" .. k .. "\2" .. tostring(fields[k]) .. "\3"
	end
	return table.concat(out)
end

local function parse_itemstring(s)
	if s == "" then
		return "", 0, 0
	end
	local parts = {}
	local start = 1
	local meta = nil
	while true do
		local i = string.find(s, " ", start, true)
		if i == nil then
			parts[#parts + 1] = string.sub(s, start)
			break
		end
		parts[#parts + 1] = string.sub(s, start, i - 1)
		start = i + 1
		if #parts == 3 and string.sub(s, start, start) == '"' then
			meta = unquote(string.sub(s, start))
			break
		end
	end
	local name = parts[1] or ""
	local count = parts[2] and (tonumber(parts[2]) or 1) or 1
	local wear = parts[3] and (tonumber(parts[3]) or 0) or 0
	return name, count, wear, meta and meta_from_string(meta) or nil
end

local function new_stack(name, count, wear, meta_fields)
	local self = setmetatable({}, Stack)
	-- An alias is resolved when the stack is made, which is where Luanti
	-- resolves it: a recipe whose output is an alias makes the item the
	-- alias points at, and every name a mod compares against is the real one
	self.name = (core.__aliases and core.__aliases[name]) or name or ""
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
		local name, count, wear, meta = parse_itemstring(from)
		return new_stack(name, count, wear, meta)
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
		-- An empty stack is empty of everything, metadata included: Luanti
		-- clears the lot, and a leftover that still carried a chest's
		-- contents would not compare equal to nothing
		self:clear()
	end
	return not self:is_empty()
end

function Stack:get_wear()
	return self.wear
end

function Stack:set_wear(wear)
	self.wear = math.max(0, math.min(65535, math.floor(tonumber(wear) or 0)))
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
	local meta = meta_to_string(self.meta.fields)
	local out = self.name
	if self.count ~= 1 or self.wear ~= 0 or meta then
		out = out .. " " .. self.count
	end
	if self.wear ~= 0 or meta then
		out = out .. " " .. self.wear
	end
	if meta then
		out = out .. " " .. quote(meta)
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
	-- What the stack's own metadata says wins, which is how a tool is worn
	-- down into a weaker one or handed out with better numbers
	local raw = self.meta:get_string("tool_capabilities")
	if raw ~= "" then
		local parsed = core.parse_json(raw)
		if type(parsed) == "table" and
				type(parsed.tool_capabilities) == "table" then
			return parsed.tool_capabilities
		end
	end
	local def = stack_definition(self)
	return def.tool_capabilities or
			(core.registered_items[""] or {}).tool_capabilities or {}
end

function Stack:add_wear(amount)
	if self:get_stack_max() ~= 1 then
		return
	end
	amount = math.floor(tonumber(amount) or 0)
	-- Wear that would run past the end of the range is a tool that has been
	-- used up, which is Luanti's own rule and the only way one breaks
	if amount > 0 and self.wear > 65535 - amount then
		self:clear()
		return
	end
	self:set_wear(self.wear + amount)
end

-- How much of a tool one use costs: Luanti's own calculateResultWear() in
-- src/tool.cpp. The wear range is cut into as many blocks as the tool has
-- uses, and because 65536 rarely divides evenly some blocks are one bigger
-- than the rest; the bigger ones are spent last, so a tool breaks after
-- exactly `uses` uses whatever wear it started at. Luanti's own example is
-- 130 uses: 114 blocks of 504 and 16 of 505, which is 65536 exactly.
function core.__result_wear(uses, initial_wear)
	uses = math.floor(tonumber(uses) or 0)
	initial_wear = math.floor(tonumber(initial_wear) or 0)
	if uses <= 0 then
		return 0
	end
	local wear_normal = math.floor(65536 / uses)
	local blocks_oversize = 65536 % uses
	if blocks_oversize > 0 then
		local blocks_normal = uses - blocks_oversize
		if initial_wear >= blocks_normal * wear_normal then
			return wear_normal + 1
		end
	end
	return wear_normal
end

-- The same, under the API's name (lua_api.md "Helper functions")
core.get_tool_wear_after_use = core.__result_wear

function Stack:add_wear_by_uses(uses)
	self:add_wear(core.__result_wear(uses, self.wear))
end

function Stack:item_fits(other)
	local s = ItemStack(other)
	if s:is_empty() then
		return true, nil
	end
	if self:is_empty() then
		return s.count <= s:get_stack_max(), nil
	end
	if self.name ~= s.name or self.wear ~= s.wear or
			not self.meta:equals(s.meta) then
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
	if self.name ~= s.name or self.wear ~= s.wear or
			not self.meta:equals(s.meta) then
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
	return setmetatable({lists = {}, widths = {}, gen = 0,
			location = location or {type = "undefined"}}, Inv)
end

local function inv_list(self, listname)
	return self.lists[listname]
end

-- Counts up on every change, so that whoever has to send an inventory
-- somewhere can tell whether it is the one they sent last. The stacks in a
-- list are taken from and added to in place, so it is the methods that are
-- counted rather than the lists.
local function changed(self)
	self.gen = (self.gen or 0) + 1
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
	changed(self)
	return true
end

function Inv:get_width(listname)
	return self.widths[listname] or 0
end

function Inv:set_width(listname, width)
	width = math.floor(tonumber(width) or 0)
	if width < 0 then
		return false
	end
	self.widths[listname] = width
	changed(self)
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
	changed(self)
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
	changed(self)
end

function Inv:get_lists()
	local out = {}
	for name, _ in pairs(self.lists) do
		out[name] = self:get_list(name)
	end
	return out
end

-- The lists it is given are the lists it has afterwards, which is what
-- Luanti's does: a name that was not there is made, with as many slots as
-- the list handed in
function Inv:set_lists(lists)
	for name, stacks in pairs(lists) do
		self:set_size(name, #stacks)
		self:set_list(name, stacks)
	end
end

function Inv:add_item(listname, stack)
	local left = ItemStack(stack)
	local list = inv_list(self, listname)
	if not list then
		return left
	end
	changed(self)
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

-- From the end, which is the order Luanti takes them in, and what comes
-- back is the first stack it took from with the rest counted onto it -- so
-- it carries that stack's metadata however many stacks it came out of.
-- With match_meta only the stacks whose metadata is the same as the one
-- asked for are touched.
function Inv:remove_item(listname, stack, match_meta)
	local want = ItemStack(stack)
	local taken = ItemStack()
	local list = inv_list(self, listname)
	if not list or want:is_empty() then
		return taken
	end
	changed(self)
	for i = #list, 1, -1 do
		local have = list[i]
		if have:get_name() == want:get_name() and
				(not match_meta or have:get_meta():equals(want:get_meta())) then
			local still = want:get_count() - taken:get_count()
			local got = have:take_item(still)
			local leftover = taken:add_item(got)
			-- What would not go on the stack is counted onto it anyway,
			-- which is how Luanti allows an oversized one out and what
			-- makes the metadata of the first stack the answer's
			taken:set_count(taken:get_count() + leftover:get_count())
			if taken:get_count() >= want:get_count() then
				break
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

-- The mapgen's noise. It is buildat's own vendored copy of Luanti's value
-- noise -- the same code the Lua API is documented against, which is what
-- makes a mod's NoiseParams mean here what it means there.
--
-- Luanti calls the class PerlinNoise for what has been value noise for
-- years; both names are the same thing and both are answered.
--
-- simplified: no lacunarity and no flags. buildat's copy doubles the
-- frequency per octave and has no eased/absvalue switches, so a mod that
-- sets either gets the default behaviour rather than an error. The upgrade
-- path is the mapgen milestone that vendors the rest of src/mapgen.

local function noise_params(np, ...)
	if type(np) == "table" then
		return np
	end
	-- The old positional form: core.get_perlin(seeddiff, octaves,
	-- persistence, spread)
	local octaves, persistence, spread = ...
	return {
		offset = 0,
		scale = 1,
		seed = np or 0,
		octaves = octaves or 3,
		persistence = persistence or 0.6,
		spread = {x = spread or 100, y = spread or 100, z = spread or 100},
	}
end

local Noise = {}
Noise.__index = Noise

local function new_noise(np, seed)
	return setmetatable({np = np, seed = seed or 0}, Noise)
end

local function to_v(p, a, b, c)
	if type(p) == "table" then
		return p[a] or p[1] or 0, p[b] or p[2] or 0, p[c] or p[3] or 0
	end
	return 0, 0, 0
end

function Noise:get_2d(pos)
	local x, y = to_v(pos, "x", "y", "z")
	return __luanti_noise_value(self.np, self.seed, x, y)
end

function Noise:get_3d(pos)
	local x, y, z = to_v(pos, "x", "y", "z")
	return __luanti_noise_value(self.np, self.seed, x, y, z)
end

Noise.get2d = Noise.get_2d
Noise.get3d = Noise.get_3d

function PerlinNoise(np, ...)
	return new_noise(noise_params(np, ...), 0)
end

ValueNoise = PerlinNoise

local NoiseMap = {}
NoiseMap.__index = NoiseMap

local function new_noise_map(np, size, seed)
	local sx, sy, sz = to_v(size, "x", "y", "z")
	return setmetatable({np = np, seed = seed or 0,
			sx = math.floor(sx), sy = math.floor(sy),
			sz = math.floor(sz)}, NoiseMap)
end

-- The flat maps are the engine's own array: x fastest, and then the second
-- axis, which for a 2D map is the world's z.
function NoiseMap:get_2d_map_flat(pos, buffer)
	local x, y = to_v(pos, "x", "y", "z")
	self.flat = __luanti_noise_map(self.np, self.seed, x, y, 0,
			self.sx, self.sy, 0, buffer)
	return self.flat
end

function NoiseMap:get_3d_map_flat(pos, buffer)
	local x, y, z = to_v(pos, "x", "y", "z")
	self.flat = __luanti_noise_map(self.np, self.seed, x, y, z,
			self.sx, self.sy, self.sz, buffer)
	return self.flat
end

-- And the nested ones Luanti also answers: map[z][x] for two dimensions and
-- map[x][y][z] for three, which is the order its own Lua API builds them in
-- Nested in C, because a mod that asks for a big map asks for a very big
-- one: mcl_end_island's is 401 x 30 x 401, and built with Lua loops these
-- two were 7.7% of the time VoxeLibre's mods took to load. Luanti builds
-- them in C as well.
function NoiseMap:get_2d_map(pos)
	return __luanti_nest_2d(self:get_2d_map_flat(pos), self.sx, self.sy)
end

function NoiseMap:get_3d_map(pos)
	return __luanti_nest_3d(self:get_3d_map_flat(pos),
			self.sx, self.sy, self.sz)
end

-- What the two have to come out as, checked at load against the flat array
-- they nest. The two orders are Luanti's own and are not the same one --
-- 2D is out[y][x] with y major, 3D is out[x][y][z] with z major -- which is
-- the whole reason they are two functions.
--
-- Both are luanti.cpp's, so this runs only where they are: lua/test.lua
-- loads this file with nothing under it, and a check of a function that is
-- not there would take the whole standalone harness down instead.
if __luanti_nest_2d then
	local flat = {}
	for i = 1, 2 * 3 * 4 do
		flat[i] = i
	end
	local two = __luanti_nest_2d(flat, 2, 3)
	assert(two[1][1] == 1 and two[1][2] == 2 and two[2][1] == 3 and
			two[3][2] == 6, "a 2D noise map is out[y][x]")
	local three = __luanti_nest_3d(flat, 2, 3, 4)
	assert(three[1][1][1] == 1 and three[2][1][1] == 2 and
			three[1][2][1] == 3 and three[1][1][2] == 7,
			"a 3D noise map is out[x][y][z], z major")
	assert(#three == 2 and #three[1] == 3 and #three[1][1] == 4,
			"and it is sx by sy by sz")
end

-- Luanti's older spellings, still in the API and in games (score's mapgen
-- calls get3dMap_flat)
NoiseMap.get2dMap = NoiseMap.get_2d_map
NoiseMap.get3dMap = NoiseMap.get_3d_map
NoiseMap.get2dMap_flat = NoiseMap.get_2d_map_flat
NoiseMap.get3dMap_flat = NoiseMap.get_3d_map_flat

function NoiseMap:calc_2d_map(pos)
	self:get_2d_map_flat(pos)
end

function NoiseMap:calc_3d_map(pos)
	self:get_3d_map_flat(pos)
end

-- One slice of what calc_3d_map() worked out, which is how a mod reads a
-- big 3D map without holding all of it in Lua at once
function NoiseMap:get_map_slice(slice_offset, slice_size, buffer)
	local flat = self.flat or {}
	local y0 = math.floor((slice_offset and slice_offset.y or 1)) - 1
	local n = math.floor(slice_size and slice_size.y or 1)
	local out = buffer or {}
	local layer = self.sx * self.sz
	local i = 1
	for y = y0, y0 + n - 1 do
		for k = 1, layer do
			out[i] = flat[y * layer + k]
			i = i + 1
		end
	end
	return out
end

function PerlinNoiseMap(np, size)
	return new_noise_map(noise_params(np), size, 0)
end

ValueNoiseMap = PerlinNoiseMap

-- A mod's buffer is filled, not only a fresh array returned: mapgens read
-- the buffer they passed (extra_ordinance, 2026-10-03)
if __luanti_noise_map then
	local m = PerlinNoiseMap({offset = 0, scale = 1, seed = 1, octaves = 1,
			persist = 0.5, spread = {x = 10, y = 10, z = 10}}, {x = 2, y = 3})
	local buf = {}
	local got = m:get_2d_map_flat({x = 0, y = 0}, buf)
	assert(got == buf and #buf == 6, "a noise map fills the buffer it is given")
end

-- The same, seeded with the world's: what a mod means by core.get_perlin is
-- noise that is this world's and not the same everywhere
function core.get_perlin(np, ...)
	return new_noise(noise_params(np, ...),
			tonumber(__luanti_world_seed) or 0)
end

function core.get_perlin_map(np, size)
	return new_noise_map(noise_params(np), size,
			tonumber(__luanti_world_seed) or 0)
end

core.get_value_noise = core.get_perlin
core.get_value_noise_map = core.get_perlin_map

-- Settings is bootstrap.lua's, which is the same object core.settings is and
-- carries the defaults a game's minetest.conf puts behind a world's. There
-- was a second one here; this file loads after bootstrap.lua, so it was the
-- one a mod got, and it had neither the defaults nor get_pos().

-- Luanti's AreaStore: cuboids, each with a string of the mod's own, asked
-- which of them a position is in or which of them hold a box. A protection
-- mod keeps its claims in one; capturetheflag keeps its landmines in one and
-- does not load without it.
--
-- simplified: a flat list walked in order, which is exactly what Luanti's
-- own store does when SpatialIndex is not built in -- and `type_name` is
-- taken and ignored for the same reason, which its own documentation allows.
-- The upgrade path is an index by block, and `set_cache_params()` is where
-- Luanti says that would go.
local AreaStoreClass = {}
AreaStoreClass.__index = AreaStoreClass

function AreaStore(type_name)
	return setmetatable({areas = {}, next_id = 0}, AreaStoreClass)
end

-- What get_area() and its two plural forms answer with: `true` when the
-- caller asked for neither half, and otherwise the halves it asked for
local function area_answer(a, include_corners, include_data)
	if not include_corners and not include_data then
		return true
	end
	local out = {}
	if include_corners then
		out.min = vector.new(a.min.x, a.min.y, a.min.z)
		out.max = vector.new(a.max.x, a.max.y, a.max.z)
	end
	if include_data then
		out.data = a.data
	end
	return out
end

local function corner_pair(c1, c2)
	local function n(v)
		return math.floor(tonumber(v) or 0)
	end
	local ax, ay, az = n(c1.x), n(c1.y), n(c1.z)
	local bx, by, bz = n(c2.x), n(c2.y), n(c2.z)
	return {x = math.min(ax, bx), y = math.min(ay, by), z = math.min(az, bz)},
			{x = math.max(ax, bx), y = math.max(ay, by), z = math.max(az, bz)}
end

-- The ids Luanti allows: a whole number a mod can hold in a u32, with the
-- last one left out the way Luanti leaves it out
local MAX_AREA_ID = 4294967294

function AreaStoreClass:insert_area(c1, c2, data, id)
	if type(c1) ~= "table" or type(c2) ~= "table" then
		return nil
	end
	if id ~= nil then
		id = tonumber(id)
		if id == nil or id ~= math.floor(id) or id < 0 or id > MAX_AREA_ID or
				self.areas[id] ~= nil then
			return nil
		end
	else
		while self.areas[self.next_id] ~= nil do
			self.next_id = self.next_id + 1
		end
		id = self.next_id
		if id > MAX_AREA_ID then
			return nil
		end
	end
	local min, max = corner_pair(c1, c2)
	self.areas[id] = {min = min, max = max, data = tostring(data or "")}
	return id
end

function AreaStoreClass:get_area(id, include_corners, include_data)
	local a = self.areas[tonumber(id) or -1]
	if a == nil then
		return nil
	end
	return area_answer(a, include_corners, include_data)
end

function AreaStoreClass:remove_area(id)
	id = tonumber(id)
	if id == nil or self.areas[id] == nil then
		return false
	end
	self.areas[id] = nil
	if id < self.next_id then
		self.next_id = id
	end
	return true
end

function AreaStoreClass:get_areas_for_pos(pos, include_corners, include_data)
	local out = {}
	if type(pos) ~= "table" then
		return out
	end
	local x, y, z = pos.x, pos.y, pos.z
	for id, a in pairs(self.areas) do
		if x >= a.min.x and x <= a.max.x and y >= a.min.y and y <= a.max.y and
				z >= a.min.z and z <= a.max.z then
			out[id] = area_answer(a, include_corners, include_data)
		end
	end
	return out
end

-- Without accept_overlap an area has to hold the whole box, which is what
-- "contain all nodes inside the area specified" means; with it, sharing one
-- node is enough.
function AreaStoreClass:get_areas_in_area(c1, c2, accept_overlap,
		include_corners, include_data)
	local out = {}
	if type(c1) ~= "table" or type(c2) ~= "table" then
		return out
	end
	local min, max = corner_pair(c1, c2)
	for id, a in pairs(self.areas) do
		local hit
		if accept_overlap then
			hit = a.min.x <= max.x and a.max.x >= min.x and
					a.min.y <= max.y and a.max.y >= min.y and
					a.min.z <= max.z and a.max.z >= min.z
		else
			hit = a.min.x <= min.x and a.max.x >= max.x and
					a.min.y <= min.y and a.max.y >= max.y and
					a.min.z <= min.z and a.max.z >= max.z
		end
		if hit then
			out[id] = area_answer(a, include_corners, include_data)
		end
	end
	return out
end

-- Luanti's own says "Requires SpatialIndex, no-op function otherwise", and
-- the cache is the store's own business either way
function AreaStoreClass:reserve(count) end
function AreaStoreClass:set_cache_params(params) end

-- simplified: Luanti's own serialization is binary and its documentation
-- calls it experimental; this is core.serialize, which round-trips through
-- this engine and not through Luanti's. A mod that writes a file and reads
-- it back -- which is what they are for -- does not notice.
function AreaStoreClass:to_string()
	return core.serialize(self.areas)
end

function AreaStoreClass:from_string(str)
	local t = core.deserialize(str)
	if type(t) ~= "table" then
		return false, "not an area store"
	end
	self.areas = {}
	self.next_id = 0
	for id, a in pairs(t) do
		if type(a) == "table" and type(a.min) == "table" and
				type(a.max) == "table" then
			self.areas[tonumber(id) or 0] = {min = a.min, max = a.max,
					data = tostring(a.data or "")}
		end
	end
	return true
end

function AreaStoreClass:to_file(filename)
	return core.safe_file_write(filename, self:to_string())
end

function AreaStoreClass:from_file(filename)
	local f = io.open(filename, "rb")
	if not f then
		return false, "cannot read " .. tostring(filename)
	end
	local text = f:read("*a")
	f:close()
	return self:from_string(text)
end

-- vim: set noet ts=4 sw=4:
