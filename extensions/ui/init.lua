-- Buildat: extension/ui/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local polybox = require("buildat/extension/polycode_sandbox")
local graphics = require("buildat/extension/graphics")
local log = buildat.Logger("extension/ui")
local dump = buildat.dump
local M = {safe = {}}

M.safe.UIEvent = polybox.wrap_class("UIEvent", {
	constructor = function()
		return UIEvent()
	end,
	class = {
		CLICK_EVENT = UIEvent.CLICK_EVENT,
		CLOSE_EVENT = UIEvent.CLOSE_EVENT,
		OK_EVENT = UIEvent.OK_EVENT,
		CANCEL_EVENT = UIEvent.CANCEL_EVENT,
		CHANGE_EVENT = UIEvent.CHANGE_EVENT,
		YES_EVENT = UIEvent.YES_EVENT,
		NO_EVENT = UIEvent.NO_EVENT,
	},
})

M.safe.UIElement = polybox.wrap_class("UIElement", {
	inherited_from_by_wrapper = graphics.safe.Entity,
	constructor = function()
		return UIElement()
	end,
	class = {
		-- This is needed for sandboxed things to be able to inherit from this
		UIElement = function(safe)
			local unsafe = polybox.check_type(safe, "UIElement")
			UIElement.UIElement(unsafe)
		end,
	},
	instance = {
		Resize = function(safe, w, h)
			local unsafe = polybox.check_type(safe, "UIElement")
			               polybox.check_type(w, "number")
			               polybox.check_type(h, "number")
			unsafe:Resize(w, h)
		end,
	},
})

M.safe.UILabel = polybox.wrap_class("UILabel", {
	inherited_from_by_wrapper = M.safe.UIElement,
	constructor = function(text, size, fontName, amode)
		polybox.check_type(text, "string")
		polybox.check_type(size, "number")
		polybox.check_type(fontName, {"string", "__nil"})
		polybox.check_type(amode, {"__nil"})
		return UILabel(text, size, fontName, amode)
	end,
	instance = {
		setText = function(text)
			local unsafe = polybox.check_type(safe, "UILabel")
		                   polybox.check_type(text, "string")
			unsafe:setText(text)
		end,
	},
})

M.safe.UIImage = polybox.wrap_class("UIImage", {
	inherited_from_by_wrapper = M.safe.UIElement,
	constructor = function(texture_name)
		polybox.check_type(texture_name, "string")
		local path2 = graphics.resave_texture_for_polycode(texture_name)
		return UIImage(path2)
	end,
})

M.safe.UIButton = polybox.wrap_class("UIButton", {
	inherited_from_by_wrapper = M.safe.UIElement,
	constructor = function(text, w, h)
		polybox.check_type(text, "string")
		polybox.check_type(w, "number")
		polybox.check_type(h, "number")
		return UIButton(text, w, h)
	end,
})

return M

