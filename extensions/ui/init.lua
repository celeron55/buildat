-- Buildat: extension/ui/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local polybox = require("buildat/extension/polycode_sandbox")
local graphics = require("buildat/extension/graphics")
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
			local unsafe = polybox.check_type(safe, "UILabel")
			               polybox.check_type(x, "number")
			               polybox.check_type(y, "number")
			               polybox.check_type(z, {"number", "__nil"})
			unsafe:setPosition(x, y, z)
		end,
		setText = function(text)
			local unsafe = polybox.check_type(safe, "UILabel")
		                   polybox.check_type(text, "string")
			unsafe:setText(text)
		end,
		setAnchorPoint = function(safe, safe_anchorPoint)
			-- This doesn't seem to work; why? There are no errors.
			local unsafe = polybox.check_type(safe, "UILabel")
			local unsafe_anchorPoint = polybox.check_type(safe_anchorPoint, "Vector3")
			unsafe:setAnchorPoint(unsafe_anchorPoint)
		end,
	},
})

M.safe.UIImage = polybox.wrap_class("UIImage", {
	constructor = function(texture_name)
		polybox.check_type(texture_name, "string")
		local path2 = graphics.resave_texture_for_polycode(texture_name)
		return UIImage(path2)
	end,
	class = {
	},
	instance = {
		setPosition = function(safe, x, y, z)
			local unsafe = polybox.check_type(safe, "UIImage")
			               polybox.check_type(x, "number")
			               polybox.check_type(y, "number")
			unsafe:setPosition(x, y, z)
		end,
		Resize = function(safe, w, h)
			local unsafe = polybox.check_type(safe, "UIImage")
			               polybox.check_type(w, "number")
			               polybox.check_type(h, "number")
			unsafe:Resize(w, h)
		end,
	},
})

M.safe.UIElement = polybox.wrap_class("UIElement", {
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
		setPosition = function(safe, x, y, z)
			local unsafe = polybox.check_type(safe, "UIElement")
			               polybox.check_type(x, "number")
			               polybox.check_type(y, "number")
			unsafe:setPosition(x, y, z)
		end,
		Resize = function(safe, w, h)
			local unsafe = polybox.check_type(safe, "UIElement")
			               polybox.check_type(w, "number")
			               polybox.check_type(h, "number")
			unsafe:Resize(w, h)
		end,
		addChild = function(safe, child_safe)
			local unsafe = polybox.check_type(safe, "UIElement")
			child_unsafe = polybox.check_type(child_safe, {"UIElement", "UIButton"})
			unsafe:addChild(child_unsafe)
			--element_child_added(child_unsafe) -- TODO: Needed?
		end,
	},
})

M.safe.UIButton = polybox.wrap_class("UIButton", {
	constructor = function(text, w, h)
		polybox.check_type(text, "string")
		polybox.check_type(w, "number")
		polybox.check_type(h, "number")
		return UIButton(text, w, h)
	end,
	class = {
	},
	instance = {
		setPosition = function(safe, x, y, z)
			local unsafe = polybox.check_type(safe, "UIButton")
			               polybox.check_type(x, "number")
			               polybox.check_type(y, "number")
			unsafe:setPosition(x, y, z)
		end,
		Resize = function(safe, w, h)
			local unsafe = polybox.check_type(safe, "UIButton")
			               polybox.check_type(w, "number")
			               polybox.check_type(h, "number")
			unsafe:Resize(w, h)
		end,
	},
})

return M

