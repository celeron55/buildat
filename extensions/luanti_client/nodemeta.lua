-- Buildat: extension/luanti_client/nodemeta.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The metadata that hangs off a voxel: what a chest holds, what a sign says.
--
-- It arrives twice over. A mapblock ends with the metadata of the voxels in
-- it, positions given as an index into the block, and TOCLIENT_NODEMETA_CHANGED
-- carries the same list with absolute positions when a server changes one.
--
-- The format, from Luanti's NodeMetadataList::deSerialize:
--
--   u8 version              -- 0 for "nothing here"
--   u16 count
--   per entry:
--     u16 index in the block, or three s16 of an absolute position
--     u32 field count
--     per field: u16-string name | u32-string value | u8 private
--     the inventory, as the lines inventory.lua reads, ending with
--     "EndInventory"
--
-- A field a server marked private arrives with an empty value, so there is
-- nothing to do about the flag but read past it.

local M = {}

-- The inventory that follows a metadata entry's fields. It is text with no
-- length in front of it, so what says where it ends is its last line.
local function read_inventory(r, inventory)
	local lines = {}
	while r:remaining() > 0 do
		local line = r:line()
		lines[#lines + 1] = line
		if line == "EndInventory" then
			break
		end
	end
	return inventory.parse(table.concat(lines, "\n").."\n")
end

-- parse(r, inventory, absolute) -> {[key] = {fields = {}, lists = {}}}
--
-- r is a reader positioned at the version byte, inventory is inventory.lua
-- and absolute says whether the positions are absolute or an index into a
-- mapblock. The key is the index for a block's own list and "x,y,z" for an
-- absolute one, so the caller does not have to know which it asked for.
function M.parse(r, inventory, absolute)
	local out = {}
	local version = r:u8()
	if version == 0 then
		return out
	end
	if version > 2 then
		error("luanti_client/nodemeta: version "..version)
	end
	for _ = 1, r:u16() do
		local key
		if absolute then
			local x, y, z = r:s16(), r:s16(), r:s16()
			key = x..","..y..","..z
		else
			key = r:u16()
		end
		local fields = {}
		for _ = 1, r:u32() do
			local name = r:string()
			local value = r:longstring()
			if version >= 2 then
				r:u8() -- private
			end
			fields[name] = value
		end
		out[key] = {fields = fields, lists = read_inventory(r, inventory)}
	end
	return out
end

return M
-- vim: set noet ts=4 sw=4:
