-- Buildat: client/api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/api")

buildat.connect_server    = __buildat_connect_server
-- The connect on a worker, polled from a frame handler: the blocking one
-- froze the waiting screen for as long as the connect took
-- ([BOX_PLAYTEST_2] 12)
buildat.connect_server_start = __buildat_connect_server_start
buildat.connect_server_poll  = __buildat_connect_server_poll
buildat.list_games        = __buildat_list_games
-- list_saves([game]) -> {{game=, name=, modified=}, ...}, newest first.
-- The saves on disk, enumerated without a server, since a launcher has
-- none to ask ([LAUNCH_WORLD]).
buildat.list_saves        = __buildat_list_saves
-- list_launchers() -> {{kind, name, path, launcher = bool}, ...}: every
-- game, builtin and extension in the tree, for the launch grid
buildat.list_launchers    = __buildat_list_launchers
-- list_installed_games(family) -> {{name =, size =, icon =}, ...} under
-- <user>/<family>/games; read-only, and in the sandbox too, for a launcher
-- file's tiles. icon is the resource name of the game's own menu/icon.png
-- where it ships one, and absent where it does not ([LAUNCH_API])
buildat.list_installed_games = __buildat_list_installed_games
buildat.safe.list_installed_games = __buildat_list_installed_games
buildat.start_local_server = __buildat_start_local_server
buildat.stop_local_server = __buildat_stop_local_server
buildat.request_stop_local_server = __buildat_request_stop_local_server
buildat.force_kill_local_server = __buildat_force_kill_local_server
buildat.local_server_ready = __buildat_local_server_ready
buildat.local_server_port = __buildat_local_server_port
buildat.local_server_running = __buildat_local_server_running
-- The last STATUS line of the local server's log, and its tail for a
-- dialog about one that died ([START_PROGRESS])
buildat.local_server_status = __buildat_local_server_status
buildat.local_server_log_tail = __buildat_local_server_log_tail
buildat.extension_path    = __buildat_extension_path
buildat.get_time_us       = __buildat_get_time_us
buildat.version           = __buildat_version
buildat.sha1              = __buildat_sha1
buildat.sha256            = __buildat_sha256
buildat.hex               = __buildat_hex
buildat.random_bytes      = __buildat_random_bytes
-- compress(data, format [, level]) -> string, where format is "zlib" or "zstd"
-- decompress(data [, format]) -> data, bytes_consumed
buildat.compress          = __buildat_compress
buildat.decompress        = __buildat_decompress
-- Big-endian byte strings in, byte strings out
buildat.bignum = {
	add     = __buildat_bignum_add,
	mul     = __buildat_bignum_mul,
	mod     = __buildat_bignum_mod,
	sub_mod = __buildat_bignum_sub_mod,
	mul_mod = __buildat_bignum_mul_mod,
	mod_exp = __buildat_bignum_mod_exp,
}
buildat.set_ui_scale      = __buildat_set_ui_scale
buildat.get_ui_scale      = __buildat_get_ui_scale
buildat.logical_size      = __buildat_logical_size
-- The fraction of the window size the user asked 3D viewports to be rendered
-- at. magic.set_preferred_viewports() applies it; this is for a game that
-- wants to know. 1.0 means no scaling at all.
buildat.get_preferred_render_scale = __buildat_get_preferred_render_scale
-- The preferences the user sets once and every game honours. The C++ side is
-- the authority: it parses and range checks a value through the same code -o
-- goes through, applies what takes effect now, and persists the rest. A
-- screen over these is a page of widgets that knows nothing about the file.
--
-- list_preferences() -> {name, ...}
-- get_preference(name) -> number or boolean, nil for a name there is none by
-- set_preference(name, value) -> true, or false and why
buildat.list_preferences  = __buildat_list_preferences
buildat.get_preference    = __buildat_get_preference
buildat.set_preference    = __buildat_set_preference
buildat.font_sans         = "Fonts/Overpass-Regular.ttf"
buildat.font_mono         = "Fonts/OverpassMono-Regular.ttf"
buildat.SpatialUpdateQueue = __buildat_SpatialUpdateQueue
buildat.pack_voxel_volume = __buildat_pack_voxel_volume
-- add_resource_dir(path) -> bool. Only under the cache path; Urho3D's own Lua
-- bindings do not have this.
buildat.add_resource_dir  = __buildat_add_resource_dir
-- take_screenshot() -> the file name it was saved under, or nil and why not.
-- Into <user>/screenshots, named by the date and the time; see
-- l_take_screenshot() in src/client/app.cpp for why this is in the sandbox.
buildat.take_screenshot   = __buildat_take_screenshot
-- dump_meshes([atlas_json]) -> the file name, or nil and why not. Same sandbox rule
-- as take_screenshot: into <user>/meshdumps, named by the date. The
-- scene's CustomGeometry in world space, which is what the client already
-- drew. See l_dump_meshes() in src/client/app.cpp.
buildat.dump_meshes       = __buildat_dump_meshes
-- compose_image(args) -> w, h. Raster operations over an RGBA canvas, saved as
-- a PNG under the cache path. See doc/client_api.txt.
buildat.compose_image     = __buildat_compose_image
-- read_image(resource_name) -> w, h, rgba. The pixels of an image, for
-- whoever has to look at them rather than draw them.
buildat.read_image        = __buildat_read_image
buildat.get_env           = __buildat_get_env
buildat.create_directories = __buildat_create_directories -- unsafe only
buildat.set_watchdog_seconds = __buildat_set_watchdog_seconds -- unsafe only

buildat.safe.disconnect    = __buildat_disconnect
-- **The extension this client was booted with as its launcher**, which
-- is -m's argument and launch_menu by default. What asks is whatever has
-- to go back to the launcher; those places named launch_menu outright,
-- which is wrong the moment the client is booted with another one.
-- Loaded only if it already is: this never boots a launcher by itself.
-- **A sandboxed launch UI is not in the trusted table of loaded
-- extensions** ([LAUNCH_SANDBOX]): its init.lua is run through the
-- sandbox's own loader, so `__buildat_loaded_extension` answers nil for
-- it and every caller that asked for the launcher got nothing. What
-- that cost: a game's own "back to the launcher" fell through to a
-- plain disconnect, and the client sat with no server and no room --
-- [FIRST_RUN]'s ContentDB run has been failing on exactly that
-- (2026-09-24). So a sandboxed launch UI hands its interface over as it
-- boots, and this is where it is kept.
local launch_ui_interface = nil
-- The three the client and a game's own menu call ([MENU_CONTEXT]);
-- anything else in the table is ignored rather than refused, since a
-- launch UI's module is its own and may hold whatever it likes.
local LAUNCH_INTERFACE = {entered_game = true, leave_game = true,
	in_game = true, show_dead_server = true}
-- **Merged, not replaced**, because a launch UI may be a composition
-- ([TWO_AUDIENCES]: the menu over the room). The composing extension's
-- own module usually has none of these -- it boots two others and that
-- is all -- so a replace would wipe what the composed ones gave and
-- leave the same dead client this was written to fix. Last one with a
-- function wins, which is the menu over the room: the menu is what a
-- game is launched from, so the menu is what it comes back to.
buildat.safe.provide_launch_interface = function(t)
	if type(t) ~= "table" then
		return false, "provide_launch_interface(t): a table"
	end
	launch_ui_interface = launch_ui_interface or {}
	for name in pairs(LAUNCH_INTERFACE) do
		if type(t[name]) == "function" then
			launch_ui_interface[name] = t[name]
		end
	end
	return true
end

function buildat.menu_extension()
	local name = __buildat_menu_extension_name or "launch_menu"
	return __buildat_loaded_extension(name) or launch_ui_interface
end
-- leave(): back to the launcher's grid when there is one under the game
-- ([MENU_CONTEXT]: the game's own menu offers it), else what disconnect
-- does -- a client started straight into a server has nothing to go back to
buildat.safe.leave = function()
	local m = buildat.menu_extension()
	if m and m.leave_game then
		m.leave_game()
	else
		-- **Said out loud, because the quiet version of this is a dead
		-- client**: with no launcher to go back to, leaving a game is a
		-- disconnect and whatever drew the game is gone with it. That is
		-- right for a client started straight into a server and wrong
		-- for one booted with a launcher, so which it was is worth a
		-- line in the log rather than a guess afterwards.
		log:info("leave: no launcher to go back to (" ..
				tostring(__buildat_menu_extension_name) ..
				"); disconnecting")
		__buildat_disconnect()
	end
end
--
-- **The launch UI's own verbs** ([LAUNCH_SANDBOX]). A launch extension
-- is a slot anybody can fill, so it has to be able to run in the
-- sandbox every game runs in -- and the rule that keeps this small is
-- that **the trusted side owns the verbs and the sandbox owns the
-- drawing**. Each of these does one nameable thing; none is a general
-- capability, because every addition here is attack surface for every
-- game as well.
--
-- launch_actions() -> the launch grid's tiles as plain data: no
-- functions, no paths to open, and the `key` is what launch() takes.
-- The list itself is built by sandboxed launcher files behind
-- `ctx.launch` already ([LAUNCH_GRID]), so this is one step further
-- out, not a new reach.
local launch_runs = {}
buildat.safe.launch_actions = function()
	local grid = dofile(buildat.extension_path("__menu") ..
			"/launch_grid.lua")
	local out = {}
	launch_runs = {}
	for i, a in ipairs(grid.actions(log)) do
		local key = tostring(a.from) .. "/" .. tostring(a.id or i)
		launch_runs[key] = a.run
		out[i] = {key = key, id = a.id, label = a.label, icon = a.icon,
			kind = a.kind, from = a.from, description = a.description,
			order = a.order,
			-- What the action says about itself ([LAUNCH_SIGNIFY]): the
			-- category is an open set and the significance a number to
			-- rank and scale by within one. Both are plain data and both
			-- may be absent.
			category = a.category, significance = a.significance}
	end
	return out
end
-- launch(key): run one of them. The key is looked up in the table the
-- trusted side built, so a sandbox cannot name anything that is not on
-- the grid, and it never hands a function across.
buildat.safe.launch = function(key)
	if type(key) ~= "string" then
		return false, "launch(key): a string from launch_actions()"
	end
	local run = launch_runs[key]
	if not run then
		return false, "launch(" .. key .. "): no such action"
	end
	run()
	return true
end
-- **Its own persistent storage**, one directory per launch extension
-- under the user path: `storage_read(name)` and `storage_write(name,
-- data)`. A name is one file, not a path -- no slashes, no dots on
-- their own -- so a launcher writes where it is put and nowhere else,
-- and the size is capped because a slot anybody can fill is a slot
-- anybody can fill a disk from.
local STORAGE_MAX = 4 * 1024 * 1024

-- **Which extension is asking**, taken from the caller's chunk name
-- rather than from which launch UI the client booted. The two are the
-- same until one launch UI composes another ([TWO_AUDIENCES]' third
-- option): then the global says the composer and the code running says
-- the composed, and a room borrowed as a backdrop would read and write
-- the composer's storage and load the composer's files. Every chunk
-- these verbs can be called from is named "<extension>/<file>" by the
-- loader that ran it, which is what this reads.
local function calling_extension(level)
	local info = debug.getinfo(level or 3, "S")
	local src = info and info.source or ""
	-- **A sandboxed chunk** is named `<extension>/<file>` by the loader
	-- that ran it
	local name = src:match("^@?([%w_]+)/[%w_%-%.]+$")
	if name then
		return name
	end
	-- **And a trusted one is a path on disk**, which is what an
	-- extension required by another extension is -- `launch_menu`
	-- requires `__menu`, whose own `run_extension_file("preferences.
	-- lua")` then looked in launch_menu's directory, found nothing,
	-- answered nil, and the client aborted eighty lines later
	-- ([MENU_FALLBACK], 2026-09-23). The same fault the composition
	-- found, in the other direction.
	name = src:match("[/\\]extensions[/\\]([%w_]+)[/\\]")
	if name then
		return name
	end
	return __buildat_menu_extension_name or "launch_menu"
end

local function storage_path(name)
	if type(name) ~= "string" or not name:match("^[%w_%-%.]+$") or
			name:find("%.%.") then
		return nil, "storage: a name of letters, digits, _ - and ."
	end
	local who = calling_extension(4)
	if not who:match("^[%w_]+$") then
		return nil, "storage: the launch extension has an odd name"
	end
	return __buildat_get_path("user") .. "/" .. who .. "/" .. name,
			__buildat_get_path("user") .. "/" .. who
end
buildat.safe.storage_read = function(name)
	local path = storage_path(name)
	if not path then
		return nil
	end
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end
buildat.safe.storage_write = function(name, data)
	local path, dir = storage_path(name)
	if not path then
		return false, dir
	end
	if type(data) ~= "string" then
		return false, "storage_write(name, data): data is a string"
	end
	if #data > STORAGE_MAX then
		return false, "storage_write: " .. #data .. " bytes is over the " ..
				STORAGE_MAX .. " a launcher may keep"
	end
	__buildat_create_directories(dir)
	local f = io.open(path, "wb")
	if not f then
		return false, "storage_write: could not open " .. name
	end
	f:write(data)
	f:close()
	return true
end

-- **Connecting to a server**, which a launcher does on a worker and
-- polls from a frame handler: the blocking one freezes the frame for as
-- long as it takes ([BOX_PLAYTEST_2] 12). An address is a string and
-- the client is what parses it.
buildat.safe.connect_start = function(address)
	if type(address) ~= "string" or #address > 256 then
		return false, "connect_start(address): a string"
	end
	__buildat_connect_server_start(address)
	return true
end
-- **JSON, because a body fetched is a body to read** ([URHO_SWEEP],
-- 2026-09-25): `network.http_get` hands a game a string and the sandbox
-- had nothing to parse it with. The answer is plain Lua -- tables,
-- strings, numbers, booleans -- parsed by the client's own reader, so
-- nothing holds a C++ object. A JSON null becomes nil, which in an
-- array leaves a hole; a document nests 64 deep at most.
-- parse_json(text) -> value, or nil and why not
buildat.safe.parse_json = function(text)
	if type(text) ~= "string" then
		return nil, "parse_json(text): a string"
	end
	return __buildat_parse_json(text)
end
buildat.safe.connect_poll = __buildat_connect_server_poll
-- **Back to the launcher from a game** ([MENU_CONTEXT]): the connection
-- dropped, the local server stopped and the sandbox's leavings cleared.
-- The launcher's own screens are its business; this is the client half.
buildat.safe.leave_to_menu = __buildat_leave_to_menu
-- Whether this client is driven by a command sequence, which a launcher
-- asks before taking the mouse: a check shares a desk with the person
-- whose mouse it is ([BOX_PLAYTEST_3])
buildat.safe.is_scripted = __buildat_is_scripted

-- **The client's preferences, against a fixed key set**: the names are
-- `list_preferences()`'s and nothing else, which is what keeps this a
-- verb rather than a capability. The values live in `app::Options` and
-- the C++ side parses, range checks and persists them, so a launcher is
-- a page of widgets over these three calls and knows nothing about the
-- file. A name outside the list is refused here rather than reaching
-- the parser, which also reads a log level the sandbox has no business
-- with.
local function a_preference(name)
	if type(name) ~= "string" then
		return false
	end
	for _, k in ipairs(__buildat_list_preferences()) do
		if k == name then
			return true
		end
	end
	return false
end
buildat.safe.list_preferences = __buildat_list_preferences
buildat.safe.get_preference = function(name)
	if not a_preference(name) then
		return nil
	end
	return __buildat_get_preference(name)
end
buildat.safe.set_preference = function(name, value)
	if not a_preference(name) then
		return false, "set_preference: no preference by that name"
	end
	if type(value) ~= "boolean" and type(value) ~= "string" and
			type(value) ~= "number" then
		return false, "set_preference(name, value): a boolean, a number " ..
				"or a string"
	end
	if type(value) == "number" then
		value = tostring(value)
	end
	return __buildat_set_preference(name, value)
end

-- **A launch extension's own second file** ([LAUNCH_SANDBOX]). Nothing
-- in the sandbox could load one: `require` reaches another extension's
-- safe interface and a module's client half, and an extension's own
-- files are neither -- so a launch UI of any size had to be one chunk,
-- or reach for `dofile` and a path. This runs one named file of the
-- calling launch extension in the sandbox and answers what it returned,
-- which is what `dofile` was being used for.
--
-- A name is one file, `.lua`, and not a path: a launcher runs its own
-- code and nobody else's.
buildat.safe.run_extension_file = function(name)
	if type(name) ~= "string" or not name:match("^[%w_%-]+%.lua$") then
		return nil, "run_extension_file(name): one .lua file, not a path"
	end
	local who = calling_extension()
	local path = __buildat_extension_path(who) .. "/" .. name
	local f = io.open(path, "rb")
	if not f then
		-- **Raised, not answered nil**: every caller would otherwise
		-- write the same assert, and a nil indexed eighty lines later
		-- names the symptom instead of the cause ([MENU_FALLBACK])
		error("run_extension_file: no " .. name .. " in " .. who, 2)
	end
	local code = f:read("*a")
	f:close()
	local status, err, ret = __buildat_run_code_in_sandbox(code,
			who .. "/" .. name)
	if not status then
		return nil, err
	end
	return ret
end

-- **The launch UIs this client has**, listed without running one:
-- an extension says it is one by shipping `launch_ui.txt`, whose first
-- line is its name for a person. Listing by loading would mean running
-- every candidate, which is the opposite of what a slot is for.
-- The launch UI that was asked for and did not load, or nil: what the
-- one that did load tells the user, so a setting cannot quietly do
-- nothing
-- **Evaluating a line of Lua, in the caller's own environment**
-- ([LAUNCH_CONSOLE]). A console whose lines each ran in a fresh
-- environment would teach something that does not transfer: `local x`
-- on one line and `x` on the next has to mean what it means everywhere
-- else. So the chunk is loaded here and given `getfenv(2)` -- the
-- sandbox wrapper of whoever called -- which is the same environment
-- the caller's own code runs in and no wider.
--
-- **Bytecode is refused**, as `run_code_in_sandbox` refuses it: a chunk
-- beginning with byte 27 is how a string-eval escapes a LuaJIT sandbox.
buildat.safe.eval = function(code, chunkname)
	if type(code) ~= "string" then
		return false, "eval(code): a string"
	end
	if code:byte(1) == 27 then
		return false, "binary bytecode prohibited"
	end
	if type(chunkname) ~= "string" then
		chunkname = "=eval"
	end
	local f, err = loadstring(code, chunkname)
	if not f then
		return false, err
	end
	setfenv(f, getfenv(2))
	local r = {pcall(f)}
	local ok = table.remove(r, 1)
	return ok, unpack(r)
end
-- **The API document**, for a launch UI that shows it beside a console
-- ([LAUNCH_CONSOLE]). One named file of the client's own documentation,
-- read-only; not a way to read files.
buildat.safe.client_api_text = function()
	local f = io.open(__buildat_get_path("share") .. "/doc/client_api.txt",
			"rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

-- **One launch UI running another over it** ([TWO_AUDIENCES]' third
-- option: the room in attract mode with the menu stacked on it). The
-- composed one is booted exactly as the client boots a launch UI --
-- sandboxed if its `launch_ui.txt` asks -- and `action` is the string
-- its `boot()` takes, which is how a room is asked for a backdrop
-- rather than a game.
--
-- **Only the listed ones**, so this names no code that is not already a
-- launch UI, and a launch UI cannot compose itself.
buildat.safe.compose_launch_ui = function(name, action)
	if type(name) ~= "string" then
		return false, "compose_launch_ui(name): a string"
	end
	if action ~= nil and (type(action) ~= "string" or
			not action:match("^[%w_/%-]*$")) then
		return false, "compose_launch_ui: an action is a plain name"
	end
	if name == calling_extension() then
		return false, "compose_launch_ui: a launch UI cannot compose itself"
	end
	local found = false
	for _, e in ipairs(buildat.safe.list_launch_uis()) do
		if e.name == name then
			found = true
		end
	end
	if not found then
		return false, "compose_launch_ui: no launch UI called " .. name
	end
	local m
	if buildat.launch_ui_sandboxed(name) then
		local f = io.open(__buildat_extension_path(name) .. "/init.lua", "rb")
		if not f then
			return false, "compose_launch_ui: no init.lua in " .. name
		end
		local code = f:read("*a")
		f:close()
		-- The chunk is named after the extension, which is what the
		-- verbs above read to know whose files and whose storage they
		-- are being asked for
		local ok, err, ret = __buildat_run_code_in_sandbox(code,
				name .. "/init.lua")
		if not ok then
			return false, err
		end
		m = ret
	else
		m = __buildat_require_extension(name)
	end
	if type(m) ~= "table" or type(m.boot) ~= "function" then
		return false, "compose_launch_ui: " .. name .. " has no boot()"
	end
	m.boot(action)
	-- A composed launch UI answers the client the same way a booted one
	-- does ([MENU_CONTEXT]): leaving a game, a dead server, whether a
	-- game is running. Without this a game launched from the menu of a
	-- composition could not be left.
	buildat.safe.provide_launch_interface(m)
	return true
end

-- **Quitting**, which is a launch UI's own verb ([LAUNCH_SANDBOX]): the
-- client shuts down. It is `disconnect()` under another name -- with no
-- connection to drop, dropping it is what leaving is -- and a launcher
-- calling `engine:Exit()` is reaching for the engine to do it.
buildat.safe.quit = function()
	__buildat_disconnect()
end
buildat.safe.launch_ui_fell_back = __buildat_launch_ui_fell_back

-- **Whose screen it is now**: the launch UI the client last booted or
-- was set to. A launch UI that is still running under another one --
-- `set_launch_ui` boots the new one over the old, and the old one's
-- handlers are still subscribed -- asks this to know that it no longer
-- holds the screen, and hands the input back ([LAUNCH_WORLD], 2026-09-24:
-- whatever holds the screen owns the input).
buildat.safe.launch_ui_name = function()
	return __buildat_menu_extension_name or "launch_menu"
end
-- The tail of a local server's log and where the whole of it is, for a
-- launcher's dialog about one that died ([START_PROGRESS]). Read-only,
-- and the path is the client's own.
buildat.safe.local_server_log_tail = __buildat_local_server_log_tail
-- Whether a launch UI asks to be run in the sandbox: a "sandboxed" line
-- in its launch_ui.txt ([LAUNCH_SANDBOX]). Trusted, and read by the
-- client's boot rather than by anything in the sandbox.
function buildat.launch_ui_sandboxed(name)
	if type(name) ~= "string" or not name:match("^[%w_]+$") then
		return false
	end
	local f = io.open(__buildat_extension_path(name) .. "/launch_ui.txt", "rb")
	if not f then
		return false
	end
	local text = f:read("*a")
	f:close()
	for line in text:gmatch("[^\r\n]+") do
		if line:match("^%s*sandboxed%s*$") then
			return true
		end
	end
	return false
end
buildat.safe.list_launch_uis = function()
	local out = {}
	for _, e in ipairs(__buildat_list_launchers()) do
		if e.kind == "extension" and type(e.path) == "string" then
			local f = io.open(e.path .. "/launch_ui.txt", "rb")
			if f then
				local text = f:read("*a")
				f:close()
				local title = text:match("^([^\r\n]*)")
				-- **"hidden" keeps it out of the list, not out of the
				-- slot**: a launch UI that exists to be tested is still
				-- selectable by name (`-m`, or the preference), and a
				-- person picking a launcher should not be offered one
				-- whose whole job is to try to break out of the sandbox.
				local hidden = false
				for line in text:gmatch("[^\r\n]+") do
					if line:match("^%s*hidden%s*$") then
						hidden = true
					end
				end
				if not hidden then
					out[#out + 1] = {name = e.name,
							title = (title ~= nil and title ~= "") and
							title or e.name}
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end
-- **Switching the launch UI**: the name is remembered and the extension
-- is booted now, so the switch is one action rather than a restart. A
-- name that is not one of the listed ones is refused here -- the
-- preference would take it, but a slot is picked from what there is.
buildat.safe.set_launch_ui = function(name)
	local found = nil
	for _, e in ipairs(buildat.safe.list_launch_uis()) do
		if e.name == name then
			found = e
		end
	end
	if not found then
		return false, "set_launch_ui: no launch UI called " .. tostring(name)
	end
	local ok, err = __buildat_set_preference("launch_ui", name)
	if not ok then
		return false, err
	end
	local m = __buildat_require_extension(name)
	if type(m) ~= "table" or type(m.boot) ~= "function" then
		return false, "set_launch_ui: " .. name .. " has no boot()"
	end
	__buildat_menu_extension_name = name
	m.boot()
	return true
end

-- The two read-only enumerations a launcher draws its room from
buildat.safe.list_games = __buildat_list_games
buildat.safe.list_saves = __buildat_list_saves
-- launch_save(game, name): open one of them. A save is the player's own
-- and the launch grid has no tile for it, so this is the one launch a
-- launcher asks for by name rather than by key ([LAUNCH_WORLD]: a save
-- is a sphere on the room's floor).
--
-- The pair has to be one list_saves() answers, so what reaches the
-- server's -u is a save that is on the disk and nothing a sandbox
-- composed. From there it is the grid's own path for a game with
-- params: the game starts and reads "save=<name>" as it would a packet.
buildat.safe.launch_save = function(game, name)
	if type(game) ~= "string" or type(name) ~= "string" then
		return false, "launch_save(game, name): two strings"
	end
	local found = false
	for _, sv in ipairs(__buildat_list_saves(game)) do
		if sv.name == name then
			found = true
			break
		end
	end
	if not found then
		return false, "launch_save(" .. game .. ", " .. name ..
				"): no such save"
	end
	local m = require("buildat/extension/launch_menu")
	if type(m) ~= "table" or type(m.start_local_game) ~= "function" then
		return false, "launch_save(): no launch_menu to start " .. game
	end
	m.start_local_game(game, "save=" .. name)
	return true
end
-- Whether the client has a local server up, which is how a launcher
-- knows a launch action started a game rather than opening a screen
buildat.safe.local_server_running = __buildat_local_server_running

-- The one preference a game may set ([BOX_FIXES] b): the player's ear.
-- Official's pause menu has mute and volume, and that is where a player
-- reaches for them. get_sound() -> mute, volume; set_sound(mute, volume)
-- -> true, or false and why. The rest of the preferences stay the
-- launcher's.
buildat.safe.get_sound = function()
	return __buildat_get_preference("sound_mute") == true,
			__buildat_get_preference("sound_volume") or 1
end
buildat.safe.set_sound = function(mute, volume)
	if type(mute) ~= "boolean" or type(volume) ~= "number" then
		return false, "set_sound(mute, volume): a boolean and a number"
	end
	local ok, err = __buildat_set_preference("sound_mute", mute)
	if not ok then
		return false, err
	end
	return __buildat_set_preference("sound_volume", tostring(volume))
end
-- The bytes of a file the server served, or nil ([BLOCKED_MODULE]): a
-- module that is busy answers no packet, and client_file is a module of its
-- own, so a table served as a file reaches the client anyway. The sandbox
-- already runs a served file as code (run_script_file); reading one's bytes
-- is no wider than that.
buildat.safe.get_file_content = function(name)
	if type(name) ~= "string" then
		return nil
	end
	return __buildat_get_file_content(name)
end
buildat.safe.set_ui_scale  = __buildat_set_ui_scale
buildat.safe.get_ui_scale  = __buildat_get_ui_scale
buildat.safe.logical_size  = __buildat_logical_size
buildat.safe.get_preferred_render_scale = __buildat_get_preferred_render_scale
buildat.safe.font_sans     = buildat.font_sans
buildat.safe.font_mono     = buildat.font_mono
buildat.safe.get_time_us   = __buildat_get_time_us
buildat.safe.version       = __buildat_version
buildat.safe.sha1          = __buildat_sha1
buildat.safe.sha256        = __buildat_sha256
buildat.safe.hex           = __buildat_hex
buildat.safe.compress      = __buildat_compress
buildat.safe.decompress    = __buildat_decompress
buildat.safe.profiler_block_begin = __buildat_profiler_block_begin
buildat.safe.profiler_block_end   = __buildat_profiler_block_end
buildat.safe.profiler_data        = __buildat_profiler_data
buildat.safe.VoxelName            = __buildat_VoxelName
buildat.safe.AtlasSegmentDefinition = __buildat_AtlasSegmentDefinition
buildat.safe.VoxelDefinition      = __buildat_VoxelDefinition
buildat.safe.createVoxelRegistry  = __buildat_createVoxelRegistry
buildat.safe.createAtlasRegistry  = __buildat_createAtlasRegistry
buildat.safe.Region        = __buildat_Region
buildat.safe.VoxelInstance = __buildat_VoxelInstance
buildat.safe.Volume        = __buildat_Volume
-- pack_voxel_volume(args): packed samples -> a serialized volume, which
-- set_voxel_geometry() and deserialize_volume() take. See doc/client_api.txt.
buildat.safe.pack_voxel_volume        = __buildat_pack_voxel_volume
buildat.safe.deserialize_volume       = __buildat_deserialize_volume
buildat.safe.deserialize_volume_int32 = __buildat_deserialize_volume_int32
buildat.safe.deserialize_volume_8bit  = __buildat_deserialize_volume_8bit
-- cast_voxel_rays(args): marches rays through voxel data. args.directions is a
-- flat array of numbers, three to a ray. With args.rays_per_cell set,
-- consecutive rays are one cell's and what comes back is their average
-- visibility per cell; without it, what every ray ran into. See the comments
-- in src/lua_bindings/voxel_volume.cpp.
buildat.safe.cast_voxel_rays          = __buildat_cast_voxel_rays
-- cast_voxel_rays_start(args) takes what cast_voxel_rays() takes and returns a
-- handle; cast_voxel_rays_collect(handle) returns nil until the marching has
-- finished on a worker thread, and then what cast_voxel_rays() would have
-- returned. The volumes and the registry are held for the job's lifetime, so a
-- chunk arriving meanwhile does not pull data out from under it.
buildat.safe.cast_voxel_rays_start    = __buildat_cast_voxel_rays_start
buildat.safe.cast_voxel_rays_collect  = __buildat_cast_voxel_rays_collect
-- write_floats(vector_buffer, values): the values into the buffer as floats,
-- replacing what was in it
buildat.safe.write_floats             = __buildat_write_floats
-- add_resource_dir(path) and compose_image(args), in the sandbox as they
-- are (decided 2026-09-13). What they give sandboxed code is "write files
-- under the cache and make them loadable", which a server can already do
-- through client_file -- it ships whatever files it likes into the same
-- cache -- so this adds no power that was not already there. What it does
-- do is make the cache-path check in each of them load-bearing rather than
-- a sanity check: anything added beside them writes under the cache or it
-- does not go in the sandbox. See doc/plan/luanti_module_plan.md, "what a
-- module's client half is allowed to do".
buildat.safe.add_resource_dir         = __buildat_add_resource_dir
buildat.safe.compose_image            = __buildat_compose_image
-- take_screenshot() -> the name of the file it went into, or nil and why
-- not. **The caller says when and nothing else**: the client picks the
-- directory and the name, so sandboxed code cannot choose a path, cannot
-- read what it wrote and cannot overwrite an existing shot. What it can do
-- is fill <user>/screenshots, which is what the screenshot key already does.
-- The file lands at the end of the frame; the name is reserved before this
-- returns. See l_take_screenshot() in src/client/app.cpp.
buildat.safe.take_screenshot          = __buildat_take_screenshot
buildat.safe.dump_meshes              = __buildat_dump_meshes
-- get_env(name) -> the variable, or nil. Only BUILDAT_-prefixed names, so a
-- server's Lua cannot read the user's environment; what it is for is a knob
-- a harness sets on the client's process, such as the rendering mode. See
-- l_get_env() in src/client/app.cpp.
buildat.safe.get_env                  = __buildat_get_env
-- get_cache_path() -> the directory those two work in. The share and user
-- paths stay out of the sandbox; this is here because writing a file under
-- the cache means knowing where the cache is.
buildat.safe.get_cache_path           = function()
	return __buildat_get_path("cache")
end
-- What stopped a ray cast by cast_voxel_rays(); see its comment in
-- src/lua_bindings/voxel_volume.cpp
buildat.safe.VOXEL_RAY = {
	BLOCKED  = 0, -- Ran into something not passable
	NO_DATA  = 1, -- Left the volumes it was given
	RANGE    = 2, -- Used up max_steps
	SKYLIGHT = 3, -- Reached the stop_skylight it was given
}

-- NOTE: Maybe not actually safe
--buildat.safe.class_info = class_info -- Luabind class_info()

buildat.safe.SpatialUpdateQueue = function()
	local internal = __buildat_SpatialUpdateQueue()
	return {
		update = function(self, ...)
			return internal:update(...)
		end,
		set_p = function(self, ...)
			return internal:set_p(...)
		end,
		-- `player` is "the player caused this"; it rides into the queue
		-- and puts the item before the world's own churn ([CLIENT_FRAME])
		put = function(self, safe_p, near_weight, near_trigger_d,
				far_weight, far_trigger_d, value, player)
			if not getmetatable(safe_p) or
					getmetatable(safe_p).type_name ~= "Vector3" then
				error("p is not a sandboxed Vector3 instance")
			end
			p = getmetatable(safe_p).unsafe
			return internal:put(p, near_weight, near_trigger_d,
					far_weight, far_trigger_d, value, player)
		end,
		get = function(self, ...)
			return internal:get(...)
		end,
		peek_next_f = function(self, ...)
			return internal:peek_next_f(...)
		end,
		peek_next_fw = function(self, ...)
			return internal:peek_next_fw(...)
		end,
		peek_next_value = function(self, ...)
			return internal:peek_next_value(...)
		end,
		find = function(self, ...)
			return internal:find(...)
		end,
		get_length = function(self, ...)
			return internal:get_length(...)
		end,
		is_sorting = function(self)
			return internal:is_sorting()
		end,
		set_p = function(self, safe_p)
			if not getmetatable(safe_p) or
					getmetatable(safe_p).type_name ~= "Vector3" then
				error("p is not a sandboxed Vector3 instance")
			end
			p = getmetatable(safe_p).unsafe
			internal:set_p(p)
		end,
		-- Which way the camera looks, for the queue's view term. **A
		-- method the C++ has and this table does not is a nil call that
		-- kills the handler it is in** (2026-09-26: set_dir raised every
		-- frame, voxelworld's whole update went with it and 3024 chunks
		-- stood undrawn).
		set_dir = function(self, safe_dir)
			if not getmetatable(safe_dir) or
					getmetatable(safe_dir).type_name ~= "Vector3" then
				error("dir is not a sandboxed Vector3 instance")
			end
			internal:set_dir(getmetatable(safe_dir).unsafe)
		end,
	}
end

-- TODO: Implement sandbox unwrapping in C++ and remove these from here
--       (already done in lua_bindings/voxel.cpp)

function buildat.safe.set_simple_voxel_model(safe_node, w, h, d, safe_buffer)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end

	__buildat_set_simple_voxel_model(node, w, h, d, buffer)
end

-- voxel_reg, atlas_reg, and then where this block's (0, 0, 0) sits in the
-- world, which is what a voxel of uv_scale > 1 takes its slice of the
-- repeat from ([WORLD_UV]). No origin is the old behaviour, the block
-- standing at the world's own zero.
function buildat.safe.set_8bit_voxel_geometry(safe_node, w, h, d, safe_buffer,
		voxel_reg, atlas_reg, ox, oy, oz)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_8bit_voxel_geometry(node, w, h, d, buffer,
			voxel_reg, atlas_reg, ox or 0, oy or 0, oz or 0)
end

function buildat.safe.set_voxel_geometry(safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_geometry(node, buffer, ...)
end

-- set_voxel_data(node, data): a chunk node's voxel data from a serialized
-- volume, for a predicted dig or place; see src/lua_bindings/misc_urho3d.cpp
function buildat.safe.set_voxel_data(safe_node, data)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(data) ~= "string" then
		error("data is not a string")
	end
	__buildat_set_voxel_data(getmetatable(safe_node).unsafe, data)
end

-- get_voxel_data(node) -> string: the same var as it is
function buildat.safe.get_voxel_data(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	return __buildat_get_voxel_data(getmetatable(safe_node).unsafe)
end

-- column_heights(buffer, voxel_reg) -> string; see src/lua_bindings/mesh.cpp
function buildat.safe.column_heights(safe_buffer, ...)
	local buffer
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	return __buildat_column_heights(buffer, ...)
end

function buildat.safe.set_voxel_lod_geometry(lod, safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_lod_geometry(lod, node, buffer, ...)
end

function buildat.safe.set_quad_geometry(safe_node, quads)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(quads) ~= "table" then
		error("quads is not a table")
	end
	return __buildat_set_quad_geometry(getmetatable(safe_node).unsafe, quads)
end

function buildat.safe.clear_voxel_geometry(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	__buildat_clear_voxel_geometry(node)
end

function buildat.safe.set_voxel_physics_boxes(safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_physics_boxes(node, buffer, ...)
end

function buildat.safe.clear_voxel_physics_boxes(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	__buildat_clear_voxel_physics_boxes(node)
end

local Vector3_prototype = {
	x = 0,
	y = 0,
	z = 0,
	dump = function(a)
		return "("..a.x..", "..a.y..", "..a.z..")"
	end,
	eq = function(a, b)
		return (a.x == b.x and a.y == b.y and a.z == b.z)
	end,
	mul_components = function(a, b)
		return buildat.safe.Vector3(
				a.x * b.x, a.y * b.y, a.z * b.z)
	end,
	div_components = function(a, b)
		return buildat.safe.Vector3(
				a.x / b.x, a.y / b.y, a.z / b.z)
	end,
	floor = function(a)
		return buildat.safe.Vector3(
				math.floor(a.x), math.floor(a.y), math.floor(a.z))
	end,
	round = function(a)
		return buildat.safe.Vector3(
				math.floor(a.x+0.5), math.floor(a.y+0.5), math.floor(a.z+0.5))
	end,
	add = function(a, b)
		return buildat.safe.Vector3(
				a.x + b.x, a.y + b.y, a.z + b.z)
	end,
	sub = function(a, b)
		return buildat.safe.Vector3(
				a.x - b.x, a.y - b.y, a.z - b.z)
	end,
	mul = function(a, b)
		return buildat.safe.Vector3(
				a.x * b, a.y * b, a.z * b)
	end,
	div = function(a, b)
		return buildat.safe.Vector3(
				a.x / b, a.y / b, a.z / b)
	end,
	length = function(a)
		return math.sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
	end,
}
function buildat.safe.Vector3(x, y, z)
	local self = {}
	if x ~= nil and y == nil and z == nil then
		assert(type(x.x) == "number" and type(x.y) == "number" and
				type(x.z) == "number")
		self.x = x.x
		self.y = x.y
		self.z = x.z
	else
		self.x = x
		self.y = y
		self.z = z
	end
	setmetatable(self, {
		__index = Vector3_prototype,
		__eq = Vector3_prototype.eq,
		__add = Vector3_prototype.add,
		__sub = Vector3_prototype.sub,
		__mul = Vector3_prototype.mul,
		__div = Vector3_prototype.div,
	})
	return self
end

local Vector2_prototype = {
	x = 0,
	y = 0,
	dump = function(a)
		return "("..a.x..", "..a.y..")"
	end,
	eq = function(a, b)
		return (a.x == b.x and a.y == b.y)
	end,
	mul_components = function(a, b)
		return buildat.safe.Vector2(
				a.x * b.x, a.y * b.y)
	end,
	div_components = function(a, b)
		return buildat.safe.Vector2(
				a.x / b.x, a.y / b.y)
	end,
	floor = function(a)
		return buildat.safe.Vector2(
				math.floor(a.x), math.floor(a.y))
	end,
	round = function(a)
		return buildat.safe.Vector2(
				math.floor(a.x+0.5), math.floor(a.y+0.5))
	end,
	add = function(a, b)
		return buildat.safe.Vector2(
				a.x + b.x, a.y + b.y)
	end,
	sub = function(a, b)
		return buildat.safe.Vector2(
				a.x - b.x, a.y - b.y)
	end,
	mul = function(a, b)
		return buildat.safe.Vector2(
				a.x * b, a.y * b)
	end,
	div = function(a, b)
		return buildat.safe.Vector2(
				a.x / b, a.y / b)
	end,
	length = function(a)
		return math.sqrt(a.x*a.x + a.y*a.y)
	end,
}
function buildat.safe.Vector2(x, y)
	local self = {}
	if x ~= nil and y == nil then
		assert(type(x.x) == "number" and type(x.y) == "number")
		self.x = x.x
		self.y = x.y
	else
		self.x = x
		self.y = y
	end
	setmetatable(self, {
		__index = Vector2_prototype,
		__eq = Vector3_prototype.eq,
		__add = Vector2_prototype.add,
		__sub = Vector2_prototype.sub,
		__mul = Vector2_prototype.mul,
		__div = Vector2_prototype.div,
	})
	return self
end

-- vim: set noet ts=4 sw=4:
