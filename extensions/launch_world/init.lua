-- extensions/launch_world: [LAUNCH_WORLD], the room you start in.
--
-- An alternative to `launch_menu`, never a replacement:
--   Build/bin/buildat -m launch_world
--
-- The room itself is world.lua; this file is only the entry the client
-- calls to boot a menu extension. It is an extension rather than a game
-- because the room *is* the launcher: starting a game is `ctx.launch` on
-- the trusted side, which a game's own sandbox cannot reach.
local log = buildat.Logger("launch_world")
local M = {}

function M.boot(action)
	-- simplified: the launch grid's one-action boot (-a kind/name/id) is
	-- not wired up yet; it arrives with the real contents, step 5 of the
	-- launcher plan's remaining order.
	if action then
		log:warning("launch_world: -a " .. tostring(action) ..
				" is not handled yet")
	end
	dofile(buildat.extension_path("launch_world") .. "/world.lua")
end

return M
