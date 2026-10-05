-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- PcgRandom gives Luanti's numbers ([MAPGEN_DENSITY]): VoxeLibre draws its
-- mesa strata from PcgRandom(seed), so other numbers are another world.
-- The values are Luanti's own (noise.cpp's PcgRandom, through l_next's
-- argument casts), and the same file passes as a world mod in official
-- Luanti.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=pcg_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/pcg.lua \
--   bin/buildat_server -u launcher=1 -m ../apps/vanilla -D ../user
--
-- The log says "pcg check: ok" once the mods have loaded.
local cases = {
	{"6", {-514446237, 4, 11, 8, 4, -554, 1997555397, 54},
			"e2eeb709038191b3b47c73972972b7b7"},
	{-5, {-598606210, 9, 4, 8, 6, 66, 209708553, 50},
			"7822c78be728c120b47c73972972b7b7"},
	{12345, {103855418, 5, 8, 1, 10, 233, 276356027, 58},
			"4bfb180e961fda2eb47c73972972b7b7"},
	{"13284934584939029384", {-1225182877, 2, 8, 10, 1, -352, 656713645, 45},
			"588cf5e094987a1db47c73972972b7b7"},
	{0, {-1973039491, 11, 11, 10, 11, 156, 10028293, 67},
			"91683467ae39da1db47c73972972b7b7"},
}
core.register_on_mods_loaded(function()
	local bad = {}
	for _, c in ipairs(cases) do
		local pr = PcgRandom(c[1])
		local got = {pr:next()}
		for _ = 1, 4 do got[#got + 1] = pr:next(1, 12) end
		got[#got + 1] = pr:next(-1000, 1000)
		got[#got + 1] = pr:next(0, 2000000000)
		got[#got + 1] = pr:rand_normal_dist(1, 100)
		local want = table.concat(c[2], " ")
		local have = table.concat(got, " ")
		if have ~= want then
			bad[#bad + 1] = tostring(c[1]) .. ": " .. have .. " (want " ..
					want .. ")"
		end
		if pr:get_state() ~= c[3] then
			bad[#bad + 1] = tostring(c[1]) .. " state " .. pr:get_state()
		end
		local copy = PcgRandom(1)
		copy:set_state(pr:get_state())
		if copy:next() ~= pr:next() then
			bad[#bad + 1] = tostring(c[1]) .. ": set_state does not round-trip"
		end
	end
	local q = PcgRandom(7, 3)
	if q:next(1, 100) ~= 52 or q:next(1, 100) ~= 9 then
		bad[#bad + 1] = "sequence 3"
	end
	if #bad == 0 then
		core.log("action", "pcg check: ok")
	else
		core.log("error", "pcg check: " .. table.concat(bad, "; "))
	end
end)
