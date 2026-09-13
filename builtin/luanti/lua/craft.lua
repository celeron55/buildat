-- Buildat: builtin/luanti/lua/craft.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What a recipe makes. core.register_craft is Lua and records what a mod
-- wrote; this is the other half, which in Luanti is the C++ CraftDefManager:
-- given what is in a grid, which recipe it is and what comes out.
--
-- The five kinds Luanti has: shaped, which is a pattern that may sit
-- anywhere in the grid; shapeless, which is a multiset; cooking and fuel,
-- which are one item each; and toolrepair, which is two of the same worn
-- tool.
--
-- simplified: no crafting hash and no cache, so a craft walks every recipe.
-- Luanti groups them by a hash of the first item and by type. devtest has
-- ~200 recipes and nothing crafts in a loop; the upgrade path is a table
-- keyed the way Luanti keys it, built the first time anything crafts.

local function alias_of(name)
	return core.__aliases[name] or name
end

-- A recipe's cell against a name from the grid. "group:a,b" wants all of
-- them, which is Luanti's rule and not an or.
local function cell_matches(spec, name)
	if spec == nil or spec == "" then
		return name == nil or name == ""
	end
	if name == nil or name == "" then
		return false
	end
	local groups = string.match(spec, "^group:(.*)$")
	if groups then
		for g in string.gmatch(groups, "[^,]+") do
			if core.get_item_group(name, g) == 0 then
				return false
			end
		end
		return true
	end
	return alias_of(spec) == alias_of(name)
end

