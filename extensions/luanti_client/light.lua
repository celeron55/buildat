-- Buildat: extension/luanti_client/light.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The light around a node that changed, worked out here rather than asked for
-- again. This is Luanti's own algorithm: take away the light that came from
-- what changed, then spread what is left back in.
--
-- Luanti keeps two light values per node, and this works on either: the day
-- bank, which is the light a node has when the sun is up, and the night bank,
-- which is what light sources alone give it. They differ in one rule only --
-- sunlight -- so the two passes are the same code with sun on and off.
--
-- Sunlight is the value 15, which is one more than any light source can give
-- (Luanti's LIGHT_SUN against LIGHT_MAX): a node is in direct sunlight when
-- its day light is 15, and sunlight goes straight down through anything that
-- lets it, undimmed. So a node that starts or stops letting sunlight through
-- takes the whole column below it with it, which is the column loop below.
--
-- Nothing here touches the map: the caller passes in accessors, which is what
-- makes this testable without a world. See world.lua for the real ones and
-- test.lua for the ones a test uses.
--
--   access.node(x, y, z)        -> the node id there, or nil for a node in a
--                                  block we do not have
--   access.light(x, y, z)       -> day, night; nil for an unknown node
--   access.set_light(x, y, z, day, night)
--   access.source(id)           -> the light the node itself gives, 0...14
--   access.through(id)          -> whether light travels through it
--   access.sun_through(id)      -> whether sunlight goes straight through
--
-- What comes back is how many nodes were looked at and whether anything was
-- left unresolved -- a node in a block we do not have, or the budget running
-- out. The caller can then fall back to asking the server, which is what it
-- did before this existed.

local M = {}

M.LIGHT_SUN = 15
M.LIGHT_MAX = 14

-- The six directions, and which of them is straight up and straight down
local NEIGHBOURS = {
	{0, 1, 0}, {0, -1, 0},
	{1, 0, 0}, {-1, 0, 0},
	{0, 0, 1}, {0, 0, -1},
}

-- How many nodes one change may look at. A dig that opens a shaft to the sky
-- relights a column and its surroundings, which is hundreds; a cap in the
-- thousands is far above anything real and keeps a pathological case from
-- costing a frame.
M.BUDGET = 6000

-- The light a node has of its own, whatever its neighbours do: what it gives
-- off, and the sun when it stands in it.
local function own_light(access, x, y, z, id, sun)
	local own = access.source(id) or 0
	if not sun then
		return own
	end
	if not access.sun_through(id) then
		return own
	end
	-- Sunlit when what is above is: straight down, undimmed. The node above
	-- being at 15 is what says so, which is why 15 is not a level any light
	-- source reaches.
	local above_day = access.light(x, y + 1, z)
	if above_day == M.LIGHT_SUN then
		return M.LIGHT_SUN
	end
	return own
end

-- One bank of one change. The caller has already given the changed node the
-- light the server sent for it; what is left is everything around it.
local function update_bank(access, x, y, z, from_id, to_id, sun, state)
	local bank_light = sun and
			function(px, py, pz)
				local day = access.light(px, py, pz)
				return day
			end or
			function(px, py, pz)
				local _, night = access.light(px, py, pz)
				return night
			end
	local set_bank = sun and
			function(px, py, pz, level)
				local _, night = access.light(px, py, pz)
				access.set_light(px, py, pz, level, night or 0)
			end or
			function(px, py, pz, level)
				local day = access.light(px, py, pz)
				access.set_light(px, py, pz, day or 0, level)
			end

	-- Everything the removal pass takes light away from, to spread from
	-- afterwards, and the two queues. A queue is a flat array of x, y, z and
	-- the light that was there, walked with a cursor: a table per entry would
	-- be thousands of them per dig.
	local relight = {}
	local dark = {}
	local dark_at = 1

	local function want_dark(px, py, pz, level)
		dark[#dark + 1] = px
		dark[#dark + 1] = py
		dark[#dark + 1] = pz
		dark[#dark + 1] = level
	end

	local function want_light(px, py, pz)
		relight[#relight + 1] = px
		relight[#relight + 1] = py
		relight[#relight + 1] = pz
	end

	local was = state.old_day
	if not sun then
		was = state.old_night
	end
	local now = bank_light(x, y, z) or 0

	-- The column below a node that stopped or started letting sunlight
	-- through: the sun reaches straight down, so the whole column changes
	-- with it.
	if sun then
		local from_sun = access.sun_through(from_id)
		local to_sun = access.sun_through(to_id)
		if from_sun and not to_sun and was == M.LIGHT_SUN then
			local cy = y - 1
			while true do
				local id = access.node(x, cy, z)
				if id == nil then
					state.unresolved = true
					break
				end
				if not access.sun_through(id) then
					break
				end
				if bank_light(x, cy, z) ~= M.LIGHT_SUN then
					break
				end
				set_bank(x, cy, z, own_light(access, x, cy, z, id, false))
				want_dark(x, cy, z, M.LIGHT_SUN)
				cy = cy - 1
			end
		elseif to_sun and not from_sun and now == M.LIGHT_SUN then
			local cy = y - 1
			while true do
				local id = access.node(x, cy, z)
				if id == nil then
					state.unresolved = true
					break
				end
				if not access.sun_through(id) then
					break
				end
				if bank_light(x, cy, z) == M.LIGHT_SUN then
					break
				end
				set_bank(x, cy, z, M.LIGHT_SUN)
				want_light(x, cy, z)
				cy = cy - 1
			end
		end
	end

	-- Take away what came from here
	if was > now then
		want_dark(x, y, z, was)
	end
	while dark_at <= #dark do
		local px, py, pz = dark[dark_at], dark[dark_at + 1], dark[dark_at + 2]
		local level = dark[dark_at + 3]
		dark_at = dark_at + 4
		state.visited = state.visited + 1
		if state.visited > M.BUDGET then
			state.unresolved = true
			return
		end
		for i = 1, 6 do
			local d = NEIGHBOURS[i]
			local nx, ny, nz = px + d[1], py + d[2], pz + d[3]
			local nl = bank_light(nx, ny, nz)
			if nl == nil then
				state.unresolved = true
			elseif nl ~= 0 and nl < level then
				-- Its light can only have come from here, so it goes out --
				-- down to whatever it has of its own
				local id = access.node(nx, ny, nz)
				local own = id and own_light(access, nx, ny, nz, id, sun) or 0
				if nl > own then
					set_bank(nx, ny, nz, own)
					want_dark(nx, ny, nz, nl)
				end
				if own > 0 then
					want_light(nx, ny, nz)
				end
			elseif nl >= level and nl > 0 then
				-- Lit by something else, so it lights this way again
				want_light(nx, ny, nz)
			end
		end
	end

	-- And spread back in, from what is still lit: what the removal pass
	-- found, the node itself, and its six neighbours -- a node that became
	-- air takes its light from them and the removal pass never ran.
	want_light(x, y, z)
	for i = 1, 6 do
		local d = NEIGHBOURS[i]
		want_light(x + d[1], y + d[2], z + d[3])
	end
	local light_at = 1
	while light_at <= #relight do
		local px, py, pz = relight[light_at], relight[light_at + 1],
				relight[light_at + 2]
		light_at = light_at + 3
		state.visited = state.visited + 1
		if state.visited > M.BUDGET then
			state.unresolved = true
			return
		end
		local level = bank_light(px, py, pz)
		if level ~= nil and level > 1 then
			for i = 1, 6 do
				local d = NEIGHBOURS[i]
				local nx, ny, nz = px + d[1], py + d[2], pz + d[3]
				local id = access.node(nx, ny, nz)
				if id == nil then
					state.unresolved = true
				elseif access.through(id) then
					local nl = bank_light(nx, ny, nz) or 0
					if nl < level - 1 then
						set_bank(nx, ny, nz, level - 1)
						want_light(nx, ny, nz)
					end
				end
			end
		end
	end
end

-- update(access, x, y, z, from_id, to_id, old_day, old_night)
--   -> visited, unresolved
--
-- The light the server sent for the changed node is already in place; what
-- this works out is the light of everything around it. old_day and old_night
-- are what the node had before, which is what says how far the darkness has
-- to reach.
function M.update(access, x, y, z, from_id, to_id, old_day, old_night)
	local state = {visited = 0, unresolved = false,
			old_day = old_day or 0, old_night = old_night or 0}
	update_bank(access, x, y, z, from_id, to_id, true, state)
	update_bank(access, x, y, z, from_id, to_id, false, state)
	return state.visited, state.unresolved
end

return M
-- vim: set noet ts=4 sw=4:
