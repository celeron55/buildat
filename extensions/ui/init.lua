-- Buildat: extension/ui/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local polybox = require("buildat/extension/polycode_sandbox")
local g3d = require("buildat/extension/graphics3d")
local log = buildat.Logger("extension/ui")
local dump = buildat.dump
local M = {safe = {}}

M.safe.UILabel = polybox.wrap_class("UILabel", {
	constructor = function(text, size, fontName, amode)
		polybox.check_type(text, "string")
		polybox.check_type(size, "number")
		polybox.check_type(fontName, {"string", "__nil"})
		polybox.check_type(amode, {"__nil"})
		return UILabel(text, size, fontName, amode)
	end,
	class = {
	},
	instance = {
		setPosition = function(safe, x, y, z)
			unsafe = polybox.check_type(safe, "UILabel")
			         polybox.check_type(x, "number")
			         polybox.check_type(y, "number")
			         polybox.check_type(z, {"number", "__nil"})
			unsafe:setPosition(x, y, z)
		end,
		setText = function(text)
			unsafe = polybox.check_type(safe, "UILabel")
		             polybox.check_type(text, "string")
			unsafe:setText(text)
		end,
	},
})

M.safe.UIImage = polybox.wrap_class("UIImage", {
	constructor = function(texture_name)
		polybox.check_type(texture_name, "string")
		local path2 = g3d.resave_texture_for_polycode(texture_name)
		return UIImage(path2)
	end,
	class = {
	},
	instance = {
		setPosition = function(safe, x, y, z)
			unsafe = polybox.check_type(safe, "UIImage")
			         polybox.check_type(x, "number")
			         polybox.check_type(y, "number")
			unsafe:setPosition(x, y, z)
		end,
		Resize = function(safe, w, h)
			unsafe = polybox.check_type(safe, "UIImage")
			         polybox.check_type(w, "number")
			         polybox.check_type(h, "number")
			unsafe:Resize(w, h)
		end,
	},
})

return M

