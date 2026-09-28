-- Buildat: client/sandbox.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sandbox")
local dump = buildat.dump

--
-- Base sandbox environment
--

__buildat_sandbox_environment = {
	assert = assert, -- Safe according to http://lua-users.org/wiki/SandBoxes
	error = error,
	-- Base sandbox from
	-- http://stackoverflow.com/questions/1224708/how-can-i-create-a-secure-lua-sandbox/6982080#6982080
	ipairs = ipairs,
	next = next,
	pairs = pairs,
	pcall = pcall,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	unpack = unpack,
	coroutine = { create = coroutine.create, resume = coroutine.resume,
		running = coroutine.running, status = coroutine.status,
		wrap = coroutine.wrap },
	string = { byte = string.byte, char = string.char, find = string.find,
		format = string.format, gmatch = string.gmatch, gsub = string.gsub,
		len = string.len, lower = string.lower, match = string.match,
		rep = string.rep, reverse = string.reverse, sub = string.sub,
		upper = string.upper },
	table = { concat = table.concat, insert = table.insert,
		maxn = table.maxn, remove = table.remove, sort = table.sort },
	math = { abs = math.abs, acos = math.acos, asin = math.asin,
		atan = math.atan, atan2 = math.atan2, ceil = math.ceil, cos = math.cos,
		cosh = math.cosh, deg = math.deg, exp = math.exp, floor = math.floor,
		fmod = math.fmod, frexp = math.frexp, huge = math.huge,
		ldexp = math.ldexp, log = math.log, log10 = math.log10, max = math.max,
		min = math.min, modf = math.modf, pi = math.pi, pow = math.pow,
		rad = math.rad, random = math.random, sin = math.sin, sinh = math.sinh,
		sqrt = math.sqrt, tan = math.tan, tanh = math.tanh },
	os = { clock = os.clock, difftime = os.difftime, time = os.time },
}

--
-- Sandbox require
--

-- Two namespaces are loadable from inside the sandbox and nothing else is:
-- an extension's safe interface, and a module's client half.
--
-- **package.loaded is not a whitelist and must never be searched by name**,
-- which is what this used to do before looking at either namespace. It
-- holds every standard library the host state has -- so require("os")
-- handed the sandbox os.execute, require("io") handed it io.open,
-- require("package") handed it loadlib and require("_G") handed it
-- loadstring, none of which are anywhere near the sandbox environment
-- itself. A server's client Lua runs in here, so that was the server
-- running what it liked on the machine of everyone who connected to it.
-- Each namespace looks in package.loaded under its own full name, which is
-- what it was written under.
__buildat_sandbox_environment.require = function(name)
	log:debug("require(\""..name.."\")")
	-- Allow loading extensions
	local m = string.match(name, '^buildat/extension/([a-zA-Z0-9_]+)$')
	if m then
		local unsafe = package.loaded[name]
		if unsafe == nil then
			unsafe = __buildat_require_extension(m)
			if unsafe == nil then
				error("require: Cannot load extension: \""..m.."\"")
			end
			package.loaded[name] = unsafe
			log:verbose("Loaded extension \""..name.."\"")
		end
		if type(unsafe) ~= 'table' or type(unsafe.safe) ~= 'table' then
			error("require: \""..name.."\" didn't return safe interface")
		end
		return unsafe.safe
	end
	-- Allow loading the client-side parts of modules
	local m = string.match(name, '^buildat/module/([a-zA-Z0-9_]+)$')
	if m then
		local interface = package.loaded[name]
		if interface == nil then
			interface = __buildat_require_module(m)
			if interface == nil then
				error("require: Cannot load module: \""..m.."\"")
			end
			package.loaded[name] = interface
			log:verbose("Loaded module \""..name.."\"")
		end
		return interface
	end
	-- Disallow loading anything else
	error("require: \""..name.."\" not found in sandbox")
end

-- What a connection's sandboxed scripts left behind, dropped, so that a
-- menu-only connection can be left for the launcher without exiting the
-- client ([MENU_CONTEXT]): the packet handlers, the module halves'
-- require cache, the event mux's sandbox handlers, and the replicated
-- scene's children (the game's camera, zone, sky). The UI stack is the
-- launcher's to pop. simplified: what the module halves put in C++ --
-- composed textures, the voxel registry -- stays; a new connection
-- replaces it by name.
function __buildat_reset_sandbox()
	__buildat_reset_packet_subs()
	for name, _ in pairs(package.loaded) do
		if string.match(name, '^buildat/module/') then
			package.loaded[name] = nil
		end
	end
	__buildat_reset_modules()
	-- **These two never ran**: an extension is not in package.loaded --
	-- the loader keeps its own table -- so both lookups read nil from
	-- the day they were written (found 2026-09-23 by [LAUNCH_WORLD]).
	-- __buildat_loaded_extension() is the table's own reader, and it
	-- does not load an extension that is not up.
	local urho3d = __buildat_loaded_extension("urho3d")
	if urho3d and urho3d.drop_sandbox_handlers then
		-- **The launch UI's own handlers stay**: it is sandboxed code
		-- too now ([LAUNCH_SANDBOX]), and dropping them left the room
		-- drawing and answering nothing after a game (2026-09-23)
		urho3d.drop_sandbox_handlers(__buildat_menu_extension_name)
	end
	local replicate = __buildat_loaded_extension("replicate")
	if replicate and replicate.reset then
		replicate.reset()
	end
	log:info("__buildat_reset_sandbox(): done")
end

--
-- Sandbox environment debugging
--

-- Bindings for debug or safety checks (override function)
local __buildat_sandbox_debug_check_value_subs = {}
function __buildat_sandbox_debug_check_value_sub(f)
	table.insert(__buildat_sandbox_debug_check_value_subs, f)
end
function __buildat_sandbox_debug_check_value(value)
	for _, f in ipairs(__buildat_sandbox_debug_check_value_subs) do
		f(value)
	end
end

-- For debugging purposes. Used by extensions/sandbox_test.
__buildat_latest_sandbox_global_wrapper_number = 0 -- Incremented every time
__buildat_latest_sandbox_global_wrapper = nil
-- Save a number of old wrappers for debugging purposes
__buildat_old_sandbox_global_wrappers = {}

local function debug_new_wrapper(sandbox)
	if __buildat_latest_sandbox_global_wrapper then
		table.insert(__buildat_old_sandbox_global_wrappers, __buildat_latest_sandbox_global_wrapper)
		-- Keep a number of old wrappers.
		-- These wrappers are created at quite a fast pace due to Update events.
		if #__buildat_old_sandbox_global_wrappers > 60*5 then
			table.remove(__buildat_old_sandbox_global_wrappers, 1)
		end
	end
	__buildat_latest_sandbox_global_wrapper_number = __buildat_latest_sandbox_global_wrapper_number + 1
	__buildat_latest_sandbox_global_wrapper = sandbox
end

--
-- Running code in sandbox
--

local function wrap_globals(base_sandbox)
	local sandbox = {}
	local sandbox_declared_globals = {}
	-- Sandbox special functions
	sandbox.sandbox = {}
	function sandbox.sandbox.make_global(t)
		for k, v in pairs(t) do
			if sandbox[k] == nil then
				rawset(sandbox, k, v)
			end
		end
	end
	-- Prevent setting sandbox globals from functions (only from the main chunk)
	setmetatable(sandbox, {
		__index = function(t, k)
			local v = rawget(sandbox, k)
			if v ~= nil then return v end
			return base_sandbox[k]
		end,
		__newindex = function(t, k, v)
			if not sandbox_declared_globals[k] then
				local info = debug.getinfo(2, "Sl")
				log:debug("Global: "..dump(k).." (set by {what="..dump(info.what)..
						", name="..dump(info.name).."})")
				if info.what == "Lua" then
					error("Assignment to undeclared global \""..k.."\"\n     in "..
							info.short_src.." line "..info.currentline)
				end
			end
			sandbox_declared_globals[k] = true
			rawset(sandbox, k, v)
		end
	})
	debug_new_wrapper(sandbox)
	return sandbox
end

local function run_function_in_sandbox(untrusted_function, sandbox)
	sandbox = wrap_globals(sandbox)
	setfenv(untrusted_function, sandbox)
	local retval = nil
	local status, err = __buildat_pcall(function()
		retval = untrusted_function()
	end)
	return status, err, retval
end

-- A caught error shown, not only logged ([MENU_ERRORS]): before a world
-- is joined -- the launch menu and every screen on the stack -- a dialog
-- with the message's first line and "the log has the rest", the screen
-- it happened on left as it is; in a game a notice line, since a form's
-- callback erroring must not take the mouse. One per distinct message
-- a minute, so a per-frame error is one dialog and a log full. The
-- box's Connect died in its pcall and the screen just went back
-- (2026-09-22).
local reported_at = {}
function __buildat_report_error(err)
	local first = tostring(err):match("^[^\n]*") or tostring(err)
	local now = os.time()
	if reported_at[first] and now - reported_at[first] < 60 then
		return
	end
	reported_at[first] = now
	local ui_utils = __buildat_loaded_extension("ui_utils") or
			__buildat_require_extension("ui_utils")
	if type(ui_utils) ~= "table" or type(ui_utils.safe) ~= "table" then
		return
	end
	-- A game the launcher started, or a client that says a world is up on
	-- its own screens (luanti_client's session). Whichever extension is
	-- the launcher, not launch_menu by name (buildat.menu_extension).
	local menu = buildat.menu_extension and buildat.menu_extension()
	local in_game = (menu and menu.in_game and menu.in_game()) or
			ui_utils.in_game == true
	local shown = first .. "\n\n(the log has the rest)"
	log:info("error shown "..(in_game and "as a notice" or "in a dialog")..": "..first)
	if in_game then
		if ui_utils.safe.show_notice then
			ui_utils.safe.show_notice(first)
		end
	elseif ui_utils.safe.show_message_dialog then
		ui_utils.safe.show_message_dialog(shown)
	end
end

function __buildat_run_function_in_sandbox(untrusted_function)
	local status, err, retval = run_function_in_sandbox(
			untrusted_function, __buildat_sandbox_environment)
	if status == false then
		log:error("Failed to run function:\n"..err)
		local ok, why = pcall(__buildat_report_error, err)
		if not ok then
			log:warning("the error could not be shown: "..tostring(why))
		end
	end
	return status, err, retval
end

local function run_code_in_sandbox(untrusted_code, sandbox, chunkname)
	if untrusted_code:byte(1) == 27 then
		return false, "binary bytecode prohibited", nil
	end
	local untrusted_function, message = loadstring(untrusted_code, chunkname)
	if not untrusted_function then
		return false, message, nil
	end
	return run_function_in_sandbox(untrusted_function, sandbox)
end

function __buildat_run_code_in_sandbox(untrusted_code, chunkname)
	local status, err, retval = run_code_in_sandbox(
			untrusted_code, __buildat_sandbox_environment, chunkname)
	if status == false then
		log:error("Failed to run script:\n"..err)
		local ok, why = pcall(__buildat_report_error, err)
		if not ok then
			log:warning("the error could not be shown: "..tostring(why))
		end
	end
	return status, err, retval
end

function buildat.run_script_file(name)
	local code = __buildat_get_file_content(name)
	if not code then
		log:error("Failed to load script file: "..name)
		return false
	end
	log:info("buildat.run_script_file("..name.."): code length: "..#code)
	return __buildat_run_code_in_sandbox(code, name)
end
buildat.safe.run_script_file = buildat.run_script_file

--
-- Insert buildat.safe into sandbox as buildat
--

__buildat_sandbox_environment.buildat = {}
for k, v in pairs(buildat.safe) do
	__buildat_sandbox_environment.buildat[k] = v
end

-- With this you can do stuff like
--   local is_in_sandbox = getfenv(2).buildat.is_in_sandbox
-- in extensions.
__buildat_sandbox_environment.buildat.is_in_sandbox = true

setmetatable(__buildat_sandbox_environment.buildat, {
	__newindex = function(t, k, v)
		assert("Cannot add fields to buildat namespace in sandbox environment")
	end,
})

log:info("sandbox.lua loaded")
-- vim: set noet ts=4 sw=4:
