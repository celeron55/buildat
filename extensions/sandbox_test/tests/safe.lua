-- Buildat: extension/sandbox_test/tests/safe.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>

local log = buildat.Logger("safe.lua")
log:verbose("Valid test case running")

-- This is only available in the sandbox, so if this doesn't fail, we're in it
sandbox.make_global({global_foo = "bar"})
assert(global_foo == "bar")

-- This too
assert(buildat.is_in_sandbox)


-- Matrix3x4 ([URHO_SWEEP]): a transform built, taken apart and applied
do
	local magic = require("buildat/extension/urho3d")
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
	log:verbose("Matrix3x4 " .. m:ToString())
end
