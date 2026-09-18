-- Buildat: extension/__menu/launch_grid.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch grid's actions ([LAUNCH_GRID]): every launcher/init.lua in
-- the tree run in the sandbox, its actions checked, their icons resolved
-- on this side, and ctx.launch -- the file's one way out -- with its
-- params crossing as plain data into a receiver that knows it is
-- untrusted. See doc/plan/launcher_plan.md.
local launch_menu = require("buildat/extension/launch_menu")
local M = {}

local ICON_FALLBACK = "buildat_logo.png"
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
	elseif request.game then
		if next(params) ~= nil then
			log:warning("launch from "..from..": a game takes no params yet")
			return
		end
		launch_menu.start_local_game(tostring(request.game))
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

local KIND_ORDER = {menu = 0, game = 1, builtin = 2, extension = 3}

-- Every action the tree offers, checked and in the grid's order: explicit
-- order first, then by kind -- games, builtins, extensions -- then label
function M.actions(log)
	local out = {}
	for _, source in ipairs(buildat.list_launchers()) do
		local actions, from = nil, source.kind.."/"..source.name
		if source.launcher then
			actions = run_launcher(log, source)
		elseif source.kind == "game" then
			-- A game without a launcher gets one tile: its name, its own
			-- icon.png beside its init.lua if it has one, and a launch
			local icon = io.open(source.path.."/icon.png", "rb")
			if icon then icon:close() end
			actions = {{id = "play", label = source.name,
				icon = icon and (source.name.."/icon.png") or ICON_FALLBACK,
				resolved_icon = true,
				run = function()
					launch_menu.start_local_game(source.name)
				end}}
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
				elseif type(a.icon) == "string" and
						not a.icon:find("[/\\]") then
					-- Resolved here, never by the file: <name>/launcher/<icon>
					-- under the kind's resource dir, so two launchers with an
					-- icon.png do not collide
					icon = source.name.."/launcher/"..a.icon
				end
				local run = a.run
				out[#out + 1] = {
					id = a.id, label = a.label, icon = icon,
					description = type(a.description) == "string" and
							a.description or nil,
					order = tonumber(a.order),
					kind = source.kind, from = from,
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
