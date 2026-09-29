-- Buildat: games/floorplanner/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID])
return function(ctx) return {{id = "play", label = "Floor planner",
	description = "Plan a floor in millimetres, together",
	-- pick: the plan is chosen in the game, by the local user
	run = function() ctx.launch{game = "floorplanner",
			params = {pick = "1"}} end}} end
