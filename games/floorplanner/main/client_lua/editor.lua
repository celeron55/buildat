-- Buildat: games/floorplanner/main/client_lua/editor.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The editor. [FP_DOC] only shows what the document holds; the views and
-- the tools come with [FP_WALLS].
local magic = require("buildat/extension/urho3d")
local M = {}

function M.start(doc)
	local t = magic.ui.root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 16)
	t:SetPosition(10, 10)
	local function refresh()
		local n = 0
		for _ in pairs(doc.ents) do
			n = n + 1
		end
		t:SetText("The plan holds " .. n .. " entities")
	end
	doc.listeners[#doc.listeners + 1] = refresh
	refresh()
end

function M.key_down(key) end
function M.update(dt) end

return M
-- vim: set noet ts=4 sw=4:
