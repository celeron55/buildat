-- Buildat: extension/sandbox_test/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sandbox_test")
local dump = buildat.dump
local try_exploit = dofile(buildat.extension_path("sandbox_test").."/try_exploit.lua")
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

	-- Run the exploit search
	log:info("sandbox_test(): Trying to find an exploit")
	try_exploit.run()

	log:info("sandbox_test(): Finished")
end

-- Enabled when this module is loaded.
-- Normally that happens when KEY_F10 is pressed on the client.
function M.check_value(value)
	log:debug("sandbox_test.check_value()")
	try_exploit.search_single_value(value)
end
__buildat_sandbox_debug_check_value_sub(M.check_value)

return M
-- vim: set noet ts=4 sw=4:
