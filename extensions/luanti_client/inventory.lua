-- Buildat: extension/luanti_client/inventory.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What the player is carrying, out of Luanti's TOCLIENT_INVENTORY.
--
-- Luanti's inventory serialization is lines of text:
--
--   List main 36
--   Width 9
--   Item mcl_core:dirt 42
--   Empty
--   ...
--   EndInventoryList
--   EndInventory
--
-- An item is "name [count [wear [metadata]]]", and the name is a JSON string
-- when it holds anything that would not survive being split on a space.
--
-- The lists that matter here are "main", which the hotbar is the front of,
-- and "hand", which is what the player digs with when the wielded slot is
-- empty. A game may put anything in the hand slot -- this one puts an item
-- whose tool capabilities are what a bare hand can do -- so how long a dig
-- takes cannot be worked out without this.

local M = {}

-- A name that was written as a JSON string, or a bare one. Returns the name
-- and where the rest of the line starts.
local function read_name(s)
	if s:sub(1, 1) ~= '"' then
		local name, rest = s:match("^(%S*)%s*(.*)$")
		return name, rest
	end
	local out = {}
	local i = 2
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			local e = s:sub(i + 1, i + 1)
			if e == "n" then
				out[#out + 1] = "\n"
			elseif e == "t" then
				out[#out + 1] = "\t"
			else
				out[#out + 1] = e
			end
			i = i + 2
		elseif c == '"' then
			return table.concat(out), s:sub(i + 1):match("^%s*(.*)$")
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	-- No closing quote: take what there was rather than failing
	return table.concat(out), ""
end

-- parse_item(s) -> {name =, count =, wear =} or nil for an empty stack
function M.parse_item(s)
	local name, rest = read_name(s)
	if not name or name == "" then
		return nil
	end
	local count, wear = rest:match("^(%d+)%s+(%d+)")
	if not count then
		count = rest:match("^(%d+)")
	end
	return {
		name = name,
		count = tonumber(count) or 1,
		wear = tonumber(wear) or 0,
	}
end

-- parse(data, previous) -> {[list name] = {size =, width =, items = {...}}}
--
-- items is a plain array with a hole for every empty slot. previous is the
-- inventory this one replaces, because a KeepList line means "this list is
-- the one you already had"; with no previous, such a list comes out missing,
-- which is the same thing a client that never had it would see.
function M.parse(data, previous)
	local lists = {}
	local list = nil
	local index = 0
	for line in (data.."\n"):gmatch("([^\n]*)\n") do
		local word, rest = line:match("^(%S+)%s*(.*)$")
		if word == "List" then
			local name, size = rest:match("^(%S+)%s+(%d+)")
			-- The size is how many slots there are and the width is how wide
			-- a form draws them, which a game may leave at zero; the items
			-- are a table with a hole for every empty slot, so counting them
			-- is not the same as either
			list = {size = tonumber(size) or 0, width = 0, items = {}}
			index = 0
			lists[name or rest] = list
		elseif word == "KeepList" then
			local name = rest:match("^(%S+)")
			if previous and previous[name] then
				lists[name] = previous[name]
			end
			list = nil
		elseif word == "Width" and list then
			list.width = tonumber(rest) or 0
		elseif word == "Item" and list then
			index = index + 1
			list.items[index] = M.parse_item(rest)
		elseif word == "Empty" and list then
			index = index + 1
		elseif word == "EndInventoryList" then
			list = nil
		elseif word == "EndInventory" then
			break
		end
	end
	return lists
end

-- The stack in a list's slot, one-based, or nil
function M.slot(lists, list_name, index)
	local list = lists and lists[list_name]
	return list and list.items[index] or nil
end

-- What digging uses: the wielded stack's own tool capabilities, or the hand
-- slot's when the wielded item has none, or the empty item's as the last
-- resort. That is the order Luanti's ItemStack::getToolCapabilities() takes.
--
-- lists is what parse() returned, wield_index is one-based, and items is what
-- itemdef.parse() returned.
function M.dig_capabilities(lists, wield_index, items)
	if not items then
		return nil
	end
	local function caps_of(stack)
		local def = stack and items[stack.name]
		return def and def.tool_capabilities or nil
	end
	local wielded = M.slot(lists, "main", wield_index)
	local caps = caps_of(wielded)
	if caps then
		return caps, wielded
	end
	caps = caps_of(M.slot(lists, "hand", 1))
	if caps then
		return caps, wielded
	end
	local empty = items[""]
	return empty and empty.tool_capabilities or nil, wielded
end

return M
-- vim: set noet ts=4 sw=4:
