-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- devtest's /bench_* commands, run for the joining player and logged, for
-- the LuaJIT before/after table in doc/plan/performance_plan.md [LUAJIT].
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=bench \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/bench.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- and a client connected, since the bulk ones read the player's position.
-- Each line the commands would have said in chat is logged as
-- `bench: <command>: <line>`, and `bench: done` ends the set.
-- Not bench_bulk_set_node and bench_bulk_swap_node: their set_node and
-- swap_node loop halves commit voxelworld once per node -- a read
-- flushes the write buffer, and set_node reads first -- and a million
-- of those is minutes. The bulk halves are what bulk_set_node is for.
local names = {"bench_table_copy_vecs", "bench_name2content",
		"bench_content2name", "bench_bulk_get_node",
		"bench_bulk_get_node_raw", "bench_bulk_get_node_raw2",
		"bench_bulk_get_node_vm"}

core.register_on_joinplayer(function(player)
	local pname = player:get_player_name()
	-- After the world around the player is there: the bulk benches set
	-- and read a 99^3 cube beside them
	core.after(15, function()
		local current = ""
		local real_send = core.chat_send_player
		core.chat_send_player = function(to, text)
			if to == pname then
				core.log("action", "bench: " .. current .. ": " .. text)
			end
			return real_send(to, text)
		end
		for _, name in ipairs(names) do
			local cmd = core.registered_chatcommands[name]
			if cmd then
				current = name
				local ok, ret, msg = pcall(cmd.func, pname, "")
				if not ok then
					core.log("action", "bench: " .. name .. ": error " ..
							tostring(ret))
				elseif msg then
					core.log("action", "bench: " .. name .. ": " .. msg)
				end
			else
				core.log("action", "bench: " .. name .. ": not registered")
			end
		end
		core.chat_send_player = real_send
		core.log("action", "bench: done")
	end)
end)
