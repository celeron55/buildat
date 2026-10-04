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
buildat.list_apps        = __buildat_list_apps
-- list_saves([app]) -> {{app=, name=, modified=}, ...}, newest first.
-- The saves on disk, enumerated without a server, since a launcher has
-- none to ask ([LAUNCH_WORLD]).
buildat.list_saves        = __buildat_list_saves
-- list_launchers() -> {{kind, name, path, launcher = bool}, ...}: every
-- game, builtin and extension in the tree, for the launch grid
buildat.list_launchers    = __buildat_list_launchers
-- list_installed_games(app) -> {{name =, size =, icon =}, ...} under
-- <user>/shared/<app>/games ("vanilla": the Luanti games); read-only, and in the sandbox too, for a launcher
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
buildat.qr_code           = __buildat_qr_code
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
-- save_file, exported_files, read_exported, pick_file, picked_file: files a
-- game hands the user and takes from them; buildat.safe's below has no
-- listing or reading of <user>/exports
buildat.save_file         = __buildat_save_file
buildat.exported_files    = __buildat_exported_files
buildat.read_exported     = __buildat_read_exported
buildat.pick_file         = __buildat_pick_file
buildat.picked_file       = __buildat_picked_file
-- dump_meshes([atlas_json], [node]) -> the file name, or nil and why not. Same sandbox rule
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
buildat.safe.set_reload_on_return = __buildat_set_reload_on_return
buildat.safe.set_web_fullscreen = __buildat_set_web_fullscreen
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
local LAUNCH_INTERFACE = {entered_app = true, leave_app = true,
	in_app = true, show_dead_server = true, app_loading = true,
	-- [AITTA_MVP]: the grid drawn again after an install
	refresh = true}
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

