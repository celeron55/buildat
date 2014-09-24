-- Buildat: extension/cereal/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/cereal")
local M = {safe = {}}

function M.safe.binary_input(data, types)
	if type(data) ~= 'string' then
		error("data not string")
	end
	if type(types) ~= 'table' then
		error("types not table")
	end
	return __buildat_cereal_binary_input(data, types)
end

function M.safe.binary_output(values, types)
	if type(values) ~= 'table' then
		error("values not table")
	end
	if type(types) ~= 'table' then
		error("types not table")
	end
	return __buildat_cereal_binary_output(values, types)
end

return M
# vim: set noet ts=4 sw=4:
