-- **A palette entry fitted to colours sampled off a real surface**
-- ([FP_SAMPLE_FIT]): plain Lua, no engine call (test/fit_check.lua runs
-- it). Everything is in the shader's space (Palette.glsl): the stored sRGB
-- values multiplied as they are, linear only to average the samples and
-- for ΔE.
--
-- simplified: the surface is taken as its darkest, middle and lightest
-- texel in equal parts (a wood's ring and streak at 0, 0.5 and 1; the
-- knots and the mottles left out), and samples are compared to those
-- three. A real grain's share of dark and light differs; the residual
-- swatches show what that leaves.
local M = {}

local G = 2.2
local function rgb3(v)
	return {math.floor(v / 65536) % 256 / 255, math.floor(v / 256) % 256 / 255,
			v % 256 / 255}
end
local function to_int(c)
	local v = 0
	for i = 1, 3 do
		v = v * 256 + math.floor(math.max(0, math.min(1, c[i])) * 255 + 0.5)
	end
	return v
end
local function luma(c)
	return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end
-- The linear mean, turned back
local function mean(cs)
	local s = {0, 0, 0}
	for _, c in ipairs(cs) do
		for i = 1, 3 do
			s[i] = s[i] + math.max(0, c[i]) ^ G
		end
	end
	for i = 1, 3 do
		s[i] = (s[i] / #cs) ^ (1 / G)
	end
	return s
end
local function lab(c)
	local r, g, b = math.max(0, c[1]) ^ G, math.max(0, c[2]) ^ G,
			math.max(0, c[3]) ^ G
	local function f(t)
		return t > 0.008856 and t ^ (1 / 3) or 7.787 * t + 16 / 116
	end
	local x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047)
	local y = f(0.2126 * r + 0.7152 * g + 0.0722 * b)
	local z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
	return {116 * y - 16, 500 * (x - y), 200 * (y - z)}
end
local function de(a, b)
	local p, q = lab(a), lab(b)
	return math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2 + (p[3] - q[3]) ^ 2)
end
M.de = function(a, b) return de(rgb3(a), rgb3(b)) end

local WOOD, PANELING, STONE, WALLPAPER, LAMP, GLASS, TILE = 1, 10, 2, 3, 4, 5, 7

-- The natural colour's factor on the own colour at the darkest, middle
-- and lightest texel, at grain contrast c (Palette.glsl's wood and
-- paneling; the other types one flat colour here)
local function factors(kind, c)
	if kind ~= WOOD and kind ~= PANELING then
		return 1, 1, 1
	end
	local lo = (0.9 - 0.18 * c) * (0.98 - 0.06 * c)
	local hi = (0.9 + 0.18 * c) * (0.98 + 0.06 * c)
	if kind == PANELING then
		-- The boards differ by 0.93 to 1.07 besides the grain
		lo, hi = lo * 0.93, hi * 1.07
	end
	return lo, 0.9 * 0.98, hi
end

-- The surface's darkest, middle and lightest colour, and their mean.
-- e: {kind, base, paint (3-vectors), finish, o, c}
local function look(e)
	local out = {}
	for j, f in ipairs({factors(e.kind, e.c)}) do
		local a = {}
		for i = 1, 3 do
			local nat = e.base[i] * f
			if e.finish == 0 then
				a[i] = nat * e.paint[i]
			elseif e.finish == 1 then
				a[i] = e.paint[i] * (0.85 + 0.15 * f)
			else
				a[i] = nat + (e.paint[i] - nat) * e.o
			end
		end
		out[j] = a
	end
	out[4] = mean({out[1], out[2], out[3]})
	return out
end

-- The paint (and a stain's opacity) that makes the middle texel t; false
-- where none does (over its colour: paint only darkens)
local function solve_paint(e, t)
	local _, fm = factors(e.kind, e.c)
	if e.finish == 1 then
		for i = 1, 3 do
			e.paint[i] = math.min(1, t[i] / (0.85 + 0.15 * fm))
		end
		return true
	end
	local n = {}
	for i = 1, 3 do
		n[i] = math.max(e.base[i] * fm, 1e-4)
	end
	if e.finish == 0 then
		for i = 1, 3 do
			local p = t[i] / n[i]
			-- A little over is the aim's overshoot, clamped; the error
			-- carries it
			if p > 1.03 then
				return false
			end
			e.paint[i] = math.min(1, p)
		end
		return true
	end
	-- The least opaque stain: per channel, o >= 1 - t/n where t is darker
	-- than the wood, o >= (t - n)/(1 - n) where it is lighter
	local o = 0
	for i = 1, 3 do
		if t[i] < n[i] then
			o = math.max(o, 1 - t[i] / n[i])
		elseif t[i] > n[i] and n[i] < 1 then
			o = math.max(o, (t[i] - n[i]) / (1 - n[i]))
		end
	end
	o = math.min(1, math.ceil(o * 1000 - 1e-6) / 1000)
	-- Under 1 % a stain is the bare wood, and its paint only the rounding
	if o < 0.01 then
		return false
	end
	e.o = o
	for i = 1, 3 do
		e.paint[i] = math.max(0, math.min(1, (t[i] - (1 - o) * n[i]) / o))
	end
	return true
end

-- The grain contrast whose darkest-to-lightest luma is the samples'
local function solve_contrast(e, spread)
	local lo, hi = 0, 3
	for _ = 1, 30 do
		e.c = (lo + hi) / 2
		local l = look(e)
		if luma(l[3]) - luma(l[1]) < spread then
			lo = e.c
		else
			hi = e.c
		end
	end
	e.c = (lo + hi) / 2
end

-- e fitted to the targets in place: the paint (and o, c) solved, the middle
-- aimed so that the mean of the three lands on the samples' mean. False
-- where the paint cannot reach them.
local function solve(e, tg)
	local t = {tg.m[1], tg.m[2], tg.m[3]}
	for _ = 1, 6 do
		if not solve_paint(e, t) then
			return false
		end
		if tg.n > 1 and (e.kind == WOOD or e.kind == PANELING) then
			solve_contrast(e, tg.spread)
		end
		local l = look(e)
		for i = 1, 3 do
			t[i] = t[i] * (tg.m[i] + 1e-3) / (l[4][i] + 1e-3)
		end
	end
	return solve_paint(e, t)
end

-- An entry's numbers back in its fields' units, and looked at as stored
local function rounded(e)
	local r = {kind = e.kind, finish = e.finish, base = rgb3(to_int(e.base)),
		paint = rgb3(to_int(e.paint)), o = math.floor(e.o * 1000 + 0.5) / 1000,
		c = math.floor(e.c * 1000 + 0.5) / 1000, color2 = e.color2}
	return r
end
local function err(e, tg)
	local l = look(e)
	local x = de(l[4], tg.m)
	if tg.n > 1 then
		x = x + de(l[1], tg.dark) + de(l[3], tg.light)
	end
	return x, l
end

local function targets(cs)
	local tg = {n = #cs, m = mean(cs)}
	tg.dark, tg.light = cs[1], cs[1]
	for _, c in ipairs(cs) do
		if luma(c) < luma(tg.dark) then tg.dark = c end
		if luma(c) > luma(tg.light) then tg.light = c end
	end
	tg.spread = luma(tg.light) - luma(tg.dark)
	return tg
end

-- One flat colour (drywall, plaster, fabric, metal, and stone, tile or
-- wallpaper's own colour): over its colour the own colour is raised
-- where the paint would have to lighten it
local function fit_flat(e, tg)
	if e.finish == 0 then
		local f = 1
		for i = 1, 3 do
			f = math.max(f, tg.m[i] / math.max(e.base[i], 1e-3))
		end
		for i = 1, 3 do
			e.base[i] = math.min(1, e.base[i] * f)
		end
	end
	solve(e, tg)
end

-- The samples split in two by Lab distance (k-means, k = 2), the larger
-- group first; nil when the two are not clearly apart (ΔE 15)
local function split(cs)
	if #cs < 2 then
		return nil
	end
	local tg = targets(cs)
	local a, b = tg.dark, tg.light
	local ga, gb
	for _ = 1, 10 do
		ga, gb = {}, {}
		for _, c in ipairs(cs) do
			table.insert(de(c, a) <= de(c, b) and ga or gb, c)
		end
		if #ga == 0 or #gb == 0 then
			return nil
		end
		a, b = mean(ga), mean(gb)
	end
	if de(a, b) <= 15 then
		return nil
	end
	if #gb > #ga then
		ga, gb = gb, ga
	end
	return ga, gb
end

local FINISHES = {[0] = "Over its colour", "White undercoat", "Stain"}

-- The fit of entry p (its ints) to samples (rgb ints), woods the named
-- species ({name, rgb}). Returns nil for a lamp or no samples, else
-- {ints = the fields that change, changes = {"Own colour: Pine -> Oak",
-- ...}, look = {darkest, middle, lightest, mean} as rgb ints, target =
-- {darkest, mean, lightest} of the samples, near = each sample's ΔE to
-- the nearest of the look, err}.
function M.fit(p, samples, woods)
	if p.kind == LAMP or #samples == 0 then
		return nil
	end
	local cs = {}
	for i, v in ipairs(samples) do
		cs[i] = rgb3(v)
	end
	local tg = targets(cs)
	local cur = {kind = p.kind, base = rgb3(p.base), paint = rgb3(p.color),
		finish = p.finish, o = p.opacity / 1000, c = p.contrast / 1000,
		color2 = p.color2}
	local function copy(e, over)
		local r = {}
		for k, v in pairs(e) do
			r[k] = type(v) == "table" and {v[1], v[2], v[3]} or v
		end
		for k, v in pairs(over or {}) do
			r[k] = v
		end
		return r
	end
	local best
	if p.kind == WOOD or p.kind == PANELING then
		-- Candidates: the entry as it is, then each species over its colour
		-- and stained, the entry's own colour among them
		local cands = {{e = copy(cur), changes = 0}}
		local species = {{rgb = p.base}}
		for _, w in ipairs(woods) do
			if w.rgb ~= p.base then
				species[#species + 1] = w
			end
		end
		local named_best = math.huge
		local finishes = cur.finish == 1 and {1} or {0, 2}
		for _, s in ipairs(species) do
			for _, fin in ipairs(finishes) do
				local e = copy(cur, {base = rgb3(s.rgb), finish = fin})
				if solve(e, tg) then
					e = rounded(e)
					cands[#cands + 1] = {e = e, err = err(e, tg),
						changes = (s.rgb ~= p.base and 1 or 0) +
								(fin ~= p.finish and 1 or 0)}
					named_best = math.min(named_best, cands[#cands].err)
				end
			end
		end
		if named_best > 2 then
			-- No named species reaches it: a free own colour, clear paint
			local e = copy(cur, {finish = 0, paint = {1, 1, 1}})
			local _, fm = factors(p.kind, cur.c)
			for i = 1, 3 do
				e.base[i] = math.min(1, tg.m[i] / fm)
			end
			e.paint = {1, 1, 1}
			if tg.n > 1 then
				solve_contrast(e, tg.spread)
			end
			e = rounded(e)
			cands[#cands + 1] = {e = e, err = err(e, tg), changes = 2}
			-- And a painted board: a white undercoat when nothing varies
			if tg.spread / math.max(luma(tg.m), 0.01) < 0.05 then
				e = copy(cur, {finish = 1})
				solve(e, tg)
				e = rounded(e)
				cands[#cands + 1] = {e = e, err = err(e, tg), changes = 1}
			end
		end
		cands[1].err = err(cands[1].e, tg)
		local least = math.huge
		for _, c in ipairs(cands) do
			least = math.min(least, c.err)
		end
		-- Within ΔE 2 of the best, the one that changes least
		for _, c in ipairs(cands) do
			if c.err <= least + 2 and (not best or c.changes < best.changes or
					(c.changes == best.changes and c.err < best.err)) then
				best = c
			end
		end
		best = best.e
	elseif p.kind == GLASS then
		best = copy(cur, {base = tg.m})
	else
		local main, second = cs, nil
		if p.kind == STONE or p.kind == TILE or p.kind == WALLPAPER then
			local a, b = split(cs)
			if a then
				main, second = a, b
			end
		end
		local e = copy(cur)
		fit_flat(e, targets(main))
		if second then
			e.color2 = to_int(mean(second))
		end
		best = rounded(e)
		tg = targets(main)
	end
	if err(cur, tg) <= 2 and p.kind ~= GLASS and
			not (p.kind == STONE or p.kind == TILE or p.kind == WALLPAPER) then
		-- Already there: nothing changes
		best = cur
	end

	-- What changes, in the fields' units
	local ints = {base = to_int(best.base), color = to_int(best.paint),
		finish = best.finish, opacity = math.floor(best.o * 1000 + 0.5),
		contrast = math.floor(best.c * 1000 + 0.5), color2 = best.color2}
	local name = {}
	for _, w in ipairs(woods) do
		name[w.rgb] = w.name
	end
	local function say(v)
		return name[v] or string.format("%06x", v)
	end
	local LABELS = {base = "Own colour", color = "Paint", finish = "Finish",
		opacity = "Stain %", contrast = "Grain contrast", color2 = "Second colour"}
	local out = {ints = {}, changes = {}}
	for _, k in ipairs({"base", "finish", "color", "opacity", "contrast",
			"color2"}) do
		local was = k == "color" and p.color or p[k]
		if ints[k] ~= was and not (k == "opacity" and ints.finish ~= 2) and
				not (k == "contrast" and p.kind ~= WOOD and p.kind ~= PANELING) then
			out.ints[k] = ints[k]
			local f = (k == "base" or k == "color" or k == "color2") and say or
					k == "finish" and function(v) return FINISHES[v] end or
					function(v) return tostring(v / 10) end
			out.changes[#out.changes + 1] = LABELS[k] .. ": " .. f(was) .. " -> " ..
					f(ints[k])
		end
	end
	local x, l = err(best, tg)
	out.err = x
	out.look = {to_int(l[1]), to_int(l[2]), to_int(l[3]), to_int(l[4])}
	out.target = {to_int(tg.dark), to_int(tg.m), to_int(tg.light)}
	out.near = {}
	for i, c in ipairs(cs) do
		local d = math.huge
		for j = 1, 3 do
			d = math.min(d, de(c, l[j]))
		end
		out.near[i] = d
	end
	return out
end

-- The samples as kept on the entry (strs.samples): "rrggbb name" each,
-- ';' between
function M.parse(s)
	local out = {}
	for item in (s or ""):gmatch("[^;]+") do
		local hex, name = item:match("^(%x%x%x%x%x%x) ?(.*)$")
		if hex then
			out[#out + 1] = {rgb = tonumber(hex, 16), name = name}
		end
	end
	return out
end
function M.format(list)
	local parts = {}
	for i, s in ipairs(list) do
		parts[i] = string.format("%06x", s.rgb) ..
				(s.name ~= "" and " " .. s.name:gsub(";", ",") or "")
	end
	return table.concat(parts, ";")
end

M.look = function(p)
	local l = look({kind = p.kind, base = rgb3(p.base), paint = rgb3(p.color),
		finish = p.finish, o = p.opacity / 1000, c = p.contrast / 1000})
	return {to_int(l[1]), to_int(l[2]), to_int(l[3]), to_int(l[4])}
end

return M
