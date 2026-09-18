-- Buildat: extensions/sandbox_test/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch grid's check ([LAUNCH_GRID]): a launcher file that tries what
-- a sandboxed file must be refused, one try per tile, each expected to
-- fail. The menu draws with this file present; a tile that reports "ok"
-- is a hole.
local function try(name, f)
	local ok, err = pcall(f)
	return {id = name, label = name .. (ok and ": HOLE" or ": refused"),
		description = tostring(err), order = 900,
		run = function() end}
end
return function(ctx)
	return {
		try("io.open", function() return io.open("/etc/hostname") end),
		try("os.execute", function() return os.execute("true") end),
		try("trusted require", function()
			local t = require("buildat/extension/sandbox_test")
			assert(t.try_exploit == nil and t.boot == nil, "trusted table")
			return t
		end),
		try("function param", function()
			ctx.launch{extension = "luanti_client", params = {f = function() end}}
		end),
	}
end
