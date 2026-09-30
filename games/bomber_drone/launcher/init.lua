-- Buildat: games/bomber_drone/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID]); the default tile is gone
return function(ctx) return {{id = "play", label = "bomber_drone",
	run = function() ctx.launch{game = "bomber_drone"} end}} end
