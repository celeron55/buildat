-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [FEATURE_SWEEP_1009]: the ABMs and LBMs that name an alias, and
-- whether find_nodes_in_area by an alias name finds the node
core.register_on_mods_loaded(function()
	local al = core.registered_aliases
	local function scan(kind, list)
		for _, d in ipairs(list or {}) do
			for _, field in ipairs({"nodenames", "neighbors"}) do
				local v = d[field]
				if type(v) == "string" then v = {v} end
				for _, n in ipairs(v or {}) do
					if al[n] then
						core.log("warning", string.format("aliascheck: %s %s %s %s -> %s",
								kind, d.label or d.name or "?", field, n, al[n]))
					end
				end
			end
		end
	end
	scan("abm", core.registered_abms)
	scan("lbm", core.registered_lbms)
	local a, t
	for k, v in pairs(al) do
		if rawget(core.registered_nodes, v) and not rawget(core.registered_nodes, k) then
			a, t = k, v
			break
		end
	end
	core.log("warning", "aliascheck: scanned, try " .. tostring(a) .. " -> " .. tostring(t))
	if not a then core.log("warning", "aliascheck: done") return end
	local p = {x = 0, y = 2000, z = 0}
	core.emerge_area(p, p, function(_, _, left)
		if left > 0 then return end
		core.set_node(p, {name = t})
		local got = core.find_nodes_in_area(p, p, {a})
		local got2 = core.find_nodes_in_area(p, p, {t})
		core.log("warning", string.format("aliascheck: find by alias %d, by name %d", #got, #got2))
		core.log("warning", "aliascheck: done")
	end)
end)
