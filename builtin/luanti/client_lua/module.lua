-- Buildat: builtin/luanti/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The module's client half, and the first piece of it: the textures a
-- Luanti game names with an expression rather than with a file.
--
-- A tile in a node definition can be "default_dirt.png^grass_side.png" or
-- "[combine:32x16:0,0=a.png" -- a small language over raster operations. The
-- server cannot resolve them: what they are for is the client's own texture
-- size, filtering and texture packs, and two of them are resolved at runtime
-- (the crack over a node being dug, a palette's colour). So the server sends
-- the expressions and this composes them, under the same names the voxel
-- definitions were registered with.
--
-- texmod.lua reads the language and hands back compose_image() operations;
-- everything here is the files.
local log = buildat.Logger("luanti")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local voxelworld = require("buildat/module/voxelworld")

local M = {}

-- Beside this file: a module's client half is served whole, and this is how
-- one file of it reaches another
local ok, err, texmod = buildat.run_script_file("luanti/texmod.lua")
if not ok or type(texmod) ~= "table" then
	error("luanti: could not load texmod.lua: " .. tostring(err))
end

-- Where the composed textures go: a resource directory of its own, under the
-- cache, which is the only place compose_image() writes and
-- add_resource_dir() adds. A file lies in it under its resource name, so the
-- prefix is a directory here too; both are made by the first write.
local RESOURCE_DIR = buildat.get_cache_path() .. "/luanti_res"
local RESOURCE_PREFIX = "luanti_texmod/"
-- What the server serves the game's own files as; see media_resource_name()
-- in builtin/luanti/luanti.cpp
local MEDIA_PREFIX = "luanti_media/"

local dir_added = false
-- The directory is a resource directory once there is something in it: the
-- first file made it, and what comes after it is looked up by name -- a
-- nested expression blits the pieces it is made of.
local function added_dir()
	if not dir_added then
		dir_added = buildat.add_resource_dir(RESOURCE_DIR)
	end
end
-- Expression -> the resource name it was composed under, for this run. The
-- files outlive it, but composing one twice costs only the work.
local composed = {}

local function hex_hash(s)
	return buildat.hex(buildat.sha1(s))
end

local function resource_of(expr)
	return RESOURCE_PREFIX .. hex_hash(expr) .. ".png"
end

local function path_of(resource)
	return RESOURCE_DIR .. "/" .. resource
end

-- A colour of the expression's own, for one that cannot be composed: the
-- node is then a flat colour rather than a hole in the world, which is what
-- it was before the client resolved anything.
local function fallback_colour(expr)
	local h = hex_hash(expr)
	local function byte(i)
		return 64 + tonumber(string.sub(h, i, i + 1), 16) % 160
	end
	return {byte(1), byte(3), byte(5), 255}
end

local function write_fallback(resource, expr)
	local okc, errc = pcall(buildat.compose_image, {
		size = {16, 16},
		ops = {{op = "fill", color = fallback_colour(expr)}},
		write = path_of(resource),
	})
	if not okc then
		log:warning("could not write a fallback for \"" .. expr .. "\": " ..
				tostring(errc))
		return
	end
	added_dir()
end

-- One expression into one file, and the pieces it is made of into files of
-- their own. The name the top one is written under is the server's, because
-- that is what the voxel definitions say; a piece is named after itself.
local function compose(top_expr, top_resource)
	local ctx
	ctx = {
		resource = function(name)
			return MEDIA_PREFIX .. name
		end,
		-- "[png:" carries a whole file; it becomes one, under a name of
		-- its own, and from there it is a file like any other
		png = function(bytes)
			local resource = RESOURCE_PREFIX .. hex_hash(bytes) .. ".png"
			if composed[resource] then
				return resource
			end
			local okc, errc = pcall(buildat.compose_image, {
				ops = {{op = "blit", src_data = bytes}},
				write = path_of(resource),
			})
			if not okc then
				log:warning("[png: could not be written: " .. tostring(errc))
				return nil
			end
			added_dir()
			composed[resource] = resource
			return resource
		end,
		compose = function(expr, ops, size)
			local resource = (expr == top_expr) and top_resource or
					resource_of(expr)
			if composed[expr] then
				return composed[expr]
			end
			local okc, errc = pcall(buildat.compose_image, {
				size = size,
				ops = ops,
				write = path_of(resource),
			})
			if not okc then
				log:warning("compose_image failed for \"" ..
						string.sub(expr, 1, 60) .. "\": " .. tostring(errc))
				return nil
			end
			added_dir()
			composed[expr] = resource
			return resource
		end,
	}
	return texmod.resolve(top_expr, ctx)
end

-- Any expression, composed under a name of its own: what the registry named
-- is composed when the server says so, and this is for the ones that turn up
-- later -- a formspec's background, an item's inventory image.
local function texture_of(expr)
	if expr == nil or expr == "" then
		return nil
	end
	if composed[expr] then
		return composed[expr]
	end
	local got = compose(expr, resource_of(expr))
	if got then
		added_dir()
	end
	return got
end

M.texture = texture_of

buildat.sub_packet("luanti:texmods", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local n = 0
	local failed = 0
	-- The pairs are flat: a resource name and then the expression it is for
	for i = 1, #values - 1, 2 do
		local resource = values[i]
		local expr = values[i + 1]
		if composed[expr] ~= resource then
			local got = compose(expr, resource)
			if got == resource then
				n = n + 1
			else
				-- Either the expression uses something texmod.lua does not
				-- build, or a file it names is not here
				log:info("texmod: a flat colour for \"" ..
						string.sub(expr, 1, 60) .. "\"")
				write_fallback(resource, expr)
				failed = failed + 1
			end
		end
	end
	log:info("luanti:texmods: " .. n .. " textures composed, " .. failed ..
			" could not be")
	for name, _ in pairs(texmod.unimplemented) do
		log:info("texmod: no \"" .. name .. "\" yet")
	end
	-- Whatever has been drawn already was drawn without these
	if n > 0 or failed > 0 then
		voxelworld.remesh_all()
	end
end)

--
-- What the player is carrying
--
-- The server sends this to one client -- the player's own -- whenever their
-- inventory has changed. What draws it is whoever is drawing: a formspec
-- once there is one, and the launcher's own line of text until then.

-- list name -> an array of item strings, one per slot; an empty slot is ""
M.inventory = {}

local inventory_subs = {}

-- sub_inventory(f) -> f(lists) every time the player's inventory changes,
-- and once now if one has already arrived
function M.sub_inventory(f)
	inventory_subs[#inventory_subs + 1] = f
	if next(M.inventory) then
		f(M.inventory)
	end
end

buildat.sub_packet("luanti:inventory", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local lists = {}
	local i = 1
	while i + 1 <= #values do
		local name = values[i]
		local size = tonumber(values[i + 1]) or 0
		local stacks = {}
		for slot = 1, size do
			stacks[slot] = values[i + 1 + slot] or ""
		end
		lists[name] = stacks
		i = i + 2 + size
	end
	M.inventory = lists
	for _, f in ipairs(inventory_subs) do
		f(lists)
	end
end)

--
-- The objects
--
-- Everything in a Luanti world that is not a node: the item a dig dropped,
-- whatever a mod added. The server says where they are every step and what
-- they look like when that changes; what makes something of it is here.
--
-- simplified: a cube or a flat sprite, both wearing one texture, and the
-- plain box for everything else. Luanti's meshes are two file formats of
-- their own and a milestone with them; see "what an object looks like" in
-- doc/plan/luanti_module_plan.md.

-- Where the objects go, which is the game's scene rather than this module's
-- business. Nothing is drawn until a game says.
local object_scene = nil
-- id -> {node =, kind =, texture =}. The material is held by the component
-- it was given to and is not kept here: see the comment in
-- extensions/luanti_client/world.lua about what happens when it is.
local object_nodes = {}
-- id -> {kind =, texture =}, as the server last said
local object_looks = {}

function M.set_scene(scene)
	object_scene = scene
end

local function object_texture(expr)
	local resource = texture_of(expr)
	if not resource then
		return nil
	end
	local tex = magic.cache:GetResource("Texture2D", resource)
	if tex then
		-- A Luanti game's textures are pixel art; smoothing them is wrong
		-- at every size
		tex.filterMode = magic.FILTER_NEAREST
	end
	return tex
end

local function make_object_node(look)
	local node = object_scene:CreateChild("luanti_object")
	local tex = object_texture(look.texture)
	if look.kind == "sprite" and tex then
		local set = node:CreateComponent("BillboardSet")
		set.numBillboards = 1
		set.faceCameraMode = magic.FC_ROTATE_XYZ
		set.sorted = true
		local material = magic.Material.new()
		-- Unlit and alpha-masked. A lit technique is wrong here: the light
		-- a voxel game needs is bright enough that a sprite under it comes
		-- out a white blob, and what a sprite wears is its own colours.
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/DiffUnlitAlpha.xml"))
		material:SetTexture(magic.TU_DIFFUSE, tex)
		set.material = material
		local b = set:GetBillboard(0)
		if b then
			b.size = magic.Vector2(0.5, 0.5)
			b.enabled = true
		end
		set:Commit()
		return node
	end
	local model = node:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	if tex then
		local material = magic.Material.new()
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/DiffUnlitAlpha.xml"))
		material:SetTexture(magic.TU_DIFFUSE, tex)
		model.material = material
	else
		-- Nothing to wear: the box it was before anything said otherwise
		model.material = magic.cache:GetResource("Material",
				"Materials/Stone.xml")
	end
	model.castShadows = true
	return node
end

-- A look that changed is a node made again: a billboard and a model are
-- different components, and one object is not redrawn often enough for the
-- difference to be worth keeping.
local function object_node(id)
	local have = object_nodes[id]
	local look = object_looks[id] or {kind = "box", texture = ""}
	if have and have.kind == look.kind and have.texture == look.texture then
		return have.node
	end
	if have then
		have.node:Remove()
	end
	local node = make_object_node(look)
	object_nodes[id] = {node = node, kind = look.kind,
			texture = look.texture}
	return node
end

buildat.sub_packet("luanti:object_props", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	for i = 1, #values - 2, 3 do
		object_looks[values[i]] = {kind = values[i + 1],
				texture = values[i + 2]}
	end
end)

buildat.sub_packet("luanti:objects", function(data)
	if not object_scene then
		return
	end
	local v = cereal.binary_input(data, {"array", "double"})
	local seen = {}
	local STRIDE = 8
	local i = 1
	while i + STRIDE - 1 <= #v do
		local id = tostring(math.floor(v[i]))
		seen[id] = true
		local node = object_node(id)
		node.position = magic.Vector3(v[i + 1], v[i + 2], v[i + 3])
		node.scale = magic.Vector3(v[i + 4], v[i + 5], v[i + 6])
		-- Luanti's rotation is radians and Urho's euler is degrees; a
		-- billboard turns with the camera and does not care
		node.rotation = magic.Quaternion(0, math.deg(v[i + 7]), 0)
		i = i + STRIDE
	end
	-- What is not in the list any more has been removed
	for id, have in pairs(object_nodes) do
		if not seen[id] then
			have.node:Remove()
			object_nodes[id] = nil
			object_looks[id] = nil
		end
	end
end)

--
-- The formspecs
--
-- The window a mod puts on the player's screen. formspec.lua says what the
-- elements are, formspec_ui.lua puts Urho3D elements there, and this is the
-- wiring: what a texture and an item and a list are, what a click on the
-- result means, and what goes back to the server.
--
-- simplified: nothing is picked up and put down. A slot is drawn and what is
-- in it is drawn, and moving an item between slots is an inventory action the
-- server has no packet for yet; buttons, fields, checkboxes and tabs are the
-- half that works. See "what is left of M4" in doc/plan/luanti_module_plan.md.
local ok_fs, err_fs, formspec = buildat.run_script_file("luanti/formspec.lua")
if not ok_fs or type(formspec) ~= "table" then
	error("luanti: could not load formspec.lua: " .. tostring(err_fs))
end
local ok_ui, err_ui, formspec_ui =
		buildat.run_script_file("luanti/formspec_ui.lua")
if not ok_ui or type(formspec_ui) ~= "table" then
	error("luanti: could not load formspec_ui.lua: " .. tostring(err_ui))
end

-- item name -> the expression it is drawn as; see core.__item_images()
local item_images = {}
-- The ones that have no image, said once each
local imageless = {}

-- "basenodes:stone 7" -> {name = "basenodes:stone", count = 7}
local function parse_stack(str)
	if str == nil or str == "" then
		return nil
	end
	local name, count = string.match(str, "^([^ ]+) *(%d*)")
	if name == nil or name == "" then
		return nil
	end
	return {name = name, count = tonumber(count) or 1}
end

local ui = nil
local form = nil          -- {formname =, spec =, at =, state =, drawn =}
local player_spec = ""    -- what the player's own inventory key opens
-- "x,y,z" -> the lists of the node the open form is about. One node, because
-- one form is about one node; see core.__send_node_inventory.
local node_inventory = {}

local function make_ui()
	if ui then
		return ui
	end
	ui = formspec_ui.new(magic, buildat, log, {
		texture = texture_of,
		item_image = function(item_name)
			local resource = texture_of(item_images[item_name])
			if not resource and not imageless[item_name] then
				imageless[item_name] = true
				log:info("item: no image for \"" .. item_name .. "\"")
			end
			return resource
		end,
		-- The player's own lists, or the node the form is about --
		-- "current_name" and "context" are that node, and a nodemeta:
		-- location names one outright. A detached inventory is nobody's
		-- here and draws empty.
		inventory = function(location, list_name)
			local lists = nil
			if location == "current_player" or
					string.sub(location, 1, 7) == "player:" then
				lists = M.inventory
			elseif location == "current_name" or location == "context" then
				lists = form and form.at and node_inventory[form.at] or nil
			else
				local at = string.match(location, "^nodemeta:(.*)$")
				lists = at and node_inventory[at] or nil
			end
			local stacks = lists and lists[list_name]
			if not stacks then
				return nil
			end
			local items = {}
			for i, str in ipairs(stacks) do
				items[i] = parse_stack(str)
			end
			return {size = #stacks, items = items}
		end,
		style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml"),
		-- A plain white pixel, which a box or a tint is drawn with. Composed
		-- rather than shipped: it is one operation and one file either way.
		white = texture_of("[fill:1x1:#ffffffff"),
	})
	return ui
end

-- How much of a stack a click picks up: the whole of it with the left
-- button, half with the right, the way Luanti's own inventory does.
--
-- simplified: what is picked up is what is put down. Luanti puts a single
-- item down with the right button and ten with the middle, which is a count
-- on the way down as well as on the way up.
local function take_count(stack, button)
	if button == "right" then
		return math.ceil(stack.count / 2)
	end
	return stack.count
end

local function send_action(held, slot)
	buildat.send_packet("luanti:inv_action", cereal.binary_output({
		"move", held.location, held.list, tostring(held.index),
		slot.location, slot.list, tostring(slot.index), tostring(held.count),
	}, {"array", "string"}))
end

local function form_fields()
	local out = {}
	for _, f in ipairs(form and form.drawn and form.drawn.fields or {}) do
		out[f.name] = f.edit and f.edit:GetText() or f.value
	end
	return out
end

local function send_fields(fields)
	local flat = {form.formname}
	for k, v in pairs(fields) do
		flat[#flat + 1] = tostring(k)
		flat[#flat + 1] = tostring(v)
	end
	buildat.send_packet("luanti:fields", cereal.binary_output(flat,
			{"array", "string"}))
end

local function close_form(quit)
	if not form then
		return
	end
	-- quit says the player closed it -- an exit button, escape -- which a
	-- game acts on: the death screen's respawn is "the player closed
	-- __builtin:death". A form the server took away gets no quit.
	if quit then
		local fields = form_fields()
		fields.quit = "true"
		send_fields(fields)
	end
	if form.drawn then
		form.drawn.window:Remove()
	end
	form = nil
end

local function draw_form()
	if form.drawn then
		form.drawn.window:Remove()
		form.drawn = nil
	end
	local elements, size, real = formspec.parse(form.spec)
	local root = magic.ui.root
	local w, h = root.width, root.height
	local layout = formspec.layout(size, real, w, h)
	form.drawn = make_ui():show(root, elements, layout, w, h, form.state)
end

local function show_form(formname, spec, at)
	close_form(false)
	if spec == "" then
		return
	end
	form = {formname = formname, spec = spec, at = at ~= "" and at or nil,
			state = {}}
	draw_form()
end

-- form_open() -> whether a form is on the screen, so that whoever else is
-- reading the mouse leaves it alone while one is
function M.form_open()
	return form ~= nil
end

-- What the player's own inventory key opens. Nothing here binds a key: which
-- key that is belongs to the game, and this is what it calls.
function M.open_player_inventory()
	if form then
		close_form(true)
		return
	end
	if player_spec == "" then
		log:info("no inventory formspec; the game has not set one")
		return
	end
	show_form("", player_spec)
end

-- A click, from whoever is reading the mouse. Returns whether the form took
-- it, so that a click that was not on one still digs.
function M.click(x, y, button)
	if not form or not form.drawn then
		return false
	end
	local lx = x - form.drawn.origin[1]
	local ly = y - form.drawn.origin[2]
	local function inside(e)
		return lx >= e.x and lx < e.x + e.w and ly >= e.y and ly < e.y + e.h
	end
	for _, b in ipairs(form.drawn.buttons) do
		if inside(b) then
			local fields = form_fields()
			fields[b.name] = ""
			if b.exit then
				fields.quit = "true"
			end
			send_fields(fields)
			if b.exit then
				close_form(false)
			end
			return true
		end
	end
	-- A tab or a checkbox: the form goes back with the new value in it, the
	-- way Luanti's own client sends one
	for _, t in ipairs(form.drawn.taps) do
		if inside(t) then
			local fields = form_fields()
			fields[t.name] = t.value
			if t.check then
				form.state.check[t.name] = t.value == "true"
				draw_form()
			end
			send_fields(fields)
			return true
		end
	end
	-- A slot: the stack in it is picked up, or what is held is put down in
	-- it. The move itself is the server's; what is held here is a drawing
	-- and the highlight formspec_ui puts on the slot it came from.
	for _, slot in ipairs(form.drawn.slots) do
		if lx >= slot.x and lx < slot.x + slot.size and
				ly >= slot.y and ly < slot.y + slot.size then
			if form.state.held then
				send_action(form.state.held, slot)
				form.state.held = nil
			elseif slot.stack then
				form.state.held = {location = slot.location, list = slot.list,
						index = slot.index,
						count = take_count(slot.stack, button)}
			end
			draw_form()
			return true
		end
	end
	-- Somewhere else on the form: what is held is put back down where it
	-- came from, which is nothing happening at all
	if form.state.held then
		form.state.held = nil
		draw_form()
	end
	-- Everything else on the form swallows the click without meaning
	-- anything, which is what keeps it from digging the node behind it
	return lx >= 0 and ly >= 0 and lx < form.drawn.size[1] and
			ly < form.drawn.size[2]
end

-- Escape closes it, which is the player closing it
function M.key(key)
	if form and key == magic.KEY_ESCAPE then
		close_form(true)
		return true
	end
	return false
end

-- The move was the server's to make, so what a form shows is stale until the
-- inventory comes back
M.sub_inventory(function()
	if form then
		draw_form()
	end
end)

buildat.sub_packet("luanti:formspec", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	show_form(values[1] or "", values[2] or "", values[3] or "")
end)

-- What is in the node the open form is about; the position leads
buildat.sub_packet("luanti:node_inventory", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local at = values[1]
	if at == nil then
		return
	end
	local lists = {}
	local i = 2
	while i + 1 <= #values do
		local name = values[i]
		local size = tonumber(values[i + 1]) or 0
		local stacks = {}
		for slot = 1, size do
			stacks[slot] = values[i + 1 + slot] or ""
		end
		lists[name] = stacks
		i = i + 2 + size
	end
	node_inventory = {[at] = lists}
	if form then
		draw_form()
	end
end)

buildat.sub_packet("luanti:player_formspec", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	player_spec = values[1] or ""
end)

buildat.sub_packet("luanti:item_images", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local n = 0
	for i = 1, #values - 1, 2 do
		item_images[values[i]] = values[i + 1]
		n = n + 1
	end
	log:info("luanti:item_images: " .. n .. " items")
end)

-- Asked for rather than sent, because a packet that arrives before the
-- script that subscribes to it has nowhere to go
buildat.send_packet("luanti:get_texmods", "")
buildat.send_packet("luanti:get_item_images", "")
buildat.send_packet("luanti:get_object_props", "")

return M
-- vim: set noet ts=4 sw=4:
