-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- core.deserialize on saved data is bounded ([SECURITY_RUN_1]): a table
-- comes back, bytecode is refused, and a loop that never ends is stopped
-- in its budget rather than hanging the server.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=deserialize_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/deserialize.lua \
--   bin/buildat_server -u launcher=1 -m ../apps/vanilla -D ../user
--
-- The log says "deserialize check: ok" once the mods have loaded.
core.register_on_mods_loaded(function()
	local t = core.deserialize(core.serialize({a = 1, b = {"x", 2}}))
	assert(type(t) == "table" and t.a == 1 and t.b[1] == "x",
			"a table comes back")
	assert(core.deserialize(string.dump(function() return 1 end)) == nil,
			"bytecode is refused")
	local t0 = os.clock()
	local v, err = core.deserialize("while true do end return 1")
	assert(v == nil and tostring(err):find("too long"),
			"an endless loop is stopped: " .. tostring(err))
	core.log("action", ("deserialize check: ok (the loop stopped in %.2f s)")
			:format(os.clock() - t0))
end)
