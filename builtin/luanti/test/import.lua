-- What an imported Luanti world brought with it besides its nodes: the
-- entities its blocks were holding, and the timers on its nodes.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=import_check \
--   BUILDAT_LUANTI_IMPORT=/path/to/a/luanti/world \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/import.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- It says what is there every ten seconds, because an import of a large
-- world takes minutes and there is no callback for it being over -- and the
-- module's own clock only moves between imports, since the import holds the
-- thread its steps are on. What the importer counted is in the log above
-- this; this says what is still there once the world is running.
local function say()
	local n, kinds = 0, {}
	for _, le in pairs(core.luaentities or {}) do
		n = n + 1
		local name = le.name or "?"
		kinds[name] = (kinds[name] or 0) + 1
	end
	local parts = {}
	for name, count in pairs(kinds) do
		parts[#parts + 1] = name .. "=" .. count
	end
	table.sort(parts)
	core.log("action", "import check: " .. n .. " entities in the world: " ..
			table.concat(parts, " "))
end

local left = 30
local function again()
	say()
	left = left - 1
	if left > 0 then
		core.after(10, again)
	end
end
core.after(10, again)
