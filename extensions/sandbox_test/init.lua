-- Buildat: extension/sandbox_test/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sandbox_test")
local dump = buildat.dump
-- **This extension loads on both sides now** ([LAUNCH_SANDBOX]): it is
-- also the hostile launch UI, and a launch UI that asks to be
-- sandboxed has its init.lua run in the sandbox, where there is no
-- dofile and no extension_path. The trusted half is what Ctrl+F12
-- runs; the sandboxed half is M.boot() at the end of this file.
local trusted = (dofile ~= nil and buildat.extension_path ~= nil)
local try_exploit = trusted and
		dofile(buildat.extension_path("sandbox_test").."/try_exploit.lua") or nil
local M = {}

local function get_file_content(path)
	local f = io.open(path, "rb")
	if not f then
		log:error("Could not open file "..dump(path))
		return nil
	end
	local content = f:read("*all")
	f:close()
	return content
end

local function run_in_sandbox(content, chunkname)
	local sandbox_status = nil
	local f = function()
		sandbox_status = __buildat_run_code_in_sandbox(content, chunkname)
	end
	local status, err = __buildat_pcall(f)
	if err then
		log:verbose(err)
	end
	return sandbox_status
end

function M.run()
	log:info("sandbox_test(): Begin")
	local ext_path = buildat.extension_path("sandbox_test")
	local tmp_path = buildat.extension_path("sandbox_test")

	-- Check that running safe code works
	log:info("sandbox_test(): Testing safe code")
	local safe_content = get_file_content(ext_path.."/tests/safe.lua")
	assert(safe_content)
	local success = run_in_sandbox(safe_content, "=safe.lua")
	assert(success)

	-- Check that running the safe code as bytecode doesn't work
	log:info("sandbox_test(): Testing bytecode")
	local f, err = loadstring(safe_content)
	if f == nil then
		error("Could not load bytecode source: "..err)
	end
	local bytecode = string.dump(f)
	local success = run_in_sandbox(bytecode)
	assert(success == false)

	-- Check that the standard libraries cannot be required
	log:info("sandbox_test(): Testing require")
	local require_content = get_file_content(ext_path.."/tests/require.lua")
	assert(require_content)
	local success = run_in_sandbox(require_content, "=require.lua")
	assert(success)

	-- Run the exploit search
	log:info("sandbox_test(): Trying to find an exploit")
	try_exploit.run()

	log:info("sandbox_test(): Finished")
end

-- Armed by toggle() (Ctrl+F12), not by loading: a sandboxed file's
-- require("buildat/extension/sandbox_test") loads this file before
-- learning it has no safe interface, and armed at load the walk ran in
-- every client from the menu on ([UI_UAF], 2026-09-20).
local value_checker_enabled = false
function M.check_value(value)
	if not value_checker_enabled then return end
	log:debug("sandbox_test.check_value()")
	try_exploit.search_single_value(value)
end
if trusted then
	__buildat_sandbox_debug_check_value_sub(M.check_value)
end

-- **The hostile launch UI** ([LAUNCH_SANDBOX]'s done-when): selected
-- like any other -- `-m sandbox_test`, or the `launch_ui` preference --
-- and it spends its boot trying to reach past the verbs instead of
-- drawing anything. What it could reach is one log line, which is what
-- extensions/sandbox_test/check.sh reads.
function M.boot(action)
	local attack = buildat.run_extension_file("launch_attack.lua")
	if type(attack) ~= "table" then
		log:error("sandbox_test: launch_attack.lua did not load")
		return
	end
	attack.run()
	-- **The whitelist's other half**, in the same boot ([URHO_SWEEP]):
	-- the attack says what cannot be reached, and `tests/safe.lua` says
	-- that what was wrapped works -- a class added to the whitelist and
	-- silently doing nothing is the fault that sweep exists to avoid.
	-- It ran only behind Ctrl+F12 before, which no check presses.
	-- This boot is sandboxed code itself, so the file is run through the
	-- sandbox's own verb rather than read off the disk
	-- **The file's own answer, not the call's**: a sandboxed file that
	-- raises is caught inside run_extension_file, which then answers nil
	-- and an error -- so a pcall around it says "fine" about a file that
	-- failed every assertion in it (2026-09-25). wrapped.lua ends with
	-- `return true`, and that is what is read.
	local ok, ret = pcall(function()
		return buildat.run_extension_file("wrapped.lua")
	end)
	if ok and ret == true then
		log:info("launch sandbox: the safe tests passed")
	else
		log:error("launch sandbox: the safe tests failed (" ..
				tostring(ret) .. "); the raise is in the lines above")
	end
end

local is_active = false

function M.toggle() -- Called by client/app
	if not is_active then
		M.run()
		value_checker_enabled = true
		is_active = true
	else
		value_checker_enabled = false
		is_active = false
	end
end

return M
-- vim: set noet ts=4 sw=4:
