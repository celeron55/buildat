-- Buildat: builtin/client_lib_test/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("client_lib_test")
local magic = require("buildat/extension/urho3d")
local M = {}

function M.f()
	log:info("client_lib_test.f() called")
	local text = magic.ui.root:CreateChild("Text")
	text:SetText("client_lib_test.f() called")
	text:SetFont(magic.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
	text.horizontalAlignment = magic.HA_RIGHT
	text.verticalAlignment = magic.VA_CENTER
	text:SetPosition(-20, magic.ui.root.height/2-20)
end

return M
-- vim: set noet ts=4 sw=4:
