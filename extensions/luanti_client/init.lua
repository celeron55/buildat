-- Buildat: extension/luanti_client/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A Luanti client for buildat_client: connect to an unmodified Luanti server
-- and do the client's side of its protocol.
--
--   $ bin/buildat_client -m luanti_client
--
-- This is where it is at: the connection, the login and a status screen that
-- says what the server sent. Rendering the world, formspecs, the HUD and input
-- come next; see doc/luanti_client.txt.
local log = buildat.Logger("luanti_client")
local magic = require("buildat/extension/urho3d").safe
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils").safe
local network = require("buildat/extension/network")
local path = __buildat_extension_path("luanti_client")
local srp = dofile(path.."/srp.lua")
local engine_test = dofile(path.."/engine_test.lua")
local luanti = dofile(path.."/client.lua")
local world = dofile(path.."/world.lua")
local nodedef = dofile(path.."/nodedef.lua")
local media = dofile(path.."/media.lua")
local player = dofile(path.."/player.lua")
local texmod = dofile(path.."/texmod.lua")
local itemdef = dofile(path.."/itemdef.lua")
local inventory = dofile(path.."/inventory.lua")
local formspec = dofile(path.."/formspec.lua")
local formspec_ui = dofile(path.."/formspec_ui.lua")
local objects = dofile(path.."/objects.lua")
local M = {safe = nil}

-- BUILDAT_LUANTI_ADDRESS is for scripted runs (bin/buildat_client -c ...),
-- which cannot easily clear a text field
local DEFAULT_ADDRESS = os.getenv("BUILDAT_LUANTI_ADDRESS") or "localhost:30000"
local DEFAULT_NAME = os.getenv("BUILDAT_LUANTI_NAME") or "buildat"

-- How far the camera sees, and how far out blocks are kept, in nodes. The
-- client asks the server for blocks by the same distance; see
-- WANTED_RANGE_BLOCKS in client.lua.
local FAR_CLIP = 240
local DROP_DISTANCE = 260
-- Degrees of look per pixel of mouse movement
local MOUSE_SENSITIVITY = 0.15

-- How far the player can reach when the item they are holding does not say,
-- which is Luanti's own default
local POINT_RANGE = 4

-- How many of the player's main slots the hotbar shows. Luanti's own default,
-- and what the number keys reach.
local HOTBAR_SLOTS = 8

-- Media files are asked for in batches, so that one REQUEST_MEDIA does not
-- turn into hundreds of split chunks in one go
local MEDIA_PER_REQUEST = 200
-- The voxel registry is rebuilt when the media that was asked for has all
-- arrived, and this long after asking whether it has or not: a file the server
-- never sends must not hold every other texture back forever
local MEDIA_WAIT_S = 15

-- Where the server's media goes. The whole directory is one resource dir and
-- the files inside it are addressed as "<server>/<name>", so two servers with
-- a same-named texture do not collide.
local MEDIA_ROOT = __buildat_get_path("cache").."/luanti_media"
local media_root_added = false

-- Luanti's day/night ratio, from its daynightratio.h: 0.175 at night, 1.0 in
-- the day, with a ramp between 4375 and 6125 and the same one mirrored around
-- 12000 for the evening.
local DAYNIGHT_RAMP = {
	{4375, 0.175}, {4625, 0.175}, {4875, 0.250}, {5125, 0.350},
	{5375, 0.500}, {5625, 0.675}, {5875, 0.875}, {6125, 1.000},
}

local function daynight_ratio(time_of_day)
	-- A scripted run cannot wait for morning, and a screenshot of the world
	-- at night says little about how it looks
	if os.getenv("BUILDAT_LUANTI_FORCE_DAY") then
		return 1.0
	end
	local t = time_of_day % 24000
	if t > 12000 then
		t = 24000 - t
	end
	if t <= DAYNIGHT_RAMP[2][1] then
		return DAYNIGHT_RAMP[1][2]
	end
	for i = 2, #DAYNIGHT_RAMP do
		if DAYNIGHT_RAMP[i][1] > t then
			local a, b = DAYNIGHT_RAMP[i - 1], DAYNIGHT_RAMP[i]
			local f = (t - a[1]) / (b[1] - a[1])
			return a[2] + f * (b[2] - a[2])
		end
	end
	return 1.0
end

local function labeled_edit(parent, label, value)
	local text = parent:CreateChild("Text")
	text:SetStyleAuto()
	text.text = label
	local edit = parent:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 24
	edit.minWidth = 300
	edit:SetText(value or "")
	return edit
end

local function split_address(address)
	local host, port = address:match("^%[(.*)%]:(%d+)$")
	if not host then
		host, port = address:match("^([^:]+):(%d+)$")
	end
	if not host then
		return address, 30000
	end
	return host, tonumber(port)
end

-- The screen that shows what the client is doing, and drives it every frame
local function show_client(host, port, name, password)
	local root = uistack.main:push({desc="luanti_client"})
	-- Held rather than read back off the element: the sandbox hands out no
	-- resource it did not just wrap
	local style = magic.cache:GetResource(
			"XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	-- Text in the top left corner rather than a window: the world is behind
	-- it. Under the UI's own root, like the chat below and for the same
	-- reason: the element this extension was given is only as big as what is
	-- in it, so an alignment inside it lands nowhere in particular.
	local status_text = magic.ui.root:CreateChild("Text")
	status_text.defaultStyle = style
	status_text:SetStyleAuto()
	status_text:SetAlignment(HA_LEFT, VA_TOP)
	status_text:SetPosition(8, 8)
	status_text.color = magic.Color(1.0, 1.0, 1.0)

	-- What has been said, at the bottom of the screen where Luanti puts it.
	-- Under the UI's own root rather than the element this extension was
	-- given, because that one is only as big as what is in it and an
	-- alignment inside it lands nowhere in particular; taken away again when
	-- the client is left.
	local chat_text = magic.ui.root:CreateChild("Text")
	-- The style before SetStyleAuto, which is what reads it; the UI's root
	-- has none of its own
	chat_text.defaultStyle = style
	chat_text:SetStyleAuto()
	chat_text:SetAlignment(HA_LEFT, VA_BOTTOM)
	chat_text:SetPosition(8, -34)
	chat_text.color = magic.Color(1.0, 1.0, 0.9)

	local lines = {"Luanti: "..host..":"..port}
	local function add_line(text)
		lines[#lines + 1] = text
		while #lines > 10 do
			table.remove(lines, 2) -- Keep the address line
		end
		status_text.text = table.concat(lines, "\n")
	end

	add_line("Asking to connect...")

	network.udp_connect(host, port, function(socket, err)
		if not socket then
			add_line("Could not connect: "..tostring(err))
			return
		end
		local client = luanti.new(socket, {
				name = name,
				password = password,
				on_status = add_line,
		}, log)

		local view = world.new(magic, buildat.safe, log, {
				far_clip = FAR_CLIP,
		})

		client.on_block = function(block)
			view:set_block(block)
		end

		client.on_node = function(x, y, z, param0, param1)
			view:set_node(x, y, z, param0, param1)
		end

		-- The server's media, and what the node definitions make of it
		local server_key = media.server_key(host, port)
		local store = media.new(buildat, log, MEDIA_ROOT.."/"..server_key)
		-- One resource dir for all servers; see MEDIA_ROOT
		if not media_root_added then
			__buildat_mkdir(MEDIA_ROOT)
			buildat.add_resource_dir(MEDIA_ROOT)
			media_root_added = true
		end

		local node_defs = nil
		local node_by_name = {}
		local announced = nil
		local to_ask = {}
		local media_asked_at = nil
		local registry_stale = false

		-- Composed textures go beside the server's own files, under a name
		-- nothing the server sends can collide with: a media name is a file
		-- name and never a path.
		local COMPOSED_DIR = MEDIA_ROOT.."/"..server_key.."/composed"
		__buildat_mkdir(COMPOSED_DIR)

		-- Expression -> the resource name it was composed under. The files
		-- outlive the run, so a second one composes nothing.
		local composed = {}
		local composed_count = 0

		local function hex_hash(s)
			return (buildat.sha1(s):gsub(".", function(c)
				return string.format("%02x", c:byte())
			end))
		end

		-- A tile's texture name -> a resource name, or nil for one that
		-- cannot be built. texmod.lua reads Luanti's modifier language and
		-- buildat.compose_image() does the pixels; a name with no modifiers
		-- in it is the file itself.
		local texmod_ctx = {
			resource = function(name)
				if not store:have_file(name) then
					return nil
				end
				return server_key.."/"..name
			end,
			compose = function(expr, ops, size)
				local resource = composed[expr]
				if resource then
					return resource
				end
				local file = hex_hash(expr)..".png"
				resource = server_key.."/composed/"..file
				local path = COMPOSED_DIR.."/"..file
				local f = io.open(path, "rb")
				if f then
					f:close()
				else
					local ok, err = pcall(buildat.compose_image,
							{size = size, ops = ops, write = path})
					if not ok then
						log:warning("compose_image failed for \""..expr..
								"\": "..tostring(err))
						return nil
					end
					composed_count = composed_count + 1
				end
				composed[expr] = resource
				return resource
			end,
		}

		-- The texture expression for one of a node's six faces.
		--
		-- Luanti draws a tile as up to two layers, the tile and an overlay
		-- over it, and each is drawn in a colour: its own when the game gave
		-- it one, and the node's otherwise. That is how a grass block's side
		-- is plain dirt with a green edge on top of it. Written as an
		-- expression, the two layers are a "^" chain and a colour is a
		-- [multiply, so texmod.lua does the work.
		--
		-- simplified: the node's colour is the one in its definition, not the
		-- one its paramtype2 picks out of a palette, so a node type is one
		-- colour everywhere rather than the biome's. Every palette node in
		-- this game also carries the colour it is mostly drawn in, which is
		-- why this looks right; the upgrade path is a voxel id per (node,
		-- param2) pair, which is also what a facedir needs.
		local function tile_expression(def, i)
			local function layer(tile)
				if not tile or tile.name == "" then
					return nil
				end
				local color = tile.color or def.color
				if not color or (color[1] == 255 and color[2] == 255 and
						color[3] == 255) then
					return tile.name
				end
				return "("..tile.name.."^[multiply:"..
						string.format("#%02x%02x%02x", color[1], color[2],
						color[3])..")"
			end
			local base = layer(def.tiles[i])
			if not base then
				return nil
			end
			local overlay = layer(def.overlays and def.overlays[i])
			if overlay then
				return base.."^"..overlay
			end
			return base
		end

		-- A tile whose texture is a strip of animation frames has to be cut
		-- down to one before it goes in an atlas; which frame it is on is
		-- not something this draws yet, so it is the first. How many frames
		-- there are is not in the definition -- Luanti works it out from the
		-- texture's own proportions -- so the crop asks for square cells.
		--
		-- simplified: the frame never advances, so water and lava and fire
		-- stand still. The upgrade path is one composed texture per frame
		-- and a voxel id per frame, or a shader that scrolls the atlas.
		local FIRST_FRAME = {
			key = "frame0",
			ops = {{op = "crop", grid = {1, 0}, cell = {0, 0}}},
		}

		local function resolve_tile(def, i)
			local expr = tile_expression(def, i)
			if not expr then
				return nil
			end
			local tile = def.tiles[i]
			local extra = nil
			if tile.animation and tile.animation.type == 1 then
				extra = FIRST_FRAME
			end
			return texmod.resolve(expr, texmod_ctx, extra)
		end

		-- The things in the world that are not nodes, by id
		local world_objects = {}
		-- The texture names the node definitions asked for, which is what
		-- decides whether arriving media is worth a new registry
		local node_textures = {}

		-- What has been said, newest last, and the line being typed
		local CHAT_LINES = 8
		local chat = {}
		local chat_input = nil
		-- The key that opens chat arrives as text as well, and the line edit
		-- would get it: the dialog goes up on the next frame instead, when
		-- that text has gone nowhere
		local chat_wanted = false
		-- Assigned below, next to the rest of the chat dialog; the frame
		-- update is what puts it up
		local open_chat

		-- The forms the server sends, and the one on screen
		local inventory_spec = nil
		local prepend = ""
		local detached = {}
		local form = nil
		local form_stale = false

		-- Pointing, digging and placing
		local item_defs = nil
		local inv = nil
		-- Which hotbar slot is wielded, one-based, as the number keys set it
		local wield_index = 1
		local pointed_under, pointed_above = nil, nil
		local dig = nil
		local digging = false

		local function rebuild_registry()
			registry_stale = false
			if not node_defs then
				return
			end
			local t0 = buildat.get_time_us()
			local cubes = view:set_node_definitions(node_defs, resolve_tile)
			add_line(cubes.." node types have their own textures"..
					" ("..store:have_count().." files, "..composed_count..
					" composed, "..
					math.floor((buildat.get_time_us() - t0) / 1000).." ms)")
		end

		-- The announcement and the definitions arrive in that order today, but
		-- the plan needs all three, so any of them arriving makes it
		local function plan_media()
			if not (node_defs and item_defs and announced) then
				return
			end
			local wanted = {}
			node_textures = wanted
			for _, def in pairs(node_defs) do
				for i = 1, 6 do
					local expr = tile_expression(def, i)
					if expr then
						texmod.sources(expr, wanted)
					end
				end
			end
			-- What an item looks like in an inventory is its own texture,
			-- and a form full of them is most of what a game's media is
			for _, def in pairs(item_defs) do
				if def.inventory_image ~= "" then
					texmod.sources(def.inventory_image, wanted)
				end
			end
			for _, name in ipairs(store:plan(announced, wanted)) do
				to_ask[#to_ask + 1] = name
			end
		end

		client.on_nodedef = function(data)
			local defs, count = nodedef.parse(luanti.serialize, data, log)
			node_defs = defs
			node_by_name = {}
			for _, def in pairs(defs) do
				node_by_name[def.name] = def
			end
			add_line(count.." node definitions")
			registry_stale = true
			plan_media()
		end

		client.on_announce_media = function(files)
			announced = files
			registry_stale = true
			plan_media()
		end

		client.on_media = function(files)
			store:store(files)
			-- Only a texture a node wanted is worth building the registry
			-- again for; an object's texture arriving is not, and objects
			-- turn up for as long as the client runs
			for _, file in ipairs(files) do
				if node_textures[file.name] then
					registry_stale = true
					break
				end
			end
			-- An object that was waiting for its texture can have it now
			for _, obj in pairs(world_objects) do
				obj.visual_stale = true
			end
		end

		-- The player's own box in the world. It asks the world what stops it;
		-- a node whose block has not arrived counts as solid, so the player
		-- stands still until the ground under them is there.
		local avatar = player.new(
				function(x, y, z) return view:is_solid(x, y, z) end,
				function(x, y, z) return view:is_liquid(x, y, z) end)
		client.on_movement = function(m)
			avatar.movement = m
			add_line("The game's movement constants arrived")
		end

		client.on_itemdef = function(data)
			local items, count = itemdef.parse(luanti.serialize, data, log)
			item_defs = items
			add_line(count.." item definitions")
			plan_media()
		end

		-- An object's texture is media like any other, but objects turn up
		-- long after the media was asked for, so what is missing is asked for
		-- when it is wanted and the object gets its texture when it arrives.
		local function object_texture(name)
			local resolved = texmod.resolve(name, texmod_ctx)
			if resolved then
				return resolved
			end
			local wanted = {}
			if texmod.sources(name, wanted) and announced then
				for _, missing in ipairs(store:plan(announced, wanted)) do
					to_ask[#to_ask + 1] = missing
				end
			end
			return nil
		end

		-- Declared before what uses it; the definition is further down, with
		-- the rest of what a form needs
		local item_image

		-- What an object is drawn wearing. A mob and a player have textures
		-- of their own; a dropped item has none and carries the item it is
		-- instead, and what that looks like is what it looks like in an
		-- inventory.
		local function object_resource(obj)
			local props = obj.props
			if not props then
				return nil
			end
			if props.textures and props.textures[1] and
					props.textures[1] ~= "" then
				return object_texture(props.textures[1])
			end
			if props.wield_item and props.wield_item ~= "" then
				local item = props.wield_item:match("^(%S+)")
				if item then
					return item_image(item)
				end
			end
			return nil
		end

		client.on_object_add = function(id, object_type, data)
			local ok, obj = pcall(objects.parse_init, luanti.serialize, data)
			if not ok then
				log:warning("objects: could not read object "..id..": "..
						tostring(obj))
				return
			end
			obj.id = id
			world_objects[id] = obj
			-- The local player is drawn by nobody: the camera is inside it
			if obj.is_player and obj.name == name then
				obj.is_self = true
				return
			end
			view:set_object(obj, object_resource)
		end

		client.on_object_remove = function(id)
			world_objects[id] = nil
			view:remove_object(id)
		end

		client.on_object_message = function(id, data)
			local obj = world_objects[id]
			if not obj then
				return
			end
			local r = luanti.serialize.reader(data)
			local ok, err = pcall(objects.apply_message, obj, r)
			if not ok then
				-- One message this does not understand is not worth losing
				-- the object over; the rest still arrive
				return
			end
			if obj.visual_stale and not obj.is_self then
				view:set_object(obj, object_resource)
			end
		end

		-- The game changes the sky whenever it likes -- entering a biome, a
		-- cave, the nether -- so only the first one is worth a line
		local said_sky = false

		client.on_sky = function(sky)
			view:set_sky(sky)
			if not said_sky then
				said_sky = true
				add_line("The sky is a \""..(sky.type or "?").."\" one")
			end
		end

		client.on_chat = function(text, sender)
			local line = formspec.strip_escapes(text)
			if sender ~= "" then
				line = "<"..formspec.strip_escapes(sender).."> "..line
			end
			chat[#chat + 1] = line
			while #chat > CHAT_LINES do
				table.remove(chat, 1)
			end
			chat_text.text = table.concat(chat, "\n")
		end

		client.on_inventory_formspec = function(spec)
			inventory_spec = spec
			if form and form.source == "inventory" then
				form_stale = true
			end
		end

		client.on_formspec_prepend = function(spec)
			prepend = spec
		end

		client.on_detached_inventory = function(name, data)
			detached[name] = data and inventory.parse(data, detached[name])
					or nil
			form_stale = true
		end

		client.on_inventory = function(data)
			local first = inv == nil
			inv = inventory.parse(data, inv)
			form_stale = true
			if first then
				local names = {}
				for name, list in pairs(inv) do
					names[#names + 1] = name.." "..list.size
				end
				table.sort(names)
				add_line("The inventory arrived: "..
						table.concat(names, ", "))
			end
		end

		-- The stack in the wielded slot, and the tool capabilities a dig
		-- goes by: the wielded item's own, the hand slot's when it has none,
		-- and the empty item's as the last resort. This game keeps a real
		-- item in the hand slot, so without it nothing could be dug.
		local function wielded()
			return inventory.slot(inv, "main", wield_index)
		end

		local function dig_capabilities()
			return (inventory.dig_capabilities(inv, wield_index, item_defs))
		end

		local function reach()
			local held = wielded()
			local def = held and item_defs and item_defs[held.name]
			if def and def.range and def.range > 0 then
				return def.range
			end
			local empty = item_defs and item_defs[""]
			if empty and empty.range and empty.range > 0 then
				return empty.range
			end
			return POINT_RANGE
		end

		local function node_def_at(p)
			local id = view:node_at(p[1], p[2], p[3])
			return id and node_defs and node_defs[id] or nil
		end

		-- The pointing ray, and what holding the dig button does to what it
		-- finds. Luanti's server wants a START_DIGGING at a node before a
		-- DIGGING_COMPLETED for it, and no sooner than the dig would have
		-- taken; the node then comes back as a REMOVENODE.
		local function update_dig(dtime)
			if form then
				-- A form has the mouse; nothing is pointed at behind it
				view:set_pointed(nil, nil)
				pointed_under, pointed_above = nil, nil
				if dig then
					client:interact(luanti.INTERACT_STOP_DIGGING,
							wield_index - 1)
					dig = nil
				end
				return
			end
			pointed_under, pointed_above = view:point_ray(reach())
			if not pointed_above then
				pointed_under = nil
			end
			view:set_pointed(pointed_under, pointed_above)

			if not digging or not pointed_under then
				if dig then
					client:interact(luanti.INTERACT_STOP_DIGGING,
							wield_index - 1)
					dig = nil
				end
				return
			end
			if not dig or dig.under[1] ~= pointed_under[1] or
					dig.under[2] ~= pointed_under[2] or
					dig.under[3] ~= pointed_under[3] then
				local def = node_def_at(pointed_under)
				dig = {
					under = pointed_under, above = pointed_above, elapsed = 0,
					-- nil when what the player is holding cannot dig this at
					-- all, and then nothing is ever completed: the server
					-- would refuse it as digging the undiggable
					time = def and itemdef.dig_time(def.groups,
							dig_capabilities()) or nil,
					name = def and def.name or "?",
				}
				client:interact(luanti.INTERACT_START_DIGGING,
						wield_index - 1, {under = dig.under,
						above = dig.above})
				return
			end
			if dig.done then
				return
			end
			dig.elapsed = dig.elapsed + dtime
			if dig.time and dig.elapsed >= dig.time then
				client:interact(luanti.INTERACT_DIGGING_COMPLETED,
						wield_index - 1, {under = dig.under,
						above = dig.above})
				dig.done = true
			end
		end

		--
		-- Formspecs: the windows the server describes
		--

		-- What an item looks like: its own inventory image, or, for an item
		-- that places a node, the top of that node. Both are texture
		-- expressions.
		function item_image(item_name)
			local def = item_defs and item_defs[item_name]
			if def and def.inventory_image and def.inventory_image ~= "" then
				return texmod.resolve(def.inventory_image, texmod_ctx)
			end
			local node = node_by_name[item_name]
			if node then
				local expr = tile_expression(node, 1)
				if expr then
					return texmod.resolve(expr, texmod_ctx)
				end
			end
			return nil
		end

		local ui = formspec_ui.new(magic, buildat, log, {
			texture = function(expr)
				return texmod.resolve(expr, texmod_ctx)
			end,
			item_image = item_image,
			-- Where a list[] element's slots come from. A form can name the
			-- player's own inventory, one the server has detached, or a
			-- node's -- and node metadata is not read yet, so a chest's own
			-- slots come out empty.
			inventory = function(location, list_name)
				local lists = nil
				if location == "current_player" or
						location:sub(1, 7) == "player:" then
					lists = inv
				else
					local name = location:match("^detached:(.*)$")
					lists = name and detached[name] or nil
				end
				return lists and lists[list_name] or nil
			end,
		})

		local held = nil

		-- The hotbar and the health bar, remade when what they show changes
		local hud = nil
		local hud_key = nil

		local function update_hud()
			local list = inv and inv.main or nil
			local key = tostring(wield_index).."/"..tostring(client.hp)
			-- What is in the slots, as a string, so that the bar is only
			-- built again when it would look different
			for i = 1, HOTBAR_SLOTS do
				local stack = list and list.items[i] or nil
				key = key.."|"..(stack and
						(stack.name.." "..stack.count) or "")
			end
			if key == hud_key then
				return
			end
			hud_key = key
			if hud then
				hud:Remove()
			end
			local ui_root = magic.ui.root
			hud = ui:hud(ui_root, list, HOTBAR_SLOTS, wield_index,
					client.hp, 20, ui_root.width, ui_root.height)
		end

		local function close_form()
			if not form then
				return
			end
			form.drawn.window:Remove()
			form = nil
			held = nil
			magic.input:SetMouseVisible(false)
		end

		local function draw_form()
			if form.drawn then
				form.drawn.window:Remove()
			end
			local spec = form.spec
			-- The prepend goes in front unless the form says not to
			if not spec:find("no_prepend%[") then
				spec = prepend..spec
			end
			local elements, size, real = formspec.parse(spec)
			-- Under the UI's own root rather than the element the status
			-- screen is in: a form is positioned in the coordinates a click
			-- arrives in, and those are the root's, while the element this
			-- extension was given is only as big as what is in it. close_form
			-- is what takes it away again.
			local ui_root = magic.ui.root
			local w = ui_root.width
			local h = ui_root.height
			local layout = formspec.layout(size, real, w, h)
			form.drawn = ui:show(ui_root, elements, layout, w, h)
			form_stale = false
		end

		-- source says which form this is, which decides whether a new
		-- inventory formspec replaces it
		local function open_form(spec, formname, source)
			close_form()
			if not spec or spec == "" then
				return
			end
			form = {spec = spec, formname = formname or "", source = source}
			draw_form()
			magic.input:SetMouseVisible(true)
		end

		client.on_show_formspec = function(spec, formname)
			if spec == "" then
				close_form()
				return
			end
			open_form(spec, formname, "server")
		end

		-- A click in a form: a slot picks a stack up and puts it down, and a
		-- button sends the form's fields back with the button's own name
		-- among them.
		local function form_click(x, y)
			if not form or not form.drawn then
				return
			end
			local lx = x - form.drawn.origin[1]
			local ly = y - form.drawn.origin[2]
			for _, b in ipairs(form.drawn.buttons) do
				if lx >= b.x and lx < b.x + b.w and
						ly >= b.y and ly < b.y + b.h then
					local fields = {[b.name] = ""}
					for _, f in ipairs(form.drawn.fields) do
						fields[f.name] = f.value
					end
					log:verbose("form: button \""..tostring(b.name)..
							"\" at "..lx..","..ly)
					client:send_inventory_fields(form.formname, fields)
					if b.exit then
						close_form()
					end
					return
				end
			end
			for _, slot in ipairs(form.drawn.slots) do
				if lx >= slot.x and lx < slot.x + slot.size and
						ly >= slot.y and ly < slot.y + slot.size then
					log:verbose("form: slot "..slot.list.." "..slot.index..
							" at "..lx..","..ly)
					if not held then
						if slot.stack then
							held = slot
						end
					else
						client:send_inventory_move(
								held.stack and held.stack.count or 1,
								held.location, held.list, held.index,
								slot.location, slot.list, slot.index)
						held = nil
					end
					return
				end
			end
		end

		-- Putting the wielded item where the ray came through the node it
		-- stopped at. What that means is the server's business: a node goes
		-- there, or the thing is used on what was pointed at, and either way
		-- what comes back is an ADDNODE or a formspec.
		local function place()
			if not pointed_under or not pointed_above then
				return
			end
			client:interact(luanti.INTERACT_PLACE, wield_index - 1,
					{under = pointed_under, above = pointed_above})
		end

		-- The bottom line is remade every frame; everything above it is the
		-- log of what happened
		local function set_counters()
			-- What is not handled yet is logged once per command by
			-- client.lua rather than shown here; it is a long line and the
			-- world is behind it
			local held = wielded()
			local holding = held and (held.name..
					(held.count > 1 and " x"..held.count or "")) or
					"nothing"
			local pointed = "pointing at nothing"
			if dig then
				pointed = (dig.done and "dug " or "digging ")..dig.name..
						(dig.time and string.format(" %.2f/%.2f",
						dig.elapsed, dig.time) or " (not by hand)")
			elseif pointed_under then
				local def = node_def_at(pointed_under)
				pointed = "pointing at "..(def and def.name or "?")
			end
			local condition = ""
			if client.hp then
				condition = string.format(" | %d hp", client.hp)
				if client.breath and client.breath < 10 then
					condition = condition..string.format(", %d breath",
							client.breath)
				end
			end
			status_text.text = table.concat(lines, "\n").."\n"..
					string.format(
					"%s%s | %.1f, %.1f, %.1f %s | %d: %s | %s"..
					" | %d objects | blocks: %d received,"..
					" %d in scene, %d to mesh | %d us to hand over"..
					" | media: %d files, %d to come",
					client.state, condition, avatar.x, avatar.y, avatar.z,
					avatar.fly and "flying" or
							(avatar.in_liquid and "swimming" or
							(avatar.on_ground and "on ground" or "falling")),
					wield_index, holding,
					pointed,
					view:object_count(),
					client.blocks_received, view:block_count(),
					view:dirty_count(), view.last_mesh_us,
					store:have_count(), store:missing_count())
		end

		-- Mouse look, so the cursor is out of the way and does not stop at the
		-- edge of the window
		magic.input:SetMouseVisible(false)

		local last_daylight = nil

		-- WASD on the horizontal plane whatever the camera is pitched at,
		-- space to jump, ctrl to sneak, shift for a faster pace, and K to
		-- toggle flying. What comes out is where the client tells the server
		-- it is, so the server sends the blocks around it: the position is
		-- both the camera's and the player's.
		--
		-- MOVE_PLAYER -- the server putting the player somewhere, at the spawn
		-- or after its movement checks -- has to win over what the player is
		-- doing. client.position is what we told the server last frame, so it
		-- differing from where the player thinks it is means the server moved
		-- us.
		local function move(dtime)
			-- A form or a chat line takes the mouse and the keys; the player
			-- stands still rather than walking blind behind it
			if form or chat_input then
				client:set_position(avatar.x, avatar.y, avatar.z)
				client:set_motion(0, 0, 0, 0)
				return
			end
			local dmouse = magic.input:GetMouseMove()
			-- Luanti's yaw grows counterclockwise seen from above, so the
			-- mouse going right, which turns the player right, takes it down
			local yaw = client.yaw - dmouse.x * MOUSE_SENSITIVITY
			-- Luanti's pitch is positive looking down, which is the way the
			-- mouse's own y goes
			local pitch = client.pitch + dmouse.y * MOUSE_SENSITIVITY
			if pitch > 89 then pitch = 89 end
			if pitch < -89 then pitch = -89 end

			local p = client.position
			if p.x ~= avatar.x or p.y ~= avatar.y or p.z ~= avatar.z then
				avatar:set_position(p.x, p.y, p.z)
			end

			-- Where forward is, in world coordinates, for that yaw
			local yr = math.rad(yaw)
			local fx, fz = -math.sin(yr), math.cos(yr)
			local wish = {x = 0, z = 0,
					jump = magic.input:GetKeyDown(KEY_SPACE),
					sneak = magic.input:GetKeyDown(KEY_CTRL),
					fast = magic.input:GetKeyDown(KEY_SHIFT)}
			local keys = 0
			if magic.input:GetKeyDown(KEY_W) then
				wish.x, wish.z = wish.x + fx, wish.z + fz
				keys = keys + luanti.KEY_UP
			end
			if magic.input:GetKeyDown(KEY_S) then
				wish.x, wish.z = wish.x - fx, wish.z - fz
				keys = keys + luanti.KEY_DOWN
			end
			if magic.input:GetKeyDown(KEY_D) then
				wish.x, wish.z = wish.x + fz, wish.z - fx
				keys = keys + luanti.KEY_RIGHT
			end
			if magic.input:GetKeyDown(KEY_A) then
				wish.x, wish.z = wish.x - fz, wish.z + fx
				keys = keys + luanti.KEY_LEFT
			end
			if wish.jump then keys = keys + luanti.KEY_JUMP end
			if wish.sneak then keys = keys + luanti.KEY_SNEAK end
			if wish.fast then keys = keys + luanti.KEY_AUX1 end

			local x, y, z = avatar:update(dtime, wish)
			client:set_position(x, y, z, pitch, yaw)
			client:set_motion(avatar.vx, avatar.vy, avatar.vz, keys)
			view:set_camera(x, y + player.EYE_HEIGHT, z, pitch, yaw)
		end

		-- A plain subscription rather than root:SubscribeToStackEvent(), which
		-- only fires while the UI element has focus; the world has to keep
		-- streaming whatever the UI is doing. Unsubscribed by hand below.
		local update_cb = magic.SubscribeToEvent("Update",
				function(event_type, event_data)
			local dtime = event_data:GetFloat("TimeStep")
			client:update(dtime)
			move(dtime)
			update_dig(dtime)
			objects.interpolate(world_objects, dtime)
			for _, obj in pairs(world_objects) do
				if obj.visual_stale and not obj.is_self then
					view:set_object(obj, object_resource)
				end
			end
			view:place_objects(world_objects)
			update_hud()
			if chat_wanted then
				chat_wanted = false
				open_chat()
			end
			if form and form_stale then
				draw_form()
			end
			if client.time_of_day then
				local daylight = daynight_ratio(client.time_of_day)
				-- The ramp is smooth and the zone is not free to set, so only
				-- a visible step is worth an update
				if not last_daylight or
						math.abs(daylight - last_daylight) > 0.01 then
					last_daylight = daylight
					view:set_daylight(daylight)
				end
			end
			-- Nothing is dropped until the server has said where the player
			-- is: until then the camera is at the origin and everything that
			-- has arrived looks far away, and a dropped block is one the
			-- server will not send again
			view:update(dtime, client.state == "ready" and DROP_DISTANCE or nil)

			-- Media requests go out a batch a frame, and the registry is
			-- rebuilt once what was asked for has arrived
			if #to_ask > 0 then
				local batch = {}
				for _ = 1, math.min(#to_ask, MEDIA_PER_REQUEST) do
					batch[#batch + 1] = table.remove(to_ask)
				end
				client:request_media(batch)
				media_asked_at = buildat.get_time_us()
			elseif registry_stale and node_defs then
				local waited = media_asked_at and
						(buildat.get_time_us() - media_asked_at) / 1000000 or 0
				if store:missing_count() == 0 or waited > MEDIA_WAIT_S then
					rebuild_registry()
				end
			end
			set_counters()
		end)

		-- The line the player types in: a dialog with a text field and the
		-- two buttons a player expects, because a bare line edit at the
		-- bottom of the screen is not something anyone can find.
		--
		-- The field is a LineEdit rather than something built here: editing a
		-- line -- the cursor, selection, backspace, paste -- is what Urho3D's
		-- own already does. Enter arrives as its TextFinished, because a
		-- stack event handler does not fire while it has the focus.
		local chat_window = nil
		local chat_input_cb = nil
		local chat_key_cb = nil
		local chat_buttons = nil

		local function close_chat()
			if not chat_input then
				return
			end
			if chat_input_cb then
				magic.UnsubscribeFromEvent(chat_input, "TextFinished",
						chat_input_cb)
				chat_input_cb = nil
			end
			if chat_key_cb then
				magic.UnsubscribeFromEvent("KeyDown", chat_key_cb)
				chat_key_cb = nil
			end
			chat_window:Remove()
			chat_window = nil
			chat_input = nil
			chat_buttons = nil
			if not form then
				magic.input:SetMouseVisible(false)
			end
		end

		local function send_chat()
			local text = chat_input:GetText()
			log:verbose("chat: sending \""..text.."\"")
			close_chat()
			if text ~= "" then
				client:send_chat(text)
			end
		end

		function open_chat()
			if chat_input then
				return
			end
			local ui_root = magic.ui.root
			local w = math.min(560, ui_root.width - 40)
			local h = 96
			local ox = math.floor((ui_root.width - w) / 2)
			-- Above the hotbar and the chat log, which are what is at the
			-- bottom of the screen
			local oy = ui_root.height - h - 180

			chat_window = ui_root:CreateChild("BorderImage")
			-- The style is inherited by everything under it, which is what
			-- the line edit's own text needs to have a font at all
			chat_window.defaultStyle = style
			chat_window.texture = magic.cache:GetResource("Texture2D",
					"luanti_client/res/white.png")
			chat_window.color = magic.Color(0.10, 0.10, 0.13, 0.95)
			chat_window.size = magic.IntVector2(w, h)
			chat_window:SetPosition(ox, oy)
			-- An element Urho3D has not been told is enabled is not hit by a
			-- click, and then no click event carries a position at all
			chat_window.enabled = true

			local caption = chat_window:CreateChild("Text")
			caption.defaultStyle = style
			caption:SetStyleAuto()
			caption.text = "Say something (a line starting with / is a"..
					" command)"
			caption:SetFontSize(12)
			caption:SetPosition(12, 10)
			caption.color = magic.Color(0.8, 0.8, 0.85)

			chat_input = chat_window:CreateChild("LineEdit")
			chat_input.defaultStyle = style
			chat_input:SetStyleAuto()
			chat_input:SetPosition(12, 30)
			-- size rather than fixedWidth/fixedHeight: the parent has no
			-- layout to size it, and the element stays 0x0
			chat_input.size = magic.IntVector2(w - 24, 26)
			chat_input.enabled = true
			-- A box of its own, so the field is visible before anything has
			-- been typed into it
			chat_input.texture = magic.cache:GetResource("Texture2D",
					"luanti_client/res/white.png")
			chat_input.color = magic.Color(0.02, 0.02, 0.03, 0.9)
			chat_input:SetText("")
			chat_input:SetFocus(true)

			-- The two buttons, as boxes with a word in them: what a click
			-- landed on is worked out from the rectangles, the same way a
			-- form's buttons are, rather than from Urho3D's own button
			-- events, which do not reach the sandbox with a position
			chat_buttons = {origin = {ox, oy}, items = {}}
			local bw, bh = 90, 26
			local by = h - bh - 10
			local labels = {{"Send", w - 12 - bw * 2 - 8, send_chat},
					{"Cancel", w - 12 - bw, close_chat}}
			for _, b in ipairs(labels) do
				local box = chat_window:CreateChild("BorderImage")
				box.texture = magic.cache:GetResource("Texture2D",
						"luanti_client/res/white.png")
				box.color = magic.Color(0.30, 0.30, 0.38, 0.95)
				box.size = magic.IntVector2(bw, bh)
				box:SetPosition(b[2], by)
				box.enabled = true
				local t = box:CreateChild("Text")
				t.defaultStyle = style
				t:SetStyleAuto()
				t.text = b[1]
				t:SetFontSize(13)
				t:SetAlignment(HA_CENTER, VA_CENTER)
				chat_buttons.items[#chat_buttons.items + 1] =
						{x = b[2], y = by, w = bw, h = bh, action = b[3]}
			end

			magic.input:SetMouseVisible(true)
			chat_input_cb = magic.SubscribeToEvent(chat_input, "TextFinished",
					send_chat)
			-- Escape cancels. A plain subscription, because the line edit has
			-- the focus and the stack's own handler is then quiet.
			chat_key_cb = magic.SubscribeToEvent("KeyDown",
					function(event_type, event_data)
				if event_data:GetInt("Key") == KEY_ESCAPE then
					close_chat()
				end
			end)
		end

		local function chat_click(x, y)
			if not chat_buttons then
				return
			end
			local lx = x - chat_buttons.origin[1]
			local ly = y - chat_buttons.origin[2]
			for _, b in ipairs(chat_buttons.items) do
				if lx >= b.x and lx < b.x + b.w and
						ly >= b.y and ly < b.y + b.h then
					b.action()
					return
				end
			end
		end

		-- The dig button. Urho3D's Input does not expose the button state to
		-- the sandbox, so the two events are what says whether it is held.
		local mouse_down_cb = magic.SubscribeToEvent("MouseButtonDown",
				function(event_type, event_data)
			if form then
				return -- The click goes to the form; see UIMouseClick
			end
			if event_data:GetInt("Button") == MOUSEB_LEFT then
				digging = true
			end
		end)

		-- Where a click landed, which MouseButtonDown does not say
		local ui_click_cb = magic.SubscribeToEvent("UIMouseClick",
				function(event_type, event_data)
			if event_data:GetInt("Button") ~= MOUSEB_LEFT then
				return
			end
			if form then
				form_click(event_data:GetInt("X"), event_data:GetInt("Y"))
			elseif chat_input then
				chat_click(event_data:GetInt("X"), event_data:GetInt("Y"))
			end
		end)
		local mouse_up_cb = magic.SubscribeToEvent("MouseButtonUp",
				function(event_type, event_data)
			if event_data:GetInt("Button") == MOUSEB_LEFT then
				digging = false
			end
			if event_data:GetInt("Button") == MOUSEB_RIGHT and not form then
				-- On the way up rather than the way down, so that holding
				-- the button does not place a stack of nodes at once
				place()
			end
		end)

		root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
			local key = event_data:GetInt("Key")
			if chat_input or chat_wanted then
				-- The dialog has the keys. Enter arrives as the line edit's
				-- TextFinished and escape as the plain subscription made in
				-- open_chat; a stack handler does not fire at all once the
				-- line edit has the focus.
				return
			end
			-- Luanti's own keys for these. A server that does not give the
			-- player the fly and noclip privileges pulls them back.
			if key == KEY_K then
				avatar.fly = not avatar.fly
				add_line(avatar.fly and "Flying" or "Walking")
			end
			-- T says something, which is Luanti's own key for it; a line
			-- starting with a slash is a command
			if key == KEY_T and not chat_input then
				chat_wanted = true
				return
			end
			if key == KEY_I then
				if form then
					close_form()
				else
					open_form(inventory_spec, "", "inventory")
				end
			end
			-- The number keys pick a hotbar slot, as they do in Luanti
			if key >= KEY_1 and key <= KEY_8 then
				wield_index = key - KEY_1 + 1
			end
			if key == KEY_H then
				avatar.noclip = not avatar.noclip
				add_line(avatar.noclip and "Through walls" or "Solid walls")
			end
			if key == KEY_ESCAPE and form then
				close_form()
			elseif key == KEY_ESCAPE then
				magic.UnsubscribeFromEvent("Update", update_cb)
				magic.UnsubscribeFromEvent("MouseButtonDown", mouse_down_cb)
				magic.UnsubscribeFromEvent("MouseButtonUp", mouse_up_cb)
				magic.UnsubscribeFromEvent("UIMouseClick", ui_click_cb)
				close_form()
				close_chat()
				chat_text:Remove()
				status_text:Remove()
				if hud then
					hud:Remove()
					hud = nil
				end
				magic.input:SetMouseVisible(true)
				client:disconnect()
				view:close()
				uistack.main:pop(root)
			end
		end)
	end)
end

local function show_connect_dialog()
	local root = uistack.main:push({desc="luanti_client connect"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "__menu/res/main_style.xml")

	local menu = ui_utils.vertical_menu(root, {min_width = 300})
	local window = menu.window

	local title = window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Connect to a Luanti server"

	local address_edit = labeled_edit(window, "Address", DEFAULT_ADDRESS)
	local name_edit = labeled_edit(window, "Player name", DEFAULT_NAME)
	local password_edit = labeled_edit(window, "Password", "")
	address_edit:SetFocus(true)

	local function connect()
		local host, port = split_address(address_edit:GetText())
		local name = name_edit:GetText()
		if name == "" then
			ui_utils.show_message_dialog("A player name is needed")
			return
		end
		uistack.main:pop(root)
		show_client(host, port, name, password_edit:GetText())
	end

	menu:add("Connect", connect)
	menu:add("Cancel", function()
		uistack.main:pop(root)
		engine:Exit()
	end)
end

function M.boot()
	srp.self_test()
	log:info("srp: self-test ok")
	engine_test.self_test()
	log:info("engine primitives: self-test ok")
	show_connect_dialog()
end

return M
-- vim: set noet ts=4 sw=4:
