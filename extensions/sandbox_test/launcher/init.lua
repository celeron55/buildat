-- Buildat: extensions/sandbox_test/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch grid's check ([LAUNCH_GRID]): a launcher file that tries what
-- a sandboxed file must be refused, one try per tile, each expected to
-- fail. The menu draws with this file present; a try that goes through
-- is a hole and gets a tile that says so. A refused try gets none: four
-- "refused" tiles on a player's grid were the bare run's first gap
-- ([UI_REACHABLE], 2026-09-20).
local function try(name, f)
	local ok, err = pcall(f)
	if not ok then
		return nil
	end
	return {id = name, label = name .. ": HOLE",
		description = tostring(err), order = 900,
		run = function() end}
end
return function(ctx)
	-- Appended one by one: a nil in a table constructor ends ipairs
	local out = {}
	local function add(t) out[#out + 1] = t end
	add(try("io.open", function() return io.open("/etc/hostname") end))
	add(try("os.execute", function() return os.execute("true") end))
	add(try("trusted require", function()
		local t = require("buildat/extension/sandbox_test")
		assert(t.try_exploit == nil and t.boot == nil, "trusted table")
		return t
	end))
	add(try("function param", function()
		ctx.launch{extension = "luanti_client", params = {f = function() end}}
	end))
	return out
end
