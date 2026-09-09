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
local objmesh = dofile(path.."/objmesh.lua")
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
-- The textures Luanti's own client ships rather than receiving: a game names
-- them and nothing arrives for them. blank.png is the one that matters --
-- what a node whose shape is drawn by something else wears -- and the unknown
-- ones are what a client puts where it has nothing.
local BUILTIN_TEXTURES = {
	["blank.png"] = "luanti_client/res/blank.png",
	["unknown_node.png"] = "luanti_client/res/placeholder.png",
	["unknown_item.png"] = "luanti_client/res/placeholder.png",
	["unknown_object.png"] = "luanti_client/res/placeholder.png",
}

-- What time it is, whatever the server says: how the sky at dawn or at night
-- gets looked at without waiting for the world to turn, or asking a server for
-- the privilege of setting its clock. BUILDAT_LUANTI_FORCE_DAY, in
-- daynight_ratio() below, is the same kind of thing for the light.
local FORCE_TIME = tonumber(os.getenv("BUILDAT_LUANTI_FORCE_TIME") or "")

-- How far the day has to move before the sky is worked out again, in
-- Luanti's own units of 1/24000th of a day: a full turn of the sun is 360
-- degrees over 24000, so this is about half a degree.
local SKY_STEP = 30

local HOTBAR_SLOTS = 8

-- Media files are asked for in batches, so that one REQUEST_MEDIA does not
-- turn into hundreds of split chunks in one go
local MEDIA_PER_REQUEST = 200
-- The voxel registry is rebuilt when the media that was asked for has all
-- arrived, and after this long with nothing arriving whether it has or not: a
-- file the server never sends must not hold every other texture back forever
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
	-- An environment variable that is set but empty is a variable that is
	-- not set: a script that passes it through unconditionally passes an
	-- empty one, and "" is true in Lua
	local force = os.getenv("BUILDAT_LUANTI_FORCE_DAY")
	if force and force ~= "" then
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

-- Defined below; a session that ends before any of the game has arrived goes
-- back to it rather than closing the client
local show_connect_dialog

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

	-- Until the game's definitions and its media are in, the world is a field
	-- of placeholders and there is nothing worth showing: an opaque panel over
	-- all of it instead, saying how far along the loading is. A UI element is
	-- always in front of the world; the priority is what puts it behind the
	-- rest of the UI, because the lines in the corner are the detail of the
	-- same story. Removed when the loading is done, and by leave().
	local loading_panel = magic.ui.root:CreateChild("BorderImage")
	loading_panel.texture = magic.cache:GetResource(
			"Texture2D", "luanti_client/res/white.png")
	loading_panel.color = magic.Color(0.06, 0.07, 0.09)
	-- Behind the rest of the UI: a dialog -- the one that asks whether the
	-- network may be used, or the one that says why a session ended -- has to
	-- come out in front of this, and the lines in the corner are the detail
	-- of the same story. The hotbar is taken down while it is up instead.
	loading_panel.priority = -1000
	loading_panel.enabled = false
	-- The size it starts at, because the text inside is centred in it and a
	-- panel of no size centres that in the top left corner
	loading_panel.width = magic.ui.root.width
	loading_panel.height = magic.ui.root.height
	local loading_text = loading_panel:CreateChild("Text")
	loading_text.defaultStyle = style
	loading_text:SetStyleAuto()
	loading_text:SetAlignment(HA_CENTER, VA_CENTER)
	loading_text:SetTextAlignment(HA_CENTER)
	loading_text.text = "Connecting to "..host..":"..port

	-- The crosshair, which is what says where the middle of the screen is
	-- when the mouse is captured. Two bars rather than a texture: it is two
	-- rectangles either way and this way there is no image to ship.
	local function crosshair_bar(w, h)
		local bar = magic.ui.root:CreateChild("BorderImage")
		bar.texture = magic.cache:GetResource(
				"Texture2D", "luanti_client/res/white.png")
		bar.width = w
		bar.height = h
		bar:SetAlignment(HA_CENTER, VA_CENTER)
		bar:SetPosition(0, 0)
		bar.color = magic.Color(1, 1, 1, 0.7)
		bar.enabled = false
		return bar
	end
	local crosshair = {crosshair_bar(13, 1), crosshair_bar(1, 13)}

	-- What F1, F2 and F5 turn on and off, which are the keys Luanti uses for
	-- them: the player's own HUD and the crosshair, what has been said, and
	-- the lines of detail in the corner.
	local show_hud = true
	local show_chat = true
	local show_debug = true

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

		-- Assigned further down, where the media store it reads the model
		-- out of exists; world.new wants the function now, so what it gets
		-- is a wrapper around whatever this holds by then
		local read_mesh

		local view = world.new(magic, buildat.safe, log, {
				far_clip = FAR_CLIP,
				read_image = buildat.read_image,
				read_mesh = function(def)
					return read_mesh and read_mesh(def) or nil
				end,
		})

		-- Whether any of the game itself has arrived. A login that is refused
		-- is refused before the definitions come, and there is then nothing
		-- to go back to but the dialog the address was typed into; a session
		-- that ends after the game has arrived ends the client.
		local got_content = false

		-- Whether the definitions and the media are still coming in. Until
		-- they are in there is nothing worth drawing -- a world of
		-- placeholders is not the game -- so a panel covers it and says how
		-- far along it is, and the registry is free to spend the frame.
		local loading = true

		client.on_block = function(block)
			view:set_block(block)
		end

		client.on_node = function(x, y, z, param0, param1, param2)
			view:set_node(x, y, z, param0, param1, param2)
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
		-- When the media last got anywhere: a file asked for, or a bunch
		-- arriving. The fallback below is a quiet spell rather than a fixed
		-- time after asking, because a game's whole media is tens of
		-- megabytes and takes longer than that to arrive.
		local media_progress_us = nil
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
					-- A few names are the client's own in Luanti and no
					-- server sends them
					return BUILTIN_TEXTURES[name]
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
		local function tile_expression(def, i, override)
			local function layer(tile)
				if not tile or tile.name == "" then
					return nil
				end
				-- A tile with a colour of its own keeps it; the override is
				-- what the voxel's param2 picked out of a palette, which
				-- stands in for the definition's own colour
				local color = tile.color or override or def.color
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

		local function resolve_tile(def, i, override)
			local expr = tile_expression(def, i, override)
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

		-- Assigned further down, with the rest of the media handling; the
		-- palette below is one of the things that wants a texture asked for
		local media_texture

		-- A palette is an image a game indexes by param2 to say what colour a
		-- voxel is drawn in; Luanti stretches it to 256 entries by repeating
		-- each pixel, so a palette of n pixels is n distinct colours. What is
		-- kept here is the pixels, and the resolving of a name to an index is
		-- in world.lua where the voxel ids are.
		local palettes = {}

		local function palette_colors(name)
			if palettes[name] ~= nil then
				return palettes[name] or nil
			end
			local resource = media_texture(name)
			if not resource then
				return nil -- Not arrived yet; the registry is built again
			end
			local ok, w, h, rgba = pcall(buildat.read_image, resource)
			if not ok or w * h < 1 then
				log:warning("palette "..name.." could not be read")
				palettes[name] = false
				return nil
			end
			local colors = {}
			for i = 0, math.min(w * h, 256) - 1 do
				local r, g, b = rgba:byte(i * 4 + 1, i * 4 + 3)
				colors[#colors + 1] = {r, g, b}
			end
			palettes[name] = colors
			return colors
		end

		-- The model a "mesh" drawtype names, as the quads a voxel's shape is
		-- made of: the mesh's name and the scale it was asked for -> quads,
		-- or false for one that could not be read. Read once each; a game
		-- has a few dozen of them, two hundred definitions share them, and
		-- every voxel that faces a different way asks for the same one.
		-- The scale is part of the key because two definitions can draw one
		-- model at different sizes.
		local meshes = {}
		local meshes_read = 0

		read_mesh = function(def)
			local name = def.mesh
			if name == nil or name == "" or not store:have_file(name) then
				return nil
			end
			local scale = def.visual_scale ~= 0 and def.visual_scale or 1
			local key = name.."@"..tostring(scale)
			local quads = meshes[key]
			if quads == nil then
				-- Only .obj: .b3d is binary and animated, and what a node
				-- wants of it is its static geometry
				if not name:lower():match("%.obj$") then
					meshes[key] = false
					return nil
				end
				local file = io.open(MEDIA_ROOT.."/"..server_key.."/"..
						name, "rb")
				if not file then
					meshes[key] = false
					return nil
				end
				local text = file:read("*all")
				file:close()
				local parsed, _, skipped = objmesh.parse(text)
				if #parsed == 0 then
					log:warning("mesh "..name.." has no faces this reads")
					meshes[key] = false
					return nil
				end
				if skipped > 0 then
					log:info("mesh "..name..": "..skipped..
							" faces are neither triangles nor quads")
				end
				-- A material of the mesh wears the tile of the same number,
				-- which is how Luanti puts a node's tiles on one
				for _, q in ipairs(parsed) do
					q.tile = math.min(q.group, 6)
				end
				quads = objmesh.scale(parsed, scale)
				meshes[key] = quads
				meshes_read = meshes_read + 1
			end
			return quads or nil
		end

		-- The things in the world that are not nodes, by id
		local world_objects = {}

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

		-- Building the registry is two and a half thousand definitions with a
		-- texture expression each, and it happens while the world is already
		-- on screen: a slice a frame rather than one frame of a second and a
		-- half. registry_step is nil when nothing is being built.
		local REGISTRY_BUDGET_US = 4000
		-- Behind the loading panel there is nothing to keep smooth, and the
		-- budget is what decides how long the wait is: on a big game's
		-- definitions 4 ms a frame turned two seconds of work into fifteen
		-- of waiting
		local REGISTRY_LOADING_BUDGET_US = 50000
		local registry_step = nil
		local registry_started_us = nil
		local registry_spent_us = 0

		local function rebuild_registry()
			registry_stale = false
			if not node_defs then
				return
			end
			registry_step = view:begin_node_definitions(node_defs,
					resolve_tile, palette_colors)
			registry_started_us = buildat.get_time_us()
			registry_spent_us = 0
		end

		-- One slice, and the line when it is done
		local function step_registry()
			local t0 = buildat.get_time_us()
			local done, cubes = registry_step(loading and
					REGISTRY_LOADING_BUDGET_US or REGISTRY_BUDGET_US)
			registry_spent_us = registry_spent_us +
					(buildat.get_time_us() - t0)
			if not done then
				return
			end
			registry_step = nil
			local line = cubes.." voxel types have their own textures"..
					" ("..store:have_count().." files, "..composed_count..
					" composed, "..meshes_read.." meshes, "..
					math.floor(registry_spent_us / 1000).." ms over "..
					math.floor((buildat.get_time_us() - registry_started_us) /
					1000).." ms)"
			add_line(line)
			-- In the log as well as on the screen: this is the last thing
			-- before the world is there, which is what anything driving the
			-- client waits for
			log:info(line)
			if loading then
				loading = false
				if loading_panel then
					loading_panel:Remove()
					loading_panel = nil
				end
				-- A node whose texture expression cannot be built stays a
				-- placeholder, and this is the only thing that says why
				for mod_name, expr in pairs(texmod.unimplemented) do
					log:warning("texture modifier ["..mod_name..
							" is not implemented, as in "..expr)
				end
			end
		end

		-- The atlas textures the world is drawn with are filled in by hand
		-- rather than loaded from a file, and Urho3D can only bring back
		-- what it loaded: a change of screen mode takes the GL context with
		-- it and the world comes back black. Building the registry again is
		-- what fills them.
		local screen_mode_cb = magic.SubscribeToEvent("ScreenMode",
				function()
					registry_stale = true
				end)

		client.on_nodedef = function(data)
			got_content = true
			local defs, count = nodedef.parse(luanti.serialize, data, log)
			node_defs = defs
			node_by_name = {}
			for _, def in pairs(defs) do
				node_by_name[def.name] = def
			end
			add_line(count.." node definitions")
			registry_stale = true
			-- Starts the fallback clock: a server that never announces its
			-- media must not leave the loading panel up forever
			media_progress_us = media_progress_us or buildat.get_time_us()
		end

		-- Everything the server has that the cache does not, asked for at
		-- once: see media.lua. Working out which files a game's definitions
		-- actually reach means walking every texture expression, and a file
		-- found after the voxel registry was built costs another build of it.
		client.on_announce_media = function(files)
			announced = files
			for _, name in ipairs(store:plan(files)) do
				to_ask[#to_ask + 1] = name
			end
			registry_stale = true
		end

		client.on_media = function(files)
			store:store(files)
			media_progress_us = buildat.get_time_us()
			-- Everything announced was asked for before the registry was
			-- built the first time, so a file arriving after that is one the
			-- announcement did not cover -- a media push, or a name a form or
			-- an object asked for -- and the voxels may want it too
			if not loading then
				registry_stale = true
			end
			-- An object that was waiting for its texture can have it now
			for _, obj in pairs(world_objects) do
				obj.visual_stale = true
			end
			-- And so can a form: its textures are asked for when it is drawn
			form_stale = true
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
			got_content = true
			local items, count = itemdef.parse(luanti.serialize, data, log,
					client.protocol_version)
			item_defs = items
			add_line(count.." item definitions")
		end

		-- A texture that is not part of a voxel definition: an object's, or
		-- one a formspec names. The media for those is not planned up front,
		-- because what wants them turns up long after the media was asked
		-- for, so what is missing is asked for when it is wanted and whatever
		-- was waiting gets it when it arrives.
		function media_texture(name)
			local resolved = texmod.resolve(name, texmod_ctx)
			if resolved then
				return resolved
			end
			local wanted = {}
			if texmod.sources(name, wanted) and announced then
				for _, missing in ipairs(store:plan(announced, wanted)) do
					to_ask[#to_ask + 1] = missing
				end
				-- Planning counts a file that is already in the cache as had,
				-- and then nothing will arrive to ask for a second look: what
				-- was on disk resolves now or not at all
				return texmod.resolve(name, texmod_ctx)
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
				return media_texture(props.textures[1])
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
				-- The spec itself, not only what is in the slots: this is how
				-- a game changes the page of its own inventory
				form.spec = spec
				form_stale = true
			end
		end

		client.on_formspec_prepend = function(spec)
			prepend = spec
		end

		-- A chest somebody put something in: the form showing it is redrawn
		-- with what it holds now
		client.on_node_meta = function(entries)
			view:set_node_meta(entries)
			if form then
				form_stale = true
			end
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
		-- The items nothing could be made of, named once each: what is
		-- drawn for them is a marked square, and this is what says why
		local imageless = {}

		-- Which drawtypes are a cube, and so are drawn as the little cube an
		-- inventory shows a voxel as. A nodebox, a plant or a mesh is not:
		-- what those look like is their own shape, and their flat tile is a
		-- better lie than a cube would be. NDT_MESH is left out for the same
		-- reason even though the world draws it as its box.
		local CUBE_ITEM_DRAWTYPES = {
			[0] = true,  -- NDT_NORMAL
			[2] = true,  -- NDT_LIQUID
			[3] = true,  -- NDT_FLOWINGLIQUID
			[4] = true,  -- NDT_GLASSLIKE
			[5] = true,  -- NDT_ALLFACES
			[6] = true,  -- NDT_ALLFACES_OPTIONAL
			[13] = true, -- NDT_GLASSLIKE_FRAMED
			[15] = true, -- NDT_GLASSLIKE_FRAMED_OPTIONAL
		}

		-- How big the cube is drawn. It is scaled to the slot afterwards, so
		-- this only decides how much of the texture's detail survives. Nine
		-- times a unit, because that is what Luanti's own geometry is in;
		-- with a unit of eight a face's edge comes out 32 pixels.
		local CUBE_UNIT = 8
		local CUBE_SIZE = 9 * CUBE_UNIT

		-- A voxel as the cube Luanti draws in an inventory: the top face and
		-- the two the viewer would see, each a parallelogram, the sides
		-- darkened so that the three read as three faces.
		--
		-- Luanti renders the node with a camera; three sheared tiles is the
		-- picture that comes out of that, without a render target.
		local function inventory_cube(def)
			if not CUBE_ITEM_DRAWTYPES[def.drawtype] then
				return nil
			end
			-- Luanti's own geometry, from createInventoryCubeImage() in
			-- src/client/imagesource.cpp: on a canvas of nine units the cube
			-- is eight wide and nine tall, a face's horizontal edge runs
			-- four across and two down, and a side face's vertical edge runs
			-- five down. Being taller than it is wide is the point -- a cube
			-- that fills a square canvas reads as squashed.
			local k = CUBE_UNIT
			-- Tiles are +Y, -Y, +X, -X, +Z, -Z: the top and the two faces
			-- that point at a viewer standing off the +X +Z corner
			--
			-- A side is darkened by asking for the tile with a [multiply on
			-- it rather than by darkening the canvas: the expression
			-- language already does that, and a multiply over the canvas
			-- would darken the faces already drawn as well.
			-- The shades are Luanti's too: 214/256 and 171/256 of the top's
			-- own brightness, which as a [multiply is #d5d5d5 and #aaaaaa
			local faces = {
				{tile = 1, at = {4.5 * k, 0},
						u = {4 * k, 2 * k}, v = {-4 * k, 2 * k}},
				{tile = 5, at = {0.5 * k, 2 * k},
						u = {4 * k, 2 * k}, v = {0, 5 * k},
						shade = "#d5d5d5"},
				{tile = 3, at = {4.5 * k, 4 * k},
						u = {4 * k, -2 * k}, v = {0, 5 * k},
						shade = "#aaaaaa"},
			}
			local ops = {}
			local key = "\0cube"
			for _, face in ipairs(faces) do
				local expr = tile_expression(def, face.tile)
				if not expr then
					return nil
				end
				if face.shade then
					expr = expr.."^[multiply:"..face.shade
				end
				local resource = texmod.resolve(expr, texmod_ctx)
				if not resource then
					return nil
				end
				key = key.."\0"..expr
				ops[#ops + 1] = {op = "shear", src = resource,
						at = face.at, u = face.u, v = face.v}
			end
			return texmod_ctx.compose(def.name..key, ops,
					{CUBE_SIZE, CUBE_SIZE})
		end

		function item_image(item_name)
			-- The name an alias means, so that what is looked for below is
			-- the item itself
			local def = item_defs and item_defs[item_name]
			item_name = (def and def.name) or item_name
			if def and def.inventory_image and def.inventory_image ~= "" then
				return texmod.resolve(def.inventory_image, texmod_ctx)
			end
			local node = node_by_name[item_name]
			if node then
				-- A voxel with no inventory image of its own is the little
				-- cube, when it is a cube at all
				local cube = inventory_cube(node)
				if cube then
					return cube
				end
				local expr = tile_expression(node, 1)
				if expr then
					local resource = texmod.resolve(expr, texmod_ctx)
					if resource then
						return resource
					end
					if not imageless[item_name] then
						imageless[item_name] = true
						log:info("item: no image for \""..item_name..
								"\", whose tile is \""..expr.."\"")
					end
					return nil
				end
			end
			if not imageless[item_name] then
				imageless[item_name] = true
				log:info("item: no image for \""..item_name.."\": "..
						(def and def.inventory_image ~= "" and
						"inventory_image \""..def.inventory_image.."\"" or
						(node and "a node with no tile" or
						"no definition and no node")))
			end
			return nil
		end

		local ui = formspec_ui.new(magic, buildat, log, {
			texture = media_texture,
			item_image = item_image,
			style = style,
			-- Where a list[] element's slots come from: the player's own
			-- inventory, one the server has detached, or the one that hangs
			-- off a voxel, which is what a chest's slots are.
			inventory = function(location, list_name)
				local lists = nil
				if location == "current_player" or
						location:sub(1, 7) == "player:" then
					lists = inv
				else
					local x, y, z = location:match(
							"^nodemeta:(-?%d+),(-?%d+),(-?%d+)$")
					if x then
						local meta = view:node_meta(tonumber(x),
								tonumber(y), tonumber(z))
						lists = meta and meta.lists or nil
					else
						local name = location:match("^detached:(.*)$")
						lists = name and detached[name] or nil
					end
				end
				return lists and lists[list_name] or nil
			end,
		})

		local held = nil

		-- The hotbar and the health bar, remade when what they show changes
		local hud = nil
		local hud_key = nil

		local function update_hud()
			-- Nothing of the player's own while the loading panel is up: the
			-- panel is behind the rest of the UI, so a hotbar would float on
			-- top of it. F1 takes it away as well, crosshair and all, which
			-- is what that key is for.
			for _, bar in ipairs(crosshair) do
				bar.visible = show_hud and not loading
			end
			if loading or not show_hud then
				if hud then
					hud:Remove()
					hud = nil
					hud_key = nil
				end
				return
			end
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

		-- The escape handler a form with fields in it needs, kept so that a
		-- redraw or a close takes it away again.
		--
		-- simplified: what a field itself is subscribed to is not taken
		-- away. Unsubscribing from an object's event is not something the
		-- sandbox offers -- UnsubscribeFromEvent takes an event type and a
		-- callback, not an object -- and Urho3D drops the subscription when
		-- the line edit is removed anyway, so what is left behind is the
		-- name of a callback that can no longer fire.
		local form_key_cb = nil

		local function clear_field_hooks()
			if form_key_cb then
				magic.UnsubscribeFromEvent("KeyDown", form_key_cb)
				form_key_cb = nil
			end
		end

		local function close_form()
			if not form then
				return
			end
			clear_field_hooks()
			form.drawn.window:Remove()
			form = nil
			held = nil
			magic.input:SetMouseVisible(false)
		end

		-- The fields a form has, as they are now: what was typed into a
		-- field rather than what the server put in it
		local function form_fields()
			local out = {}
			for _, f in ipairs(form.drawn.fields) do
				out[f.name] = f.edit and f.edit:GetText() or f.value
			end
			return out
		end

		-- Pressing enter in a field sends the form the way a button does,
		-- with which field it was as one of the fields; Luanti's own client
		-- calls them key_enter and key_enter_field.
		local function field_entered(name)
			local fields = form_fields()
			fields.key_enter = "true"
			fields.key_enter_field = name
			log:verbose("form: enter in \""..tostring(name).."\"")
			client:send_inventory_fields(form.formname, fields)
			if form.drawn.close_on_enter[name] ~= false then
				close_form()
			end
		end

		local function draw_form()
			if form.drawn then
				clear_field_hooks()
				form.drawn.window:Remove()
			end
			local spec = form.spec
			-- The prepend goes in front unless the form says not to
			if not spec:find("no_prepend%[") then
				spec = prepend..spec
			end
			log:verbose("FORMSPEC "..spec)
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
			form.drawn = ui:show(ui_root, elements, layout, w, h, form.state)
			local typeable = false
			for _, f in ipairs(form.drawn.fields) do
				if f.edit then
					typeable = true
					local name = f.name
					magic.SubscribeToEvent(f.edit, "TextFinished",
							function()
								field_entered(name)
							end)
				end
			end
			if typeable then
				-- A line edit with the focus swallows the keys, and the
				-- handler that would otherwise close the form on escape is a
				-- stack one, which then never fires
				form_key_cb = magic.SubscribeToEvent("KeyDown",
						function(event_type, event_data)
							if event_data:GetInt("Key") == KEY_ESCAPE then
								close_form()
							end
						end)
			end
			form_stale = false
		end

		-- source says which form this is, which decides whether a new
		-- inventory formspec replaces it
		local function open_form(spec, formname, source)
			close_form()
			if not spec or spec == "" then
				return
			end
			form = {spec = spec, formname = formname or "", source = source,
					state = {scroll = {}}}
			held = nil
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

		-- Where the cursor is, for the tooltips a form asks for and for the
		-- stack in hand: the UI does not say where it is and Input only
		-- gives the movement since the last frame, so it is tracked from
		-- MouseMove below. Declared here because everything that reads it is
		-- below this point.
		local mouse_at = nil

		-- The stack in hand, drawn under the cursor: a stack on its way from
		-- one slot to another has to be visible on the way. Under the UI's
		-- own root and over everything, and never in the way of a click.
		local held_element = nil
		local held_key = nil
		local held_size = 32

		local function update_held_image()
			local key = nil
			if held and mouse_at and form and form.drawn then
				key = held.name.." "..held.count
			end
			if not key then
				if held_element then
					held_element:Remove()
					held_element = nil
					held_key = nil
				end
				return
			end
			if key ~= held_key then
				held_key = key
				if held_element then
					held_element:Remove()
				end
				local size = math.floor((form.drawn.slots[1] and
						form.drawn.slots[1].size) or 32)
				held_size = size
				held_element = magic.ui.root:CreateChild("BorderImage")
				held_element.defaultStyle = style
				held_element.priority = 30000
				held_element.enabled = false
				held_element.size = magic.IntVector2(size, size)
				local resource = item_image(held.name)
				if resource then
					held_element.texture = magic.cache:GetResource(
							"Texture2D", resource)
				else
					held_element.texture = magic.cache:GetResource(
							"Texture2D", "luanti_client/res/white.png")
					held_element.color = magic.Color(0.8, 0.4, 0.8, 0.8)
				end
				if held.count > 1 then
					local t = held_element:CreateChild("Text")
					t:SetStyleAuto()
					t:SetPosition(0, math.floor(size * 0.5))
					t.text = tostring(held.count)
					t:SetFontSize(math.max(8, math.floor(size * 0.32)))
				end
			end
			-- Centred on the cursor, the way Luanti carries it
			held_element:SetPosition(mouse_at[1] - math.floor(held_size / 2),
					mouse_at[2] - math.floor(held_size / 2))
		end

		-- Which of a form's slots is at a point in the form's own
		-- coordinates, or nil
		local function slot_at(lx, ly)
			if not form or not form.drawn then
				return nil
			end
			for _, slot in ipairs(form.drawn.slots) do
				if lx >= slot.x and lx < slot.x + slot.size and
						ly >= slot.y and ly < slot.y + slot.size then
					return slot
				end
			end
			return nil
		end

		-- Taking a stack out of a slot and putting it into one. Luanti's own
		-- inventory takes and puts a whole stack with the left button, half
		-- of it or a single item with the right, and ten with the middle.
		local function take_from(slot, button)
			if not slot.stack then
				return
			end
			local have = slot.stack.count
			local take = have
			if button == MOUSEB_RIGHT then
				take = math.ceil(have / 2)
			elseif button == MOUSEB_MIDDLE then
				take = math.min(10, have)
			end
			held = {location = slot.location, list = slot.list,
					index = slot.index, count = take,
					name = slot.stack.name}
			-- The slot the stack came from is marked as well as the stack
			-- being drawn under the cursor: which slot it is on its way out
			-- of is worth seeing
			form.state.held = held
			form_stale = true
		end

		local function put_into(slot, button)
			local move = held.count
			if button == MOUSEB_RIGHT then
				move = 1
			elseif button == MOUSEB_MIDDLE then
				move = math.min(10, held.count)
			end
			client:send_inventory_move(move,
					held.location, held.list, held.index,
					slot.location, slot.list, slot.index)
			held.count = held.count - move
			if held.count <= 0 then
				held = nil
			end
			form.state.held = held
			form_stale = true
		end

		-- A click in a form: a slot picks a stack up and puts it down, and a
		-- button sends the form's fields back with the button's own name
		-- among them.
		-- button is which mouse button it was: Luanti's own inventory takes
		-- and puts a whole stack with the left one, half of it or a single
		-- item with the right, and ten with the middle.
		local function form_click(x, y, button)
			if not form or not form.drawn then
				return
			end
			local lx = x - form.drawn.origin[1]
			local ly = y - form.drawn.origin[2]
			for _, b in ipairs(form.drawn.buttons) do
				if lx >= b.x and lx < b.x + b.w and
						ly >= b.y and ly < b.y + b.h then
					local fields = form_fields()
					fields[b.name] = ""
					log:verbose("form: button \""..tostring(b.name)..
							"\" at "..lx..","..ly)
					client:send_inventory_fields(form.formname, fields)
					if b.exit then
						close_form()
					end
					return
				end
			end
			-- A tab or a checkbox: the form goes back with the new value in
			-- it, the way Luanti's own client sends one
			for _, t in ipairs(form.drawn.taps) do
				if lx >= t.x and lx < t.x + t.w and
						ly >= t.y and ly < t.y + t.h then
					local fields = form_fields()
					fields[t.name] = t.value
					if t.check then
						form.state.check[t.name] = t.value == "true"
						form_stale = true
					end
					log:verbose("form: \""..tostring(t.name).."\" = "..
							t.value)
					client:send_inventory_fields(form.formname, fields)
					return
				end
			end
			-- A row of a table: the server hears about it as CHG and the
			-- row's number, which is what its own client sends
			for _, t in ipairs(form.drawn.tables) do
				if lx >= t.x and lx < t.x + t.w and
						ly >= t.y and ly < t.y + t.h then
					for _, r in ipairs(t.rows) do
						if ly >= r.y and ly < r.y + t.row_h then
							-- A row with children opens and closes, which
							-- is the client's own business; the server
							-- hears about the row either way
							if r.opens then
								local open = form.state.open[t.name]
								open[r.index] = not open[r.index]
								form_stale = true
							end
							local fields = form_fields()
							fields[t.name] = "CHG:"..r.index
							log:verbose("form: table \""..tostring(t.name)..
									"\" row "..r.index)
							client:send_inventory_fields(form.formname,
									fields)
							return
						end
					end
					return
				end
			end
			local slot = slot_at(lx, ly)
			if slot then
				log:verbose("form: slot "..slot.list.." "..slot.index..
						" at "..lx..","..ly)
				if held then
					put_into(slot, button)
				else
					take_from(slot, button)
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
			-- Two lines rather than one: one line of this does not fit on a
			-- screen and what runs off the edge is the half that changes
			status_text.text = table.concat(lines, "\n").."\n"..
					string.format(
					"%s%s | %.1f, %.1f, %.1f %s"..
					" | looking %.0f down, %.0f round"..
					" | %d: %s | %s\n"..
					"%d objects | blocks: %d received,"..
					" %d in scene, %d to mesh | %d us to hand over"..
					" | %d commands waiting"..
					" | %d param2 pairs | media: %d files, %d to come",
					client.state, condition, avatar.x, avatar.y, avatar.z,
					avatar.fly and "flying" or
							(avatar.in_liquid and "swimming" or
							(avatar.on_ground and "on ground" or "falling")),
					client.pitch or 0, client.yaw or 0,
					wield_index, holding,
					pointed,
					view:object_count(),
					client.blocks_received, view:block_count(),
					view:dirty_count(), view.last_mesh_us,
					client.commands_waiting,
					view:pair_voxel_count(),
					store:have_count(), store:missing_count())
		end

		-- Mouse look, so the cursor is out of the way and does not stop at the
		-- edge of the window
		magic.input:SetMouseVisible(false)

		local last_daylight = nil
		local last_time_of_day = 0

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

		-- Set once the session is over -- the server said no, the connection
		-- went away, or escape was pressed -- and everything this session put
		-- on the screen has been taken back. leave() is what does that; it is
		-- defined further down, where all of it is in scope.
		local left = false
		local leave

		-- What the cursor is over and for how long: a tooltip that came up
		-- the instant the cursor crossed something would be in the way of
		-- everything. Luanti waits about this long too.
		local TOOLTIP_DELAY = 0.35
		local tooltip_over = nil
		local tooltip_wait = 0

		-- What Luanti's own client shows over an inventory slot: the item's
		-- description, and the name it is known by under it.
		--
		--     Calcite
		--     [mcl_amethyst:calcite]
		local function slot_tooltip(slot)
			local stack = slot.stack
			if not stack or stack.name == "" then
				return nil
			end
			local def = item_defs and item_defs[stack.name] or nil
			local desc = formspec.strip_escapes(
					(def and def.description) or "")
			-- Only the first line: a game writes a whole paragraph into a
			-- description -- what the thing does, what it is worth -- and
			-- Luanti's own tooltip is the name of the item
			desc = desc:match("^[^\n]*") or ""
			if desc == "" then
				desc = stack.name
			end
			return desc.."\n["..stack.name.."]"
		end

		local function update_tooltip(dtime)
			local drawn = form and form.drawn
			if not drawn or not mouse_at then
				if tooltip_over then
					tooltip_over = nil
					ui:tooltip(magic.ui.root, nil)
				end
				return
			end
			local lx = mouse_at[1] - drawn.origin[1]
			local ly = mouse_at[2] - drawn.origin[2]
			-- The last one that covers the cursor: a form's later elements
			-- are the ones on top. The text is worked out here rather than
			-- read off what was hit, because a slot's is its item's.
			local over, over_text = nil, nil
			for _, t in ipairs(drawn.tooltips or {}) do
				if lx >= t.x and lx < t.x + t.w and
						ly >= t.y and ly < t.y + t.h then
					over, over_text = t, t.text
				end
			end
			-- A slot is the most specific thing under the cursor, so it wins
			-- over an area the form asked for
			for _, slot in ipairs(drawn.slots or {}) do
				if lx >= slot.x and lx < slot.x + slot.size and
						ly >= slot.y and ly < slot.y + slot.size then
					local text = slot_tooltip(slot)
					if text then
						over, over_text = slot, text
					end
				end
			end
			if over ~= tooltip_over then
				tooltip_over = over
				tooltip_wait = 0
				ui:tooltip(magic.ui.root, nil)
				return
			end
			if not over then
				return
			end
			tooltip_wait = tooltip_wait + dtime
			if tooltip_wait >= TOOLTIP_DELAY then
				ui:tooltip(magic.ui.root, over_text, mouse_at[1],
						mouse_at[2], magic.ui.root.width,
						magic.ui.root.height)
			end
		end

		-- A plain subscription rather than root:SubscribeToStackEvent(), which
		-- only fires while the UI element has focus; the world has to keep
		-- streaming whatever the UI is doing. Unsubscribed by leave().
		local update_cb = magic.SubscribeToEvent("Update",
				function(event_type, event_data)
			local dtime = event_data:GetFloat("TimeStep")
			client:update(dtime)
			-- The client may have found out during that update that the
			-- session is over, and leave() has then taken the screen apart:
			-- what is below here would put some of it back
			if left then
				return
			end
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
			update_tooltip(dtime)
			update_held_image()
			local time_of_day = FORCE_TIME or client.time_of_day
			if time_of_day then
				local daylight = daynight_ratio(time_of_day)
				-- The ramp is smooth and the zone is not free to set, so
				-- only a visible step is worth an update. The time itself
				-- matters as well as the light it comes to: it is where the
				-- sun is in the sky.
				if not last_daylight or
						math.abs(daylight - last_daylight) > 0.01 or
						math.abs(time_of_day - last_time_of_day) >
								SKY_STEP then
					last_daylight = daylight
					last_time_of_day = time_of_day
					view:set_daylight(daylight, time_of_day)
				end
			end
			-- Nothing is dropped until the server has said where the player
			-- is: until then the camera is at the origin and everything that
			-- has arrived looks far away, and a dropped block is one the
			-- server will not send again
			view:update(dtime, client.state == "ready" and DROP_DISTANCE or nil)

			-- Media requests go out a batch a frame, and the registry is
			-- rebuilt once what was asked for has arrived
			if registry_step then
				step_registry()
			elseif #to_ask > 0 then
				local batch = {}
				for _ = 1, math.min(#to_ask, MEDIA_PER_REQUEST) do
					batch[#batch + 1] = table.remove(to_ask)
				end
				client:request_media(batch)
				media_progress_us = buildat.get_time_us()
			elseif registry_stale and node_defs then
				local waited = media_progress_us and
						(buildat.get_time_us() - media_progress_us) /
						1000000 or 0
				-- The announcement is waited for as well as the files it
				-- names: the definitions can arrive first, and a registry
				-- built before the media is a registry of placeholders that
				-- has to be built all over again
				local settled = store:missing_count() == 0 and
						(announced ~= nil or not loading)
				if settled or waited > MEDIA_WAIT_S then
					rebuild_registry()
				end
			end
			if loading and loading_panel then
				local what = "waiting for the game's definitions"
				if registry_step then
					what = "building the voxel types"
				elseif announced then
					what = "media: "..store:have_count().." of "..
							#announced.." files, "..
							(#to_ask + store:missing_count()).." to come"
				end
				loading_text.text = "Loading "..host..":"..port.."\n\n"..what
				-- The root's size, every frame, because the window can be
				-- resized while this is up
				loading_panel.width = magic.ui.root.width
				loading_panel.height = magic.ui.root.height
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

		local mouse_move_cb = magic.SubscribeToEvent("MouseMove",
				function(event_type, event_data)
					-- Input reports window pixels; a form is laid out in
					-- the UI's own coordinates, which are those divided by
					-- the UI scale -- the same ones a click arrives in
					local scale = magic.ui:GetScale()
					if not scale or scale <= 0 then
						scale = 1
					end
					mouse_at = {
						math.floor(event_data:GetInt("X") / scale),
						math.floor(event_data:GetInt("Y") / scale),
					}
				end)

		-- Where a click landed, which MouseButtonDown does not say
		local ui_click_cb = magic.SubscribeToEvent("UIMouseClick",
				function(event_type, event_data)
			local button = event_data:GetInt("Button")
			if form then
				form_click(event_data:GetInt("X"), event_data:GetInt("Y"),
						button)
			elseif chat_input and button == MOUSEB_LEFT then
				chat_click(event_data:GetInt("X"), event_data:GetInt("Y"))
			end
		end)
		-- The wheel scrolls the table a form has; a form with two of them
		-- would want to know which one the mouse is over, and none of this
		-- game's do.
		local mouse_wheel_cb = magic.SubscribeToEvent("MouseWheel",
				function(event_type, event_data)
					if not form or not form.drawn then
						return
					end
					local t = form.drawn.tables[1]
					if not t or t.count <= t.visible then
						return
					end
					local by = -event_data:GetInt("Wheel") * 3
					local at = math.max(0, math.min(t.count - t.visible,
							t.scroll + by))
					if at ~= t.scroll then
						form.state.scroll[t.name] = at
						form_stale = true
					end
				end)

		local mouse_up_cb = magic.SubscribeToEvent("MouseButtonUp",
				function(event_type, event_data)
			if event_data:GetInt("Button") == MOUSEB_LEFT then
				digging = false
			end
			-- Dragging a stack: the press picked it up (UIMouseClick fires
			-- on the way down), and letting go over another slot puts it
			-- there. Over the slot it came from, or over nothing, the stack
			-- stays in hand -- which is a plain click, and what the next
			-- click puts down.
			if form and form.drawn and held and mouse_at then
				local slot = slot_at(mouse_at[1] - form.drawn.origin[1],
						mouse_at[2] - form.drawn.origin[2])
				if slot and not (slot.location == held.location and
						slot.list == held.list and
						slot.index == held.index) then
					put_into(slot, event_data:GetInt("Button"))
				end
			end
			if event_data:GetInt("Button") == MOUSEB_RIGHT and not form then
				-- On the way up rather than the way down, so that holding
				-- the button does not place a stack of nodes at once
				place()
			end
		end)

		-- Everything this session put on the screen or subscribed to, taken
		-- back. What is left after it is the empty stack the connect dialog
		-- was pushed on.
		leave = function()
			if left then
				return
			end
			left = true
			magic.UnsubscribeFromEvent("Update", update_cb)
			magic.UnsubscribeFromEvent("MouseButtonDown", mouse_down_cb)
			magic.UnsubscribeFromEvent("MouseButtonUp", mouse_up_cb)
			magic.UnsubscribeFromEvent("MouseMove", mouse_move_cb)
			magic.UnsubscribeFromEvent("UIMouseClick", ui_click_cb)
			magic.UnsubscribeFromEvent("MouseWheel", mouse_wheel_cb)
			magic.UnsubscribeFromEvent("ScreenMode", screen_mode_cb)
			close_form()
			ui:drop_tooltip()
			close_chat()
			chat_text:Remove()
			status_text:Remove()
			if loading_panel then
				loading_panel:Remove()
				loading_panel = nil
			end
			if hud then
				hud:Remove()
				hud = nil
			end
			for _, bar in ipairs(crosshair) do
				bar:Remove()
			end
			if held_element then
				held_element:Remove()
				held_element = nil
			end
			magic.input:SetMouseVisible(true)
			client:disconnect()
			view:close()
			uistack.main:pop(root)
		end

		-- The server said no, or the connection went away. Whatever is on the
		-- screen is no use any more, and a client that writes a line in the
		-- corner and then sits there is not telling anybody anything: the
		-- reason goes in a dialog, and closing that closes the client.
		client.on_failed = function(text)
			log:info("Session ended: "..(text:gsub("\n", " ")))
			leave()
			ui_utils.show_message_dialog(text, function()
				if got_content then
					engine:Exit()
				else
					-- Nothing of the game ever arrived, so this was the
					-- address, the name or the password: back to where they
					-- are typed
					show_connect_dialog(host..":"..port, name)
				end
			end)
		end

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
			-- Luanti's own keys for what is on the screen
			if key == KEY_F1 then
				show_hud = not show_hud
				update_hud()
			end
			if key == KEY_F2 then
				show_chat = not show_chat
				chat_text.visible = show_chat
			end
			if key == KEY_F5 then
				show_debug = not show_debug
				status_text.visible = show_debug
			end
			if key == KEY_H then
				avatar.noclip = not avatar.noclip
				add_line(avatar.noclip and "Through walls" or "Solid walls")
			end
			if key == KEY_ESCAPE and form then
				close_form()
			elseif key == KEY_ESCAPE then
				leave()
			end
		end)
	end)
end

-- address and name are what to start the fields with; without them the
-- environment's own defaults. What passes them is a session that ended before
-- it got anywhere: whatever was wrong with them, they are what to fix.
show_connect_dialog = function(address, name)
	local root = uistack.main:push({desc="luanti_client connect"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "__menu/res/main_style.xml")

	local menu = ui_utils.vertical_menu(root, {min_width = 300})
	local window = menu.window

	local title = window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Connect to a Luanti server"

	local address_edit = labeled_edit(window, "Address",
			address or DEFAULT_ADDRESS)
	local name_edit = labeled_edit(window, "Player name", name or DEFAULT_NAME)
	local password_edit = labeled_edit(window, "Password", "")
	-- The password is the field a second try is most likely about, and it is
	-- the one that is not filled in
	if address then
		password_edit:SetFocus(true)
	else
		address_edit:SetFocus(true)
	end

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
