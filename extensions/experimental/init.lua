-- Buildat: extension/experimental/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/experimental")
local M = {safe = {}}

local subs_tick = {}

function __buildat_tick(dtime)
	for _, cb in ipairs(subs_tick) do
		cb(dtime)
	end
end

function M.safe.sub_tick(cb)
	table.insert(subs_tick, cb)
end
function M.safe.unsub_tick(cb)
	for i=#subs_tick,1,-1 do
		if subs_tick[i] == cb then
			table.remove(subs_tick, i)
		end
	end
end

local polybox = require("buildat/extension/polycode_sandbox")

--[[
local function SomeUI(scene)
	local self = {}
	local function on_button_click()
		log:info("SomeUI: on_button_click()")
	end
	self.button = UIButton("Foo", 100, 50)
	scene:addEventListener(self, on_button_click, UIEvent.CLICK_EVENT)
	return self
end
--]]

--[[
class "SomeUI" (UIElement)
function SomeUI:SomeUI()
	UIElement.UIElement(self)
	self:Resize(100, 60)
	self:setPosition(640-100, 0)
	self.button = UIButton("Foo", 100, 30)
	self:addChild(self.button)
end

function SomeUI:on_button(e)
end

M.things = {}
function M.safe.do_stuff(scene2d_safe)
	CoreServices.getInstance():getConfig():setNumericValue("Polycode", "uiButtonFontSize", 20)
	local scene2d = polybox.check_type(scene2d_safe, "Scene")
	scene2d.rootEntity.processInputEvents = true
	local some_ui = SomeUI()
	scene2d:addEntity(some_ui)
	table.insert(M.things, some_ui)
end
]]

return M
