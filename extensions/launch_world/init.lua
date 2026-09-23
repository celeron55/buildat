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
	-- **What the client asks a launcher for** ([MENU_CONTEXT]): the room
	-- hands back the three the client and a game's own menu call --
	-- `buildat.leave()` goes through `leave_game`, and [MENU_ERRORS]
	-- reads `in_game` to choose a dialog or a notice.
	local room = dofile(buildat.extension_path("launch_world") ..
			"/world.lua")
	if type(room) == "table" then
		M.entered_game = room.entered_game
		M.leave_game = room.leave_game
		M.in_game = room.in_game
	end
end

-- A local server that died, the same as launch_menu's: the last lines of
-- its log and where the whole of it is, so a crash's backtrace is on the
-- screen and not just gone ([START_PROGRESS]).
function M.show_dead_server(title, on_close)
	local ui_utils = require("buildat/extension/ui_utils")
	local path, tail = buildat.local_server_log_tail(20)
	ui_utils.show_message_dialog(title .. "\n\n" .. tail ..
			"\nThe full log is at " .. path, on_close)
end

return M
-- vim: set noet ts=4 sw=4:
