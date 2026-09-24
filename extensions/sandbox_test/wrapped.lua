-- Buildat: extension/sandbox_test/wrapped.lua
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **What the whitelist lets through, exercised** ([URHO_SWEEP]). The
-- hostile boot beside this says what cannot be reached; this says that
-- what was wrapped works -- **a class added to the whitelist with a
-- property missing silently does nothing**, which is the fault the
-- sweep exists to avoid, and it is found here rather than in a game.
--
-- Run from M.boot() in the sandbox, so everything here is sandboxed
-- code: extensions/sandbox_test/check.sh reads the line it logs.
local log = buildat.Logger("wrapped")
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe

-- Matrix3x4 (2026-09-22): a transform built, taken apart and applied
do
	local m = magic.Matrix3x4(magic.Vector3(1, 2, 3),
			magic.Quaternion(90, magic.Vector3(0, 1, 0)), 2)
	local t = m:Translation()
	assert(math.abs(t.x - 1) < 1e-4 and math.abs(t.y - 2) < 1e-4 and
			math.abs(t.z - 3) < 1e-4)
	assert(math.abs(m:Scale().x - 2) < 1e-4)
	-- Rotation 90 about Y takes +X to -Z; scaled by 2 and moved
	local p = m * magic.Vector3(1, 0, 0)
	assert(math.abs(p.x - 1) < 1e-3 and math.abs(p.z - (3 - 2)) < 1e-3,
			"Matrix3x4 * Vector3: " .. p.x .. ", " .. p.y .. ", " .. p.z)
	local back = m:Inverse() * p
	assert(math.abs(back.x - 1) < 1e-3 and math.abs(back.z) < 1e-3)
	local id = m * m:Inverse()
	assert(id:Translation():Length() < 1e-3 and
			math.abs(id:Scale().x - 1) < 1e-3)
end

-- XMLElement (2026-09-25): a document out of the resource cache walked
-- -- the root, its children, an attribute and a number
do
	local f = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	assert(f, "the style file is in the cache")
	local root = f:GetRoot()
	assert(root:NotNull() and not root:IsNull(), "the root is there")
	assert(root:GetName() == "elements",
			"the root is <elements>: " .. root:GetName())
	local e = root:GetChild("element")
	assert(e:NotNull(), "the first element")
	assert(e:HasAttribute("type"), "an element says what type it is")
	assert(#e:GetAttribute("type") > 0, "and the attribute reads back")
	local n = 0
	while e:NotNull() do
		n = n + 1
		e = e:GetNext("element")
	end
	assert(n > 1, "the style has several elements: " .. n)
	log:info("wrapped: " .. n .. " elements under <" .. root:GetName() .. ">")
end

return true
