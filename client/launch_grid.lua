-- Buildat: client/launch_grid.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch grid's actions ([LAUNCH_GRID]): every launcher/init.lua in
-- the tree run in the sandbox, its actions checked, their icons resolved
-- on this side, and ctx.launch -- the file's one way out -- with its
-- params crossing as plain data into a receiver that knows it is
-- untrusted. See doc/plan/launcher_plan.md. Loaded by client/api.lua,
-- whose launch_actions() and launch() are its safe face.
local M = {}

local ICON_FALLBACK = "buildat_logo.png"

-- **The screens a game is started through**, extensions/launch_menu/
-- screens.lua, run in the sandbox for each launch: every launch UI's game
-- starts end there, and the file keeps no state, so a fresh copy is the
-- same as a kept one. Named after the extension, as its own loader
-- names it, so the verbs know whose file it is.
function M.screens()
	local f = io.open(__buildat_extension_path("launch_menu") ..
			"/screens.lua", "rb")
	if not f then
		error("launch_grid: no launch_menu/screens.lua")
	end
	local code = f:read("*a")
	f:close()
	local ok, err, m = __buildat_run_code_in_sandbox(code,
			"launch_menu/screens.lua")
	if not ok or type(m) ~= "table" then
		error("launch_grid: launch_menu/screens.lua: " .. tostring(err))
	end
	return m
end

-- The launch menu's own two tiles, which every launch UI's grid has:
-- the local game list and connecting to a server
local function menu_actions()
	return {
		{id = "local", label = "Local app", order = 1,
			icon = "launch_menu/res/icon_local.png", resolved_icon = true,
			description = "Start an app on this machine",
			run = function() M.screens().show_local_apps() end},
		{id = "connect", label = "Connect to server", order = 2,
			icon = "launch_menu/res/icon_network.png", resolved_icon = true,
			description = "Join a buildat server",
			run = function() M.screens().show_connect_to_server() end},
	}
end
local MAX_PARAMS_DEPTH = 8

-- params as plain data: strings, numbers, booleans and tables of them,
-- copied into a fresh table so nothing of the sandbox's reaches the
-- trusted side by reference; anything else is an error at the call
local function plain_copy(v, depth)
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" or t == "nil" then
		return v
	end
	if t ~= "table" then
		error("ctx.launch: params may hold strings, numbers, booleans and "..
				"tables, not a "..t)
	end
	if depth > MAX_PARAMS_DEPTH then
		error("ctx.launch: params nested too deep")
	end
	local out = {}
	for k, x in pairs(v) do
		local kt = type(k)
		if kt ~= "string" and kt ~= "number" then
			error("ctx.launch: a params key is a "..kt)
		end
		out[k] = plain_copy(x, depth + 1)
	end
	return out
end

-- What a launch does, per target kind. An extension is entered through its
-- on_untrusted_launch(request) and nothing else; a game starts a local
-- server the way the local-game screen does. simplified: params reach an
-- extension and not yet a game or a builtin -- the server has no door for
-- them yet (`untrusted_launch` in its config is the plan), so a game with
-- params, and a module target, are refused with a warning until it does.
local function do_launch(log, from, request)
	local params = plain_copy(request.params, 0) or {}
	if request.extension then
		local name = tostring(request.extension)
		local ok, ext = pcall(require, "buildat/extension/"..name)
		if not ok or type(ext) ~= "table" or
				type(ext.on_untrusted_launch) ~= "function" then
			log:warning("launch from "..from..": extension "..name..
					" has no on_untrusted_launch; not a target")
			return
		end
		ext.on_untrusted_launch({from = from, params = params})
	elseif request.app or request.game then
		-- (`game`, as an app was called before: accepted still)
		local app = request.app or request.game
		-- To a game the params go as key=value lines through the server's
		-- -u, which a module reads as it would a packet; the top level
		-- only, strings, numbers and booleans, a key of a name's shape
		local lines = {}
		for k, v in pairs(params) do
			if type(k) ~= "string" or not k:match("^[%w_]+$") or
					type(v) == "table" or tostring(v):find("\n") then
				log:warning("launch from "..from..": param "..tostring(k)..
						" cannot reach a game; dropped")
			else
				lines[#lines + 1] = k.."="..tostring(v)
			end
		end
		M.screens().start_local_app(tostring(app),
				table.concat(lines, "\n"))
	elseif request.module then
		log:warning("launch from "..from..": a builtin module is not a "..
				"target yet ([LAUNCH_GRID])")
	else
		log:warning("launch from "..from..": no extension, game or module")
	end
end

-- The file, run in the sandbox as a module's client Lua is, given ctx
local function run_launcher(log, source)
	local path = source.path.."/launcher/init.lua"
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local code = f:read("*a")
	f:close()
	local from = source.kind.."/"..source.name
	local ctx = {
		kind = source.kind, name = source.name, path = source.path,
		launch = function(request)
			if type(request) ~= "table" then
				error("ctx.launch: wants a table")
			end
			-- An app installed from a release launches itself and nothing
			-- else: its launcher names the app as it is in its tree, and
			-- the tile is that version of it ([AITTA_MVP])
			if source.kind == "installed" then
				request = {app = source.name, params = request.params}
			end
			do_launch(log, from, request)
		end,
	}
	local status, err, chunk = __buildat_run_code_in_sandbox(code,
			"launcher "..from)
	if not status then
		log:warning("launcher "..from..": "..tostring(err))
		return nil
	end
	if type(chunk) ~= "function" then
		log:warning("launcher "..from..": the file did not return a function")
		return nil
	end
	local ok, actions = pcall(chunk, ctx)
	if not ok then
		log:warning("launcher "..from..": "..tostring(actions))
		return nil
	end
	if type(actions) ~= "table" then
		log:warning("launcher "..from..": returned a "..type(actions)..
				", not a table of actions")
		return nil
	end
	return actions, from
end

local KIND_ORDER = {menu = 0, app = 1, installed = 1, builtin = 2, extension = 3}

-- Every action the tree offers, checked and in the grid's order: explicit
-- order first, then by kind -- apps, builtins, extensions -- then label
-- **What a launch action says about itself** ([LAUNCH_SIGNIFY]): the
-- category is what kind of thing it is -- an **open set**, so a launch
-- UI that meets one it does not know draws its default rather than
-- failing -- and the significance is a non-negative number it may rank
-- and scale by, comparable **within** a category and nowhere else.
-- Absent means "no opinion" and is never an error, since most sources
-- have no view.
--
-- A launcher file may say both; what it does not say is defaulted here:
-- a game is a `game` of its own installed size, and everything else is
-- an `action` with no opinion. So the size a launch UI already draws
-- games by comes from the action rather than from the UI guessing which
-- game an action came from.
local function significance_of(a, source, app_sizes)
	local n = tonumber(a.significance)
	if n == nil and source.kind == "app" then
		n = app_sizes[source.name]
	end
	if n == nil or n < 0 then
		return nil
	end
	return n
end

local function category_of(a)
	if type(a.category) == "string" and a.category:match("^[%w_]+$") then
		return a.category
	end
	return nil
end

function M.actions(log)
	local out = {}
	local app_sizes = {}
	for _, g in ipairs(buildat.list_apps() or {}) do
		app_sizes[g.name] = tonumber(g.size)
	end
	for _, source in ipairs(buildat.list_launchers()) do
		local actions, from = nil, source.kind.."/"..source.name
		-- One rule: a directory is on the grid if it has launcher/init.lua.
		-- The default tile for a game without one put the test scenes on
		-- the grid; the real games carry a two-line file each.
		if source.kind == "extension" and source.name == "launch_menu" then
			actions = menu_actions()
		elseif source.launcher then
			actions = run_launcher(log, source)
		end
		local seen = {}
		for i, a in ipairs(actions or {}) do
			if type(a) ~= "table" or type(a.label) ~= "string" or
					type(a.run) ~= "function" then
				log:warning("launcher "..from..": action "..i..
						" has no label or run; skipped")
			elseif a.id ~= nil and seen[a.id] then
				log:warning("launcher "..from..": duplicate id "..
						tostring(a.id).."; first wins")
			else
				if a.id ~= nil then seen[a.id] = true end
				local icon = ICON_FALLBACK
				if a.resolved_icon then
					icon = a.icon
				elseif source.kind == "installed" then
					-- simplified: an installed app's icon is the fallback,
					-- as <user>/installed is no resource dir; the upgrade
					-- is copying it under the cache as
					-- installed_game_icon() does a Luanti game's
					icon = ICON_FALLBACK
				elseif type(a.icon) == "string" and
						not a.icon:find("[/\\]") then
					-- Resolved here, never by the file: <name>/launcher/<icon>
					-- under the kind's resource dir, so two launchers with an
					-- icon.png do not collide
					icon = source.name.."/launcher/"..a.icon
				end
				local run = a.run
				out[#out + 1] = {
					id = a.id, icon = icon,
					-- Every installed version is a tile, and says which
					label = source.kind == "installed" and
							a.label.." "..source.name:match("@(.*)$") or a.label,
					description = type(a.description) == "string" and
							a.description or nil,
					order = tonumber(a.order),
					kind = source.kind, from = from,
					category = category_of(a) or
							((source.kind == "app" or source.kind == "installed")
							and "app" or "action"),
					significance = significance_of(a, source, app_sizes),
					run = function()
						local ok, err = pcall(run)
						if not ok then
							log:warning("launcher "..from..": "..tostring(err))
						end
					end,
				}
			end
		end
	end
	table.sort(out, function(a, b)
		if (a.order ~= nil) ~= (b.order ~= nil) then
			return a.order ~= nil
		end
		if a.order ~= nil and a.order ~= b.order then
			return a.order < b.order
		end
		if KIND_ORDER[a.kind] ~= KIND_ORDER[b.kind] then
			return KIND_ORDER[a.kind] < KIND_ORDER[b.kind]
		end
		return a.label < b.label
	end)
	return out
end

return M
-- vim: set noet ts=4 sw=4:
