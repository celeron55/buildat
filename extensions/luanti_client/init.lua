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
local M = {safe = nil}

-- BUILDAT_LUANTI_ADDRESS is for scripted runs (bin/buildat_client -c ...),
-- which cannot easily clear a text field
local DEFAULT_ADDRESS = os.getenv("BUILDAT_LUANTI_ADDRESS") or "localhost:30000"

-- How far the camera sees, and how far out blocks are kept, in nodes. The
-- client asks the server for blocks by the same distance; see
-- WANTED_RANGE_BLOCKS in client.lua.
local FAR_CLIP = 240
local DROP_DISTANCE = 260
-- Degrees of look per pixel of mouse movement
local MOUSE_SENSITIVITY = 0.15

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
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "__menu/res/main_style.xml")

	-- Text in the corner rather than a window: the world is behind it
	local status_text = root:CreateChild("Text")
	status_text:SetStyleAuto()
	status_text:SetAlignment(HA_LEFT, VA_TOP)
	status_text:SetPosition(8, 8)
	status_text.color = magic.Color(1.0, 1.0, 1.0)

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
		local announced = nil
		local to_ask = {}
		local media_asked_at = nil
		local registry_stale = false

		-- A tile's texture name -> a resource name, or nil for one that is not
		-- there. Texture modifiers ("grass.png^[colorize:...") are their own
		-- language and are not a file name at all; those nodes keep the
		-- placeholder.
		local function resolve_texture(name)
			local plain = nodedef.plain_texture_name(name)
			if not plain or not store:have_file(plain) then
				return nil
			end
			return server_key.."/"..plain
		end

		local function rebuild_registry()
			registry_stale = false
			if not node_defs then
				return
			end
			local t0 = buildat.get_time_us()
			local cubes = view:set_node_definitions(node_defs,
					resolve_texture)
			add_line(cubes.." node types have their own textures"..
					" ("..store:have_count().." files, "..
					math.floor((buildat.get_time_us() - t0) / 1000).." ms)")
		end

		-- The announcement and the definitions arrive in that order today, but
		-- the plan needs both, so either one arriving makes it
		local function plan_media()
			if not (node_defs and announced) then
				return
			end
			local wanted = nodedef.texture_names(node_defs)
			for _, name in ipairs(store:plan(announced, wanted)) do
				to_ask[#to_ask + 1] = name
			end
		end

		client.on_nodedef = function(data)
			local defs, count = nodedef.parse(luanti.serialize, data, log)
			node_defs = defs
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
			registry_stale = true
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

		-- The bottom line is remade every frame; everything above it is the
		-- log of what happened
		local function set_counters()
			-- What is not handled yet is logged once per command by
			-- client.lua rather than shown here; it is a long line and the
			-- world is behind it
			status_text.text = table.concat(lines, "\n").."\n"..
					string.format(
					"%s | %.1f, %.1f, %.1f %s | blocks: %d received,"..
					" %d in scene, %d to mesh | %d us to hand over"..
					" | media: %d files, %d to come",
					client.state, avatar.x, avatar.y, avatar.z,
					avatar.fly and "flying" or
							(avatar.in_liquid and "swimming" or
							(avatar.on_ground and "on ground" or "falling")),
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
			local dmouse = magic.input:GetMouseMove()
			local yaw = client.yaw + dmouse.x * MOUSE_SENSITIVITY
			-- Luanti's pitch is positive looking up, and the mouse moving away
			-- from the user is negative y
			local pitch = client.pitch - dmouse.y * MOUSE_SENSITIVITY
			if pitch > 89 then pitch = 89 end
			if pitch < -89 then pitch = -89 end

			local p = client.position
			if p.x ~= avatar.x or p.y ~= avatar.y or p.z ~= avatar.z then
				avatar:set_position(p.x, p.y, p.z)
			end

			local yr = math.rad(yaw)
			local fx, fz = math.sin(yr), math.cos(yr)
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
			view:update(dtime, DROP_DISTANCE)

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

		root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
			local key = event_data:GetInt("Key")
			-- Luanti's own keys for these. A server that does not give the
			-- player the fly and noclip privileges pulls them back.
			if key == KEY_K then
				avatar.fly = not avatar.fly
				add_line(avatar.fly and "Flying" or "Walking")
			end
			if key == KEY_H then
				avatar.noclip = not avatar.noclip
				add_line(avatar.noclip and "Through walls" or "Solid walls")
			end
			if key == KEY_ESCAPE then
				magic.UnsubscribeFromEvent("Update", update_cb)
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
	local name_edit = labeled_edit(window, "Player name", "buildat")
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
