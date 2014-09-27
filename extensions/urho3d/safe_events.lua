-- Buildat: extension/urho3d/safe_events.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>

return {
	Update = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	KeyDown = {
		Key = {variant = "Int", safe = "number"},
	},
	HoverBegin = {
	},
	HoverEnd = {
	},
	Released = {
	},
	TextFinished = {
	},
}
-- vim: set noet ts=4 sw=4:
