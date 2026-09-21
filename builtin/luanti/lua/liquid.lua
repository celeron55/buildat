-- Buildat: builtin/luanti/lua/liquid.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The liquid transform: ServerMap::transformLiquidsLocal in official's
-- servermap.cpp, node for node, over the module's node reads and writes.
-- A queue of positions; every liquid_update seconds up to liquid_loop_max
-- of them are read with their six neighbours and rewritten as what the
-- neighbours say, and what changed queues its neighbours. A node written by
-- set_node queues itself and its six neighbours ([LIQUID_FLOW]).
--
-- The tables the transform reads are Luanti's own names: liquid_type,
-- liquid_alternative_flowing/source, liquid_range, liquid_renewable,
-- liquid_viscosity, floodable, floats, on_flood. The level is param2's low
-- three bits and the flowing-down bit is bit 3, as on the wire.
--
-- A generated section queues its liquids' edges the way Mapgen::updateLiquid
-- does (the scan is C++, luanti.cpp liquid_edges). simplified: rollback is
-- not a thing here.

local LEVEL_MAX = 7
local LEVEL_MASK = 0x07
local FLOW_DOWN_MASK = 0x08
local WATER_DROP_BOOST = 4
local UPPER, SAME, LOWER = 1, 2, 3

local IGNORE, AIR = core.CONTENT_IGNORE, core.CONTENT_AIR

-- The six neighbours in official's order: up first, down last
local DIRS = {{0, 1, 0}, {0, 0, 1}, {1, 0, 0}, {0, 0, -1}, {-1, 0, 0}, {0, -1, 0}}
local KIND = {UPPER, SAME, SAME, SAME, SAME, LOWER}

local function key(x, y, z)
	return x .. "," .. y .. "," .. z
end

local get_node_raw = core.get_node_raw
local set_node_raw = core.__set_node_raw

-- What this pass has decided and not yet written, by position: a read
-- sees it, as official's does its immediate write. Written to the map at
-- the pass's end, so that the map is read and then written rather than
-- alternately -- voxelworld commits its write buffer on every read, and a
-- read-write-read per node cost a step 0.4 s for a pour.
local pending = {}
local pending_list = {}
local function get(x, y, z)
	local w = pending[key(x, y, z)]
	if w then
		return w[4], 0, w[5]
	end
	return get_node_raw(x, y, z)
end

-- What the transform needs of a content id, read once from the definition
local info_of = {}
local function info(id)
	local i = info_of[id]
	if i then
		return i
	end
	local name = core.get_name_from_content_id(id)
	local def = core.registered_nodes[name]
	local lt = def and def.liquidtype or "none"
	i = {
		liquid_type = lt,
		floodable = def and def.floodable == true or false,
		floats = def and def.floats == true or false,
		range = math.min(LEVEL_MAX + 1, (def and def.liquid_range) or 8),
		renewable = def == nil or def.liquid_renewable ~= false,
		viscosity = (def and def.liquid_viscosity) or 0,
		on_flood = def and def.on_flood or nil,
		flowing = AIR,
		source = AIR,
	}
	if lt ~= "none" then
		local f = def.liquid_alternative_flowing
		local s = def.liquid_alternative_source
		i.flowing = f and core.get_content_id(f) or id
		i.source = s and core.get_content_id(s) or id
	end
	info_of[id] = i
	return i
end

-- A unique queue: positions once each, in arrival order
local queue, queued, head, tail = {}, {}, 1, 0
local function push(x, y, z)
	local k = key(x, y, z)
	if queued[k] then
		return
	end
	queued[k] = true
	tail = tail + 1
	queue[tail] = {x, y, z}
end
local function pop()
	local p = queue[head]
	queue[head] = nil
	head = head + 1
	queued[key(p[1], p[2], p[3])] = nil
	return p[1], p[2], p[3]
end

function core.transforming_liquid_add(pos)
	push(math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5))
end

-- A node written: it, then its six neighbours, no reads -- a read here
-- flushed voxelworld's write buffer under every set_node, a commit and a
-- relight per node ([DIG_LIGHT]'s room read its light too early). The
-- pass skips what is neither liquid nor floodable at the cost of a read.
-- The order is the column's: dug top-down, the node under a dug one is
-- queued right after it, so the column fills in one pass, each node
-- seeing the one above it already water. Official queues the node last
-- and only the liquid and air neighbours; a removed liquid here is read
-- before its neighbours rather than after, and refills a pass sooner.
function core.__liquid_node_written(x, y, z)
	push(x, y, z)
	for i = 1, 6 do
		push(x + DIRS[i][1], y + DIRS[i][2], z + DIRS[i][3])
	end
end

function core.__liquid_queue_length()
	return tail - head + 1
end

-- get_max_liquid_level: the level a neighbour would give this node
local function max_level_from(nb_level, nb_flow_down, nt, current)
	if nt == UPPER then
		if nb_level + WATER_DROP_BOOST > current then
			if nb_level + WATER_DROP_BOOST < LEVEL_MAX then
				return nb_level + WATER_DROP_BOOST
			end
			return LEVEL_MAX
		elseif nb_level > current then
			return nb_level
		end
	elseif nt == SAME then
		if not nb_flow_down and nb_level > 0 and nb_level - 1 > current then
			return nb_level - 1
		end
	end
	return current
end

-- One node's decision: what it becomes, or nothing. The reads are here
-- (through the pending writes) and the write is the caller's.
local function decide(x0, y0, z0, must_reflow, falling)
	do
		local id0, _, param2_0 = get(x0, y0, z0)
		local i0 = info(id0)
		local lt0 = i0.liquid_type

		local level = -1
		-- What is placed here if liquid flows in, and if it cannot
		local kind = IGNORE
		local floodable_node = AIR
		if lt0 == "source" then
			level = LEVEL_MAX
			kind = i0.flowing
		elseif lt0 == "flowing" then
			level = param2_0 % 8
			kind = id0
		else
			if not i0.floodable then
				return nil
			end
			floodable_node = id0
			kind = AIR
		end

		-- The neighbours: sources, flows, airs, by kind
		local sources, ns = {}, 0
		local flows, nf = {}, 0
		local airs, na = {}, 0
		local flowing_down = false
		local ignored_sources = false
		local floating_above = false
		for i = 1, 6 do
			local nt = KIND[i]
			local nx, ny, nz = x0 + DIRS[i][1], y0 + DIRS[i][2], z0 + DIRS[i][3]
			local nid, _, np2 = get(nx, ny, nz)
			local ni = info(nid)
			if nt == UPPER and ni.floats then
				floating_above = true
			end
			local nlt = ni.liquid_type
			if nlt == "none" then
				if ni.floodable then
					na = na + 1
					airs[na] = {nx, ny, nz, nt}
					-- A liquid here spreads into it regardless of whether
					-- this node changes
					if nt ~= UPPER and lt0 ~= "none" then
						push(nx, ny, nz)
					end
					if nt == LOWER then
						flowing_down = true
					end
				else
					if nid == IGNORE then
						-- Not loaded: below, it may take the flow; beside,
						-- it may be the source, so nothing flows away
						if nt == LOWER then
							flowing_down = true
						else
							ignored_sources = true
						end
					end
				end
			elseif nlt == "source" then
				if kind == AIR then
					kind = ni.flowing
				end
				if ni.flowing == kind and nt ~= LOWER then
					ns = ns + 1
					sources[ns] = nt
				end
			elseif nlt == "flowing" then
				local nlevel = np2 % 8
				local ndown = np2 % 16 >= 8
				if nt ~= SAME or not ndown then
					-- Whether that neighbour can even flow in here decides
					-- whether it names the kind
					local from_nb = max_level_from(nlevel, ndown, nt, -1)
					local range = info(ni.flowing).range
					if kind == AIR and from_nb >= LEVEL_MAX + 1 - range then
						kind = ni.flowing
					end
				end
				if ni.flowing == kind then
					nf = nf + 1
					flows[nf] = {nx, ny, nz, nt, nlevel, ndown}
					if nt == LOWER then
						flowing_down = true
					end
				end
			end
		end

		-- What this node becomes
		local ik = info(kind)
		local range = ik.range
		local new_id
		local new_level = -1
		local max_level = -1
		if (ns >= 2 and ik.renewable) or lt0 == "source" then
			new_id = ik.source
		elseif ns >= 1 and sources[1] ~= LOWER then
			max_level = LEVEL_MAX
			new_level = LEVEL_MAX
			if new_level >= LEVEL_MAX + 1 - range then
				new_id = kind
			else
				new_id = floodable_node
			end
		elseif ignored_sources and level >= 0 then
			new_level = level
			new_id = kind
		else
			for i = 1, nf do
				local f = flows[i]
				max_level = max_level_from(f[5], f[6], f[4], max_level)
			end
			local viscosity = ik.viscosity
			if viscosity > 1 and max_level ~= level then
				-- The gain, at most the viscosity's share, at least one
				local inc = max_level - level
				if inc < -viscosity or inc > viscosity then
					new_level = level + math.floor(inc / viscosity)
					-- C's division truncates toward zero
					if inc < 0 then
						new_level = level - math.floor(-inc / viscosity)
					end
				elseif inc < 0 then
					new_level = level - 1
				elseif inc > 0 then
					new_level = level + 1
				end
				if new_level ~= max_level then
					must_reflow[#must_reflow + 1] = {x0, y0, z0}
				end
			else
				new_level = max_level
			end
			if max_level >= LEVEL_MAX + 1 - range then
				new_id = kind
			else
				new_id = floodable_node
			end
		end

		-- Nothing changed: the next one
		local old_down = param2_0 % 16 >= 8
		if new_id == id0 and (lt0 ~= "flowing" or
				(param2_0 % 8 == new_level % 8 and old_down == flowing_down)) then
			return nil
		end

		if floating_above and new_id == AIR then
			falling[#falling + 1] = {x = x0, y = y0, z = z0}
		end

		local new_param2
		if info(new_id).liquid_type == "flowing" then
			new_param2 = (flowing_down and FLOW_DOWN_MASK or 0) + new_level % 8
		else
			new_param2 = param2_0 - param2_0 % 16
		end

		-- on_flood(): the node in the way says whether it goes
		if floodable_node ~= AIR then
			local i_old = info(id0)
			if i_old.on_flood then
				local pos = {x = x0, y = y0, z = z0}
				local oldnode = {name = core.get_name_from_content_id(id0),
						param1 = 0, param2 = param2_0}
				local newnode = {name = core.get_name_from_content_id(new_id),
						param1 = 0, param2 = new_param2}
				if i_old.on_flood(pos, oldnode, newnode) then
					return nil
				end
			end
		end
		return {x0, y0, z0, new_id, new_param2, flows, nf, airs, na}
	end
end

-- A pass is cut at this many microseconds as well as at loop_max: a fresh
-- VoxeLibre world's ocean queues half a million nodes and 20000 of them
-- took a 4 s step, under which a click's answer came after the next
-- scan (the driven first run's crafts, 2026-09-22). A cut pass is
-- followed by the next one sooner than liquid_update, so the queue
-- drains at the same rate in shorter steps.
-- Measured 2026-09-22 (seed 5 VoxeLibre, no client): the decisions are
-- a third of a pass and the writes after them two thirds -- 15 000
-- nodes, 600 ms -- so the loop's cut is at a third of the step wanted.
-- simplified: a fixed 100 ms; a setting when a game wants it.
local PASS_US = 100000
local cut_short = false

local function transform(loop_max)
	local loops = 0
	local t0 = core.get_us_time()
	cut_short = false
	local must_reflow = {}
	local changed = {}
	local falling = {}
	-- Official's loop: the queue in arrival order, what a change queues
	-- taken in the same pass while the budget lasts -- which is what
	-- lets a dug column fill top to bottom in one pass, each node seeing
	-- the one above it already water
	while head <= tail and loops < loop_max do
		loops = loops + 1
		if loops % 64 == 0 and core.get_us_time() - t0 > PASS_US then
			cut_short = true
			break
		end
		local x0, y0, z0 = pop()
		local w = decide(x0, y0, z0, must_reflow, falling)
		if w then
			local k = key(x0, y0, z0)
			if not pending[k] then
				pending_list[#pending_list + 1] = w
			end
			pending[k] = w
			changed[#changed + 1] = {x = x0, y = y0, z = z0}
			local new_id, flows, nf, airs, na = w[4], w[6], w[7], w[8], w[9]
			-- The neighbours that follow from the change
			local new_lt = info(new_id).liquid_type
			if new_lt == "source" or new_lt == "flowing" then
				for i = 1, nf do
					if flows[i][4] ~= UPPER then
						push(flows[i][1], flows[i][2], flows[i][3])
					end
				end
				for i = 1, na do
					if airs[i][4] ~= UPPER then
						push(airs[i][1], airs[i][2], airs[i][3])
					end
				end
			else
				-- Turned to air: the flows beside it may have to as well
				for i = 1, nf do
					push(flows[i][1], flows[i][2], flows[i][3])
				end
			end
		end
	end
	-- The pass's writes, each position's last decision
	for _, w in ipairs(pending_list) do
		local last = pending[key(w[1], w[2], w[3])]
		core.__note_block_changed(last[1], last[2], last[3])
		set_node_raw(last[1], last[2], last[3], last[4], 0, last[5])
	end
	pending, pending_list = {}, {}
	for _, p in ipairs(must_reflow) do
		push(p[1], p[2], p[3])
	end
	if core.check_for_falling then
		for _, p in ipairs(falling) do
			core.check_for_falling(p)
		end
	end
	if #changed > 0 and core.registered_on_liquid_transformed then
		for _, f in ipairs(core.registered_on_liquid_transformed) do
			f(changed, {})
		end
	end
	return loops
end

-- A generated box: the liquids with somewhere to flow queued, as
-- Mapgen::updateLiquid does -- the scan is C++ (luanti.cpp, liquid_edges);
-- the sets it takes are every liquid id and every floodable id, read once
local liquid_ids, floodable_ids = nil, nil
function core.__liquid_scan_generated(x0, y0, z0, x1, y1, z1)
	if liquid_ids == nil then
		liquid_ids, floodable_ids = {}, {}
		for name, def in pairs(core.registered_nodes) do
			local id = core.get_content_id(name)
			if def.liquidtype and def.liquidtype ~= "none" then
				liquid_ids[#liquid_ids + 1] = id
			elseif def.floodable then
				floodable_ids[#floodable_ids + 1] = id
			end
		end
	end
	if #liquid_ids == 0 then
		return 0
	end
	local flat = __luanti_liquid_edges(x0, y0, z0, x1, y1, z1,
			liquid_ids, floodable_ids)
	for i = 1, #flat, 3 do
		push(flat[i], flat[i + 1], flat[i + 2])
	end
	return #flat / 3
end

-- Once every liquid_update seconds, the whole queue at most once
local due = 0
local said_n, said_at = 0, 0
function core.__step_liquids(dtime)
	due = due - dtime
	if due > 0 then
		return 0
	end
	due = tonumber(core.settings:get("liquid_update")) or 1.0
	local loop_max = math.min(tail - head + 1,
			tonumber(core.settings:get("liquid_loop_max")) or 100000)
	if loop_max <= 0 then
		return 0
	end
	local t0 = core.get_us_time()
	local n = transform(loop_max)
	local pass_us = core.get_us_time() - t0
	if pass_us > 500000 then
		core.log("warning", string.format("liquids: a pass of %d nodes took %d ms%s",
				n, pass_us / 1000, cut_short and " (cut)" or ""))
	end
	if cut_short then
		due = math.min(due, 0.25)
	end
	-- What the transform did, at most every five seconds
	said_n = said_n + n
	if core.get_us_time() - said_at > 5000000 then
		if said_n > 0 then
			-- And what the front of the queue is, since a queue that never
			-- empties is one that re-queues itself
			local sample = {}
			for i = head, math.min(tail, head + 3) do
				local q = queue[i]
				local id, _, p2 = get_node_raw(q[1], q[2], q[3])
				sample[#sample + 1] = string.format("%d,%d,%d %s/%d", q[1], q[2],
						q[3], core.get_name_from_content_id(id), p2)
			end
			core.log("info", string.format("liquids: %d nodes taken, %d queued: %s",
					said_n, tail - head + 1, table.concat(sample, "; ")))
		end
		said_n, said_at = 0, core.get_us_time()
	end
	return n
end