-- **A game says when it stops being a menu and starts being a world**
-- ([LAUNCH_API]'s fourth ask, user 2026-09-28). A game launched into a
-- menu of its own -- vanilla's save list, its server screen -- is on the
-- screen for as long as the player takes to choose, and a launch UI that
-- paused an animation for it has no way of knowing when the choosing is
-- over. The heuristics it has are the viewport handover and the local
-- server coming up, and both are late and neither says which happened.
--
-- launch_loading(what): `what` is "world" or "server", anything else is
-- refused. Nothing but the launch UI hears it, and a launch UI that
-- provides no `app_loading` is not an error -- most will not want one.
buildat.safe.launch_loading = function(what)
	if what ~= "world" and what ~= "server" then
		return false, 'launch_loading(what): "world" or "server"'
	end
	log:info("launch: the game is loading a " .. what)
	local m = buildat.menu_extension()
	if m and m.app_loading then
		m.app_loading(what)
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
	if m and m.leave_app then
		m.leave_app()
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
local launch_grid = dofile(__buildat_get_path("share") ..
		"/client/launch_grid.lua")

-- **A launch history, kept once for every launch UI** ([LAUNCH_API]).
-- The API knew a save's modified time and nothing about what was
-- launched when, so each launcher that wanted "recently played" had to
-- keep a list of its own -- and a list per launcher is a list that
-- disagrees with the next one. One line per key in
-- <user>/launch_history.csv, "<unix seconds> <key>", and the oldest
-- dropped past the cap: what was launched when is not worth more than
-- a small file.
local LAUNCH_HISTORY_MAX = 200
local function launch_history_read()
	local out = {}
	local f = io.open(__buildat_get_path("user") .. "/launch_history.csv", "r")
	if not f then
		return out
	end
	for line in f:lines() do
		local t, key = line:match("^(%d+) (.+)$")
		if key then
			out[key] = tonumber(t)
		end
	end
	f:close()
	return out
end
local function launch_history_note(key)
	-- A key is written a line at a time, so one with a newline or a
	-- control character in it would write a line this cannot read back
	if key:find("%c") then
		return
	end
	local seen = launch_history_read()
	seen[key] = os.time()
	local rows = {}
	for k, t in pairs(seen) do
		rows[#rows + 1] = {k = k, t = t}
	end
	table.sort(rows, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return a.k < b.k
	end)
	local f = io.open(__buildat_get_path("user") .. "/launch_history.csv", "w")
	if not f then
		log:warning("launch: cannot write the launch history")
		return
	end
	for i = 1, math.min(#rows, LAUNCH_HISTORY_MAX) do
		f:write(rows[i].t .. " " .. rows[i].k .. "\n")
	end
	f:close()
end

buildat.safe.launch_actions = function()
	local out = {}
	local history = launch_history_read()
	launch_runs = {}
	for i, a in ipairs(launch_grid.actions(log)) do
		local key = tostring(a.from) .. "/" .. tostring(a.id or i)
		launch_runs[key] = a.run
		out[i] = {key = key, id = a.id, label = a.label, icon = a.icon,
			kind = a.kind, from = a.from, description = a.description,
			order = a.order,
			-- What the action says about itself ([LAUNCH_SIGNIFY]): the
			-- category is an open set and the significance a number to
			-- rank and scale by within one. Both are plain data and both
			-- may be absent.
			category = a.category, significance = a.significance,
			-- When this key was last launched, in unix seconds, or
			-- absent for one that never was
			last_launched = history[key]}
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
	launch_history_note(key)
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
-- And the names: a server's script writing a new one in a loop filled
-- the disk 4 MiB at a time ([SECURITY_RUN_1])
local STORAGE_FILES_MAX = 64

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
	local name = src:match("^@?([%w_]+)/[%w_%-%.]+$") or
			src:match("^@?([%w_]+)/[%w_%-]+/[%w_%-%.]+$")
	if name then
		return name
	end
	-- **And a trusted one is a path on disk**, which is what an
	-- extension required by another extension is: the menu, required
	-- by another, asked for its `preferences.lua` in the other's
	-- directory, found nothing, answered nil, and the client aborted
	-- eighty lines later ([MENU_FALLBACK], 2026-09-23). The same fault
	-- the composition found, in the other direction.
	name = src:match("[/\\]extensions[/\\]([%w_]+)[/\\]")
	if name then
		return name
	end
	return __buildat_menu_extension_name or "launch_menu"
end

-- The chunks servers served, by name (sandbox.lua's run_script_file)
__buildat_served_chunks = {}

-- Whose storage a call is in: "server" for game code a server sent, or the
-- launch extension's name. 1 is this, 2 the verb, 3 who called it.
local function storage_domain()
	local info = debug.getinfo(3, "S")
	if __buildat_served_chunks[info and info.source or ""] then
		return "server"
	end
	return calling_extension(4)
end

local function storage_path(name, domain)
	if type(name) ~= "string" or not name:match("^[%w_%-%.]+$") or
			name:find("%.%.") then
		return nil, "storage: a name of letters, digits, _ - and ."
	end
	-- **Game code a server sent** keeps its things where the server's
	-- game_storage_dir() says, like a web page's localStorage: a game
	-- started here has its game's, anything else its address's. A server's
	-- chunks have a buildat of their own that says so (sandbox.lua's
	-- __buildat_run_served_code); a launch extension is told by its
	-- chunk's name.
	if domain == "server" then
		local dir = __buildat_game_storage_dir()
		if not dir then
			return nil, "storage: not connected to a server"
		end
		return dir .. "/" .. name, dir
	end
	if not domain:match("^[%w_]+$") then
		return nil, "storage: the launch extension has an odd name"
	end
	return __buildat_get_path("user") .. "/" .. domain .. "/" .. name,
			__buildat_get_path("user") .. "/" .. domain
end
local function storage_read_in(name, domain)
	local path = storage_path(name, domain)
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
local function storage_write_in(name, data, domain)
	local path, dir = storage_path(name, domain)
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
	local old = io.open(path, "rb")
	if old then
		old:close()
	elseif __buildat_count_files(dir) >= STORAGE_FILES_MAX then
		return false, "storage_write: " .. STORAGE_FILES_MAX ..
				" names are kept already"
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
buildat.safe.storage_read = function(name)
	local domain = storage_domain()
	return storage_read_in(name, domain)
end
buildat.safe.storage_write = function(name, data)
	local domain = storage_domain()
	return storage_write_in(name, data, domain)
end

-- **What a server's chunks get instead** ([SECURITY_RUN_1]): the gates
-- below read the calling frame, and a tail call or a verb passed as a
-- callback leaves no frame of the server's to read -- `return
-- buildat.set_preference(...)` at a chunk's top set any preference. So a
-- chunk a server sent is run with a buildat of its own
-- (sandbox.lua's __buildat_run_served_code), in which the user's verbs
-- refuse whoever is on the stack and storage is the server's.
local function refused(verb)
	return function()
		return false, verb .. ": the user's, not a server's"
	end
end
__buildat_served_overrides = {
	set_preference = refused("set_preference"),
	start_local_server = refused("start_local_server"),
	stop_local_server = refused("stop_local_server"),
	launch = refused("launch"),
	launch_save = refused("launch_save"),
	set_launch_ui = refused("set_launch_ui"),
	compose_launch_ui = refused("compose_launch_ui"),
	cache_read = function() return nil end,
	cache_write = refused("cache_write"),
	storage_read = function(name)
		return storage_read_in(name, "server")
	end,
	storage_write = function(name, data)
		return storage_write_in(name, data, "server")
	end,
}

-- **An extension's cache** ([EXTENSIONS_SANDBOXED]): files under
-- <cache>/<extension>/, which is also a place add_resource_dir() takes,
-- so what is written can be loaded by name. A name is up to three
-- segments of letters, digits, _ - and . ("server/composed/x.png").
-- simplified: a cap per file and none on the whole; compose_image()
-- already writes under the cache without one.
local CACHE_FILE_MAX = 32 * 1024 * 1024
local function cache_path(name)
	if type(name) ~= "string" or #name > 256 or name:find("%.%.") or
			not (name:match("^[%w_%-%.]+$") or
				name:match("^[%w_%-%.]+/[%w_%-%.]+$") or
				name:match("^[%w_%-%.]+/[%w_%-%.]+/[%w_%-%.]+$")) then
		return nil, "cache: a name of up to three segments of letters, " ..
				"digits, _ - and ."
	end
	-- 1 is this, 2 cache_read or cache_write, 3 who called that. **Not
	-- a server's**: a module named like an extension would be writing
	-- that extension's media.
	local info = debug.getinfo(3, "S")
	if __buildat_served_chunks[info and info.source or ""] then
		return nil, "cache: an extension's, not a server's"
	end
	local who = calling_extension(4)
	local root = __buildat_get_path("cache") .. "/" .. who
	local path = root .. "/" .. name
	return path, path:match("^(.*)/[^/]+$")
end
buildat.safe.cache_read = function(name)
	local path = cache_path(name)
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
buildat.safe.cache_write = function(name, data)
	local path, dir = cache_path(name)
	if not path then
		return false, dir
	end
	if type(data) ~= "string" then
		return false, "cache_write(name, data): data is a string"
	end
	if #data > CACHE_FILE_MAX then
		return false, "cache_write: " .. #data .. " bytes is over the " ..
				CACHE_FILE_MAX .. " a file may have"
	end
	__buildat_create_directories(dir)
	local f = io.open(path, "wb")
	if not f then
		return false, "cache_write: could not open " .. name
	end
	f:write(data)
	f:close()
	return true
end

-- **Connecting to a server**, which a launcher does on a worker and
-- polls from a frame handler: the blocking one freezes the frame for as
-- long as it takes ([BOX_PLAYTEST_2] 12). An address is a string and
-- the client is what parses it.
local feedback = nil
buildat.safe.connect_start = function(address)
	if type(address) ~= "string" or #address > 256 then
		return false, "connect_start(address): a string"
	end
	if feedback and feedback.address ~= address then
		feedback = nil
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
-- **"Feedback..." on an installed app** ([PACKAGE_SUBJECT]): the grid
-- (trusted) sets what the user is about to tell the app's home Hearth
-- and connects there; the Hearth's client takes it once -- the package,
-- its version, this engine's and the platform, nothing else. A connect
-- to another address drops it.
buildat.set_feedback = function(f)
	feedback = f
end
-- feedback() -> {subject, package, version, engine, platform} or nil
buildat.safe.feedback = function()
	local f = feedback
	feedback = nil
	return f and {subject = f.subject, package = f.package,
			version = f.version, engine = f.engine, platform = f.platform}
end
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
	-- **Read by apps, set by the user**: a chunk a server sent may read
	-- a preference (a game's name field offers default_username) and may
	-- not write one; a launch extension, which is the user's, may
	local info = debug.getinfo(2, "S")
	if info and __buildat_served_chunks[info.source] then
		return false, "set_preference: the user's, not a server's"
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
-- A name is one file, `.lua`, or one in a subdirectory (`res/x.lua`),
-- and not a path: an extension runs its own code and nobody else's.
buildat.safe.run_extension_file = function(name)
	if type(name) ~= "string" or not (name:match("^[%w_%-]+%.lua$") or
			name:match("^[%w_%-]+/[%w_%-]+%.lua$")) then
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
	-- **The chunk is the caller's, by name too**: every gate that tells a
	-- server's code from the user's -- set_preference, storage, the local
	-- server -- reads the calling chunk's name, so a name of the caller's
	-- choosing was a way to be someone else ([SECURITY_RUN_1]). The name
	-- asked for is only what an error message says.
	local info = debug.getinfo(2, "S")
	local own = info and info.source or "=eval"
	local f, err = loadstring(code, own)
	local function shown(e)
		if type(chunkname) ~= "string" or type(e) ~= "string" then
			return e
		end
		local short = info and info.short_src or ""
		if short ~= "" and e:sub(1, #short) == short then
			return chunkname:gsub("^[=@]", "") .. e:sub(#short + 1)
		end
		return e
	end
	if not f then
		return false, shown(err)
	end
	setfenv(f, getfenv(2))
	local r = {pcall(f)}
	local ok = table.remove(r, 1)
	if not ok then
		r[1] = shown(r[1])
	end
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
local function launch_ui_says(name, word)
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
		if line:match("^%s*" .. word .. "%s*$") then
			return true
		end
	end
	return false
end
function buildat.launch_ui_sandboxed(name)
	return launch_ui_says(name, "sandboxed")
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
-- The launch UIs booted in this client, the one it started with too
local booted_launch_uis = {}
buildat.safe.set_launch_ui = function(name)
	booted_launch_uis[__buildat_menu_extension_name or "launch_menu"] = true
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
	-- **A "persistent" launch UI is booted once**: the room keeps running
	-- under another launch UI and takes the screen back by itself, so a
	-- second boot was a second room with every key acted on twice
	-- (2026-10-03). The stack is cleared and the name taken all the same.
	local again = booted_launch_uis[name] and launch_ui_says(name, "persistent")
	local m = nil
	if not again then
		m = __buildat_require_extension(name)
		if type(m) ~= "table" or type(m.boot) ~= "function" then
			return false, "set_launch_ui: " .. name .. " has no boot()"
		end
	end
	-- **Nothing of the old one's stays on the screen** ([LAUNCH_WORLD]
	-- stage 2, 2026-10-03): the switch is often made from the old one's
	-- own settings window, which was left drawn over the new one and
	-- kept the input. Everything on the main stack is the old launch
	-- UI's, so all of it goes before the new one boots.
	local us = __buildat_require_extension("uistack")
	local stack = us and us.main and us.main.stack
	if stack and stack[1] then
		local ok_pop, why = pcall(function()
			us.main:pop_to(stack[1], true)
		end)
		if not ok_pop then
			log:warning("set_launch_ui: clearing the stack: " .. tostring(why))
		end
	end
	__buildat_menu_extension_name = name
	booted_launch_uis[name] = true
	if again then
		log:info("set_launch_ui: " .. name .. " is running; it has the screen again")
	else
		m.boot()
	end
	return true
end

-- The two read-only enumerations a launcher draws its room from
buildat.safe.list_apps = __buildat_list_apps
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
	launch_grid.screens().start_local_app(game, "save=" .. name)
	return true
end
-- Whether the client has a local server up, which is how a launcher
-- knows a launch action started a game rather than opening a screen
buildat.safe.local_server_running = __buildat_local_server_running

-- **The local server, for the screens a game is started through**
-- (extensions/launch_menu/screens.lua, which runs in the sandbox). The
-- user's and not a server's: a chunk a server sent may not start, stop
-- or kill a process on this machine.
local function from_served()
	-- 1 is this, 2 the verb, 3 who called it
	local info = debug.getinfo(3, "S")
	return info ~= nil and __buildat_served_chunks[info.source] ~= nil
end
-- start_local_server(game[, launch]) -> true, or false and why. game is
-- one list_apps() answers; launch is key=value lines for the server's
-- -u, a key of a name's shape, which the module reads as it would a
-- packet.
buildat.safe.start_local_server = function(game, launch)
	if from_served() then
		return false, "start_local_server: the user's, not a server's"
	end
	local found = false
	for _, g in ipairs(__buildat_list_apps()) do
		if g.name == game then
			found = true
		end
	end
	if not found then
		return false, "start_local_server: no app called " .. tostring(game)
	end
	if launch ~= nil then
		if type(launch) ~= "string" or #launch > 4096 then
			return false, "start_local_server: launch is a string"
		end
		for line in launch:gmatch("[^\n]+") do
			if not line:match("^[%w_]+=[^\r]*$") then
				return false, "start_local_server: a launch line is key=value"
			end
		end
	end
	return __buildat_start_local_server(game, launch)
end
-- stop_local_server(force): asks it to stop, or kills it with force
buildat.safe.stop_local_server = function(force)
	if from_served() then
		return false, "stop_local_server: the user's, not a server's"
	end
	if force == true then
		__buildat_force_kill_local_server()
	else
		__buildat_request_stop_local_server()
	end
	return true
end
-- local_server_state() -> port or nil, status: the port once it
-- answers, and the last status line of its log
-- lan_address() -> "a.b.c.d" or nil: this machine's address on the LAN,
-- only while connected to the server this client started (the pause
-- menu's "Open to LAN" says it)
buildat.safe.lan_address = __buildat_lan_address
-- lan_servers() -> {{host, port, name, app, version, players, account},
-- ...}: the games announcing themselves on this network, heard within
-- 6 s ([LAN_DISCOVERY]); empty while connected to a server. Ask it every
-- second or so while the list is on the screen.
buildat.safe.lan_servers = __buildat_lan_servers

buildat.safe.local_server_state = function()
	local port = __buildat_local_server_ready() and
			__buildat_local_server_port() or nil
	return port, __buildat_local_server_status()
end

-- The one preference a game may set ([BOX_FIXES] b): the player's ear.
-- Official's pause menu has mute and volume, and that is where a player
-- reaches for them. get_sound() -> mute, db; set_sound(mute, db) ->
-- true, or false and why. The rest of the preferences stay the
-- launcher's.
--
-- **The volume is decibels below full** ([VOLUME_LAW], user
-- 2026-09-28): 0 is full, -3, -6 and so on are the steps a setting
-- offers, and -33 or less is off. A game shows it in those units; the
-- gain is made from it in the client, in the one place it is applied.
buildat.safe.get_sound = function()
	return __buildat_get_preference("sound_mute") == true,
			__buildat_get_preference("sound_volume_db") or 0
end
buildat.safe.set_sound = function(mute, db)
	if type(mute) ~= "boolean" or type(db) ~= "number" then
		return false, "set_sound(mute, db): a boolean and decibels"
	end
	local ok, err = __buildat_set_preference("sound_mute", mute)
	if not ok then
		return false, err
	end
	return __buildat_set_preference("sound_volume_db", tostring(db))
end
-- **The render scale, the other preference a game may set** (user,
-- 2026-09-30): the web client has no launcher to reach Engine settings
-- through, so a game's own settings carry it. What the game gets to set
-- is how much its frame costs, never what is in it.
-- get_render_scale() -> share, automatic; set_render_scale(share or
-- "auto") -> true, or false and why. "auto" is the client's own choice,
-- made again on each start and resize.
buildat.safe.get_render_scale = function()
	return __buildat_get_preferred_render_scale(),
			__buildat_get_preference("render_scale") == "auto"
end
buildat.safe.set_render_scale = function(v)
	if type(v) ~= "number" and v ~= "auto" then
		return false, "set_render_scale(share): a number or \"auto\""
	end
	return __buildat_set_preference("render_scale", tostring(v))
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
buildat.safe.get_local_time = __buildat_get_local_time
buildat.safe.version       = __buildat_version
buildat.safe.sha1          = __buildat_sha1
buildat.safe.sha256        = __buildat_sha256
-- qr_code(text) -> the QR code's modules as a string of "0" and "1", row
-- by row from the top, and its side; or nil. Reads and writes nothing:
-- a TOTP secret's otpauth:// link for an authenticator app ([STARPORT] 10a)
buildat.safe.qr_code       = __buildat_qr_code
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
-- **Files a game hands the user and takes from them** ([FP_EXPORT] 4), the
-- same rule as take_screenshot: the client picks where. On native,
-- <user>/exports; on the web, the browser's download and file picker.
--   save_file(name, data) -> the path it went to ("" for a download), or
--       nil and why not; never overwrites
--   pick_file([accept]) -> true: the web's file picker, or on native the
--       client's own list of <user>/exports (extension/network)
--   picked_file() -> name, data once the picked file is read, else nil;
--       nil and why once the user picked nothing or it could not be read
-- **No listing or reading of <user>/exports** ([SECURITY_RUN_1]): every
-- server's game exports there, so a game that read it all read another
-- server's plans; it gets the file the user picks.
-- Files are at most 64 MiB. See l_save_file() in src/client/app.cpp.
buildat.safe.save_file                = __buildat_save_file
local picked_export = nil
buildat.safe.pick_file = function(accept)
	if __buildat_pick_file(accept) then
		return true
	end
	picked_export = nil
	__buildat_require_extension("network").pick_export(
			type(accept) == "string" and accept or "", function(name, data)
		picked_export = {name, data}
	end)
	return true
end
buildat.safe.picked_file = function()
	local p = picked_export
	if p then
		picked_export = nil
		return p[1], p[2]
	end
	return __buildat_picked_file()
end
-- dump_meshes([atlas_json], [node]): node, a sandboxed Node, dumps what is
-- under it rather than the replicated scene
function buildat.safe.dump_meshes(atlas, safe_node)
	if safe_node ~= nil then
		if not getmetatable(safe_node) or
				getmetatable(safe_node).type_name ~= "Node" and
				getmetatable(safe_node).type_name ~= "Scene" then
			error("node is not a sandboxed Node instance")
		end
		return __buildat_dump_meshes(atlas, getmetatable(safe_node).unsafe)
	end
	return __buildat_dump_meshes(atlas)
end
-- get_env(name) -> the variable, or nil. Only BUILDAT_-prefixed names, so a
-- server's Lua cannot read the user's environment; what it is for is a knob
-- a harness sets on the client's process, such as the rendering mode. See
-- l_get_env() in src/client/app.cpp.
buildat.safe.get_env                  = __buildat_get_env
-- get_locale() -> the user's language as the environment says it
-- (LANGUAGE, LC_ALL, LC_MESSAGES, LANG, the first set), or ""
buildat.safe.get_locale = function()
	for _, k in ipairs({"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}) do
		local v = os.getenv(k)
		if v and v ~= "" then
			return v
		end
	end
	return ""
end
-- Harmless in the sandbox ([EXTENSIONS_SANDBOXED]): bytes from the
-- system's generator, arithmetic on byte strings, and the pixels of a
-- resource the sandbox could already load
buildat.safe.random_bytes = buildat.random_bytes
buildat.safe.bignum = buildat.bignum
buildat.safe.read_image = buildat.read_image
-- The cereal extension's two bindings ([EXTENSIONS_SANDBOXED]): a byte
-- string and a type list in, values out, or the reverse
buildat.safe.cereal_binary_input = function(data, types)
	if type(data) ~= 'string' then
		error("data not string")
	end
	if type(types) ~= 'table' then
		error("types not table")
	end
	return __buildat_cereal_binary_input(data, types)
end
buildat.safe.cereal_binary_output = function(values, types)
	if type(values) ~= 'table' then
		error("values not table")
	end
	if type(types) ~= 'table' then
		error("types not table")
	end
	return __buildat_cereal_binary_output(values, types)
end
-- connection_encrypted() -> whether the server connection is under TLS:
-- a web client on an https page, or a native one joined by https://
buildat.safe.connection_encrypted = function()
	local a = __buildat_server_address() or ""
	return __buildat_get_env("BUILDAT_PAGE_HTTPS") == "1" or
			a:match("^https://") ~= nil or a:match("^wss://") ~= nil
end
-- server_address() -> the address the server was joined by, as it was given
-- ("host:port", "https://host:port"); nil when not joined
buildat.safe.server_address = function()
	return __buildat_server_address()
end
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

-- set_triangle_geometry(node, verts): a triangle list, 12 numbers a vertex
-- (position, normal, colour, texture coordinate), as the node's
-- CustomGeometry; see src/lua_bindings/mesh.cpp
function buildat.safe.set_triangle_geometry(safe_node, verts)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(verts) ~= "table" then
		error("verts is not a table")
	end
	-- Anything not a number reads as 0 in the engine (lua_tonumber)
	return __buildat_set_triangle_geometry(getmetatable(safe_node).unsafe, verts)
end

-- set_image_data(image, values): all of an Image's bytes from a flat list
-- of numbers from 0 to 1, rows from the top; see src/lua_bindings/mesh.cpp
function buildat.safe.set_image_data(safe_image, values)
	if not getmetatable(safe_image) or
			getmetatable(safe_image).type_name ~= "Image" then
		error("image is not a sandboxed Image instance")
	end
	if type(values) ~= "table" then
		error("values is not a table")
	end
	return __buildat_set_image_data(getmetatable(safe_image).unsafe, values)
end

-- set_line_geometry(node, verts): a line list, 7 numbers a vertex
-- (position, colour), as the node's CustomGeometry; see
-- src/lua_bindings/mesh.cpp
function buildat.safe.set_line_geometry(safe_node, verts)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(verts) ~= "table" then
		error("verts is not a table")
	end
	return __buildat_set_line_geometry(getmetatable(safe_node).unsafe, verts)
end

-- set_cell_geometry(node, cells, size, r, g, b, a, v): a volume of cubic
-- cells as the node's CustomGeometry, v the texture coordinate's second
-- half on every vertex (0 unless given); see src/lua_bindings/mesh.cpp
function buildat.safe.set_cell_geometry(safe_node, cells, size, r, g, b, a, v)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(cells) ~= "table" or type(size) ~= "number" then
		error("cells is not a table or size is not a number")
	end
	for _, v in ipairs(cells) do
		if type(v) ~= "number" then
			error("cells holds something that is not a number")
		end
	end
	local function num(v)
		return type(v) == "number" and v or 1
	end
	return __buildat_set_cell_geometry(getmetatable(safe_node).unsafe, cells,
			size, num(r), num(g), num(b), num(a), type(v) == "number" and v or 0)
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
