-- Every tutorial step's text on a desktop and on a touchscreen, with a
-- key rebound: the touchscreen's names no key and no mouse button, the
-- desktop's names the bound key and not the default.
--   lua apps/floorplanner/test/tutorial_text.lua
local any
any = setmetatable({}, {__index = function() return any end,
		__call = function() return any end})
package.preload["buildat/extension/urho3d"] = function() return any end
local function texts(touch)
	buildat = {storage_read = function() return nil end,
			storage_write = function() end, font_sans = "",
			get_env = function(n)
				return n == "BUILDAT_TOUCH" and (touch and "1" or "0") or nil
			end}
	local NAMES = {room = "P", view_2d = "F1", view_3d = "F2",
			view_walk = "F3", hosted = "I", select = "V", box = "O",
			voxel = "K", forward = "W", back = "S", left = "A", right = "D",
			use = "E"}
	local doc = {editor = {keys = {name = function(a) return NAMES[a] end},
			S = {}, folded = function() return false end},
			ents = {}, voxels = {}, can = function() return false end,
			of_type = function() return {} end}
	local T = dofile("apps/floorplanner/main/client_lua/tutorial.lua")(doc)
	local out = {}
	for i = 1, T.steps do
		out[i] = T.text_of(i)
		assert(out[i] ~= "", "step " .. i .. " has no text (an error in it)")
	end
	return out
end
for i, t in ipairs(texts(true)) do
	for _, bad in ipairs({"%(F%d%)", "%(%u%)", "Ctrl", "Enter", "right ",
			"mouse", "press [%u]%f[%A]", "Click", "click"}) do
		assert(not t:find(bad), "touch step " .. i .. " has " .. bad .. ": " .. t)
	end
end
local all = table.concat(texts(false), "\n")
assert(all:find("Room %(P%)"), "the rebound Room key")
assert(not all:find("%(R%)"), "the default Room key")
assert(all:find("Ctrl%+L") and all:find("Enter"), "the desktop's shortcuts")
print("tutorial_text: ok")