-- Rows of cells, padded to the widest row
local function rows_to_grid(rows)
	local w = 0
	for _, row in ipairs(rows) do
		if type(row) ~= "table" then
			return nil
		end
		w = math.max(w, #row)
	end
	local grid = {}
	for y, row in ipairs(rows) do
		grid[y] = {}
		for x = 1, w do
			grid[y][x] = row[x] or ""
		end
	end
	return grid, w, #rows
end

-- The empty border is not part of the pattern: a recipe drawn in the middle
-- of a 3x3 and the same one in a corner are the same recipe
local function trim(grid)
	local y0, y1, x0, x1 = nil, nil, nil, nil
	for y = 1, #grid do
		for x = 1, #grid[y] do
			if grid[y][x] ~= "" then
				y0 = y0 or y
				y1 = y
				if x0 == nil or x < x0 then x0 = x end
				if x1 == nil or x > x1 then x1 = x end
			end
		end
	end
	if y0 == nil then
		return {}, 0, 0
	end
	local out = {}
	for y = y0, y1 do
		local row = {}
		for x = x0, x1 do
			row[#row + 1] = grid[y][x]
		end
		out[#out + 1] = row
	end
	return out, x1 - x0 + 1, y1 - y0 + 1
end

local function grids_match(recipe_grid, input_grid)
	if #recipe_grid ~= #input_grid then
		return false
	end
	for y = 1, #recipe_grid do
		if #recipe_grid[y] ~= #input_grid[y] then
			return false
		end
		for x = 1, #recipe_grid[y] do
			if not cell_matches(recipe_grid[y][x], input_grid[y][x]) then
				return false
			end
		end
	end
	return true
end

local function shapeless_match(specs, names)
	local left = {}
	for _, name in ipairs(names) do
		if name ~= "" then
			left[#left + 1] = name
		end
	end
	local wanted = {}
	for _, spec in ipairs(specs) do
		if spec ~= "" then
			wanted[#wanted + 1] = spec
		end
	end
	if #wanted ~= #left then
		return false
	end
	-- Greedy, and the plain names go first so that a group does not eat the
	-- item a name was going to match
	table.sort(wanted, function(a, b)
		return (string.match(a, "^group:") and 1 or 0) <
				(string.match(b, "^group:") and 1 or 0)
	end)
	for _, spec in ipairs(wanted) do
		local found = nil
		for i, name in ipairs(left) do
			if cell_matches(spec, name) then
				found = i
				break
			end
		end
		if found == nil then
			return false
		end
		table.remove(left, found)
	end
	return true
end

local function replacements_of(recipe)
	local out = {}
	for _, pair in ipairs(recipe.replacements or {}) do
		out[#out + 1] = ItemStack(pair[2])
	end
	return out
end

-- Luanti's own: what is left of two of the same tool is what is left of
-- each, plus the wear a repair costs
local function repair(a, b, additional_wear)
	local uses = (65536 - a:get_wear()) + (65536 - b:get_wear())
	local wear = 65536 - uses + math.floor((additional_wear or 0) * 65536 + 0.5)
	if wear >= 65536 then
		return nil
	end
	local out = ItemStack(a)
	out:set_wear(math.max(0, wear))
	return out
end

local function names_of(stacks)
	local names = {}
	for i, stack in ipairs(stacks) do
		names[i] = stack:is_empty() and "" or stack:get_name()
	end
	return names
end

local function try_recipe(recipe, method, stacks, names, width)
	local kind = recipe.type or "shaped"
	if kind == "cooking" or kind == "fuel" then
		if method ~= kind then
			return nil
		end
		local n = 0
		local one = nil
		for _, name in ipairs(names) do
			if name ~= "" then
				n = n + 1
				one = name
			end
		end
		if n ~= 1 or not cell_matches(recipe.recipe, one) then
			return nil
		end
		if kind == "cooking" then
			return {item = ItemStack(recipe.output),
					time = recipe.cooktime or 3,
					replacements = replacements_of(recipe)}
		end
		return {item = ItemStack(""), time = recipe.burntime or 1,
				replacements = replacements_of(recipe)}
	end
	if method ~= "normal" then
		return nil
	end
	if kind == "toolrepair" then
		local worn = {}
		for _, stack in ipairs(stacks) do
			if not stack:is_empty() then
				worn[#worn + 1] = stack
			end
		end
		if #worn ~= 2 or worn[1]:get_name() ~= worn[2]:get_name() then
			return nil
		end
		local def = core.registered_items[worn[1]:get_name()]
		if def == nil or def.type ~= "tool" then
			return nil
		end
		local out = repair(worn[1], worn[2], recipe.additional_wear)
		if out == nil then
			return nil
		end
		return {item = out, time = 0, replacements = {}}
	end
	if kind == "shapeless" then
		if not shapeless_match(recipe.recipe or {}, names) then
			return nil
		end
		return {item = ItemStack(recipe.output), time = 0,
				replacements = replacements_of(recipe)}
	end
	if kind ~= "shaped" then
		return nil
	end
	local grid = rows_to_grid(recipe.recipe or {})
	if grid == nil then
		return nil
	end
	local input = {}
	for y = 1, math.ceil(#names / width) do
		input[y] = {}
		for x = 1, width do
			input[y][x] = names[(y - 1) * width + x] or ""
		end
	end
	if not grids_match((trim(grid)), (trim(input))) then
		return nil
	end
	return {item = ItemStack(recipe.output), time = 0,
			replacements = replacements_of(recipe)}
end

local EMPTY = function(method, width, stacks)
	return {item = ItemStack(""), time = 0, replacements = {}},
			{method = method, width = width, items = stacks}
end

function core.get_craft_result(input)
	input = input or {}
	local method = input.method or "normal"
	local width = input.width or 3
	if width < 1 then
		width = 1
	end
	local stacks = {}
	for i, item in ipairs(input.items or {}) do
		stacks[i] = ItemStack(item)
	end
	local names = names_of(stacks)
	for _, recipe in ipairs(core.__crafts) do
		local out = try_recipe(recipe, method, stacks, names, width)
		if out then
			-- One of each is what a craft takes, whatever the method
			local left = {}
			for i, stack in ipairs(stacks) do
				local s = ItemStack(stack)
				if not s:is_empty() then
					s:take_item(1)
				end
				left[i] = s
			end
			return out, {method = method, width = width, items = left}
		end
	end
	return EMPTY(method, width, stacks)
end

-- What a recipe looks like from the other end: given an output, the items
-- that make it. Luanti answers with the last registered one, and with a
-- width of 0 for anything that is not shaped.
local function recipe_to_table(recipe)
	local kind = recipe.type or "shaped"
	if kind == "shaped" then
		local grid, w = rows_to_grid(recipe.recipe or {})
		local items = {}
		if grid then
			for y = 1, #grid do
				for x = 1, w do
					items[(y - 1) * w + x] = grid[y][x]
				end
			end
		end
		return {method = "normal", width = w or 0, items = items,
				output = recipe.output, type = "shaped"}
	end
	if kind == "shapeless" then
		local items = {}
		for i, spec in ipairs(recipe.recipe or {}) do
			items[i] = spec
		end
		return {method = "normal", width = 0, items = items,
				output = recipe.output, type = "shapeless"}
	end
	return {method = kind, width = 0, items = {recipe.recipe},
			output = recipe.output or "", type = kind}
end

local function output_matches(recipe, wanted)
	if recipe.output == nil then
		return false
	end
	local out = ItemStack(recipe.output)
	local want = ItemStack(wanted)
	if out:is_empty() or want:is_empty() then
		return false
	end
	return alias_of(out:get_name()) == alias_of(want:get_name())
end

function core.get_craft_recipe(output)
	local found = nil
	for _, recipe in ipairs(core.__crafts) do
		if output_matches(recipe, output) then
			found = recipe
		end
	end
	if found == nil then
		return {method = "normal", width = 0, items = {}}
	end
	return recipe_to_table(found)
end

function core.get_all_craft_recipes(output)
	local all = {}
	for _, recipe in ipairs(core.__crafts) do
		if output_matches(recipe, output) then
			all[#all + 1] = recipe_to_table(recipe)
		end
	end
	if #all == 0 then
		return nil
	end
	return all
end

-- Luanti takes either an output or a recipe here, and answers with whether
-- it removed anything
function core.clear_craft(spec)
	if type(spec) ~= "table" then
		error("clear_craft(): needs a table")
	end
	local removed = false
	for i = #core.__crafts, 1, -1 do
		local recipe = core.__crafts[i]
		local hit = false
		if spec.output then
			hit = output_matches(recipe, spec.output)
		elseif spec.recipe then
			local names = {}
			local rows = spec.recipe
			if type(rows[1]) == "table" then
				local grid, w, h = rows_to_grid(rows)
				for y = 1, h do
					for x = 1, w do
						names[(y - 1) * w + x] = grid[y][x]
					end
				end
				hit = try_recipe(recipe, "normal", {}, names, w) ~= nil
			else
				for k, v in ipairs(rows) do
					names[k] = v
				end
				hit = try_recipe(recipe, "normal", {}, names, #names) ~= nil
			end
		end
		if hit then
			table.remove(core.__crafts, i)
			removed = true
		end
	end
	return removed
end

-- vim: set noet ts=4 sw=4:
