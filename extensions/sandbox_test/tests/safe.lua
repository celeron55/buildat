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

