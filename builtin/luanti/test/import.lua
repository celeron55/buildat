-- What an imported Luanti world brought with it besides its nodes: the
-- entities its blocks were holding, and the timers on its nodes.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=import_check \
--   BUILDAT_LUANTI_IMPORT=/path/to/a/luanti/world \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/import.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- It says what is there every ten seconds of the world's own clock, which
-- is not ten seconds of yours: an import holds the thread the steps are on,
-- and a step is capped at half a second, so a world that is still
-- generating advances its clock slower than the wall. Leave it running.
--
-- What the importer itself counted -- how many timers and entities it made,
-- and the kinds it could not -- is in the log above this, and is the number
-- to read first.
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
