-- Buildat: extension/luanti_client/media.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The server's media files, on disk where Urho3D's resource cache can find
-- them.
--
-- The server announces what it has as name plus sha1, the client asks for what
-- it wants by name, and the files come back in bunches. They are kept in
-- cache/luanti_media/<server>/, so a second run asks for nothing: a cached
-- file is used when its sha1 is the one the server announced, and re-fetched
-- when it is not. That check is also what keeps a file that was written
-- half-way from being drawn.
--
-- Only the textures the node definitions name are asked for. A game's media is
-- mostly sounds, models and textures for things that are not nodes, and there
-- can be thousands of them.

local M = {}

-- A name from the server ends up as a file name, so it is checked rather than
-- trusted. Luanti's own names are of the form "modname_thing.png"; anything
-- with a path in it, or that could be one, is refused.
function M.is_safe_name(name)
	if name == "" or #name > 200 then
		return false
	end
	if name:find("[^%w%._%-]") then
		return false
	end
	-- "." and ".." are directories, and a leading dot hides the file
	if name:sub(1, 1) == "." then
		return false
	end
	return true
end

-- A directory name for one server, out of its address
function M.server_key(host, port)
	return (host:gsub("[^%w%._%-]", "_")).."_"..tostring(port)
end

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local data = file:read("*all")
	file:close()
	return data
end

local function write_file(path, data)
	local file = io.open(path, "wb")
	if not file then
		return false
	end
	file:write(data)
	file:close()
	return true
end

-- new(buildat, log, dir): dir is where this server's files go, and is created
function M.new(buildat, log, dir)
	local self = {dir = dir}
	__buildat_mkdir(dir)

	-- name -> true for files that are on disk with the announced sha1
	local have = {}
	-- name -> sha1 for files that have been asked for and not arrived
	local missing = {}

	-- The announced list, and the names worth having. Returns the names to ask
	-- the server for; the ones already on disk are counted as had.
	--
	-- wanted is a set of names; a name that was not announced cannot be
	-- fetched and is left out.
	function self:plan(files, wanted)
		local ask = {}
		local skipped_unsafe = 0
		for _, file in ipairs(files) do
			if wanted[file.name] and not have[file.name] and
					not missing[file.name] then
				if not M.is_safe_name(file.name) then
					skipped_unsafe = skipped_unsafe + 1
				else
					local data = read_file(dir.."/"..file.name)
					if data and buildat.sha1(data) == file.sha1 then
						have[file.name] = true
					else
						missing[file.name] = file.sha1
						ask[#ask + 1] = file.name
					end
				end
			end
		end
		if skipped_unsafe > 0 then
			log:warning("media: "..skipped_unsafe..
					" announced names are not usable as file names")
		end
		return ask
	end

	-- Files out of a MEDIA bunch. Returns how many were written, and how many
	-- are still to come.
	function self:store(files)
		local written = 0
		for _, file in ipairs(files) do
			local sha1 = missing[file.name]
			if not sha1 then
				-- Something we did not ask for, or already have
			elseif buildat.sha1(file.data) ~= sha1 then
				log:warning("media: "..file.name..
						" does not have the sha1 the server announced")
				missing[file.name] = nil
			elseif write_file(dir.."/"..file.name, file.data) then
				have[file.name] = true
				missing[file.name] = nil
				written = written + 1
			else
				log:warning("media: could not write "..dir.."/"..file.name)
				missing[file.name] = nil
			end
		end
		return written, self:missing_count()
	end

	function self:have_file(name)
		return have[name] == true
	end

	function self:missing_count()
		local n = 0
		for _, _ in pairs(missing) do
			n = n + 1
		end
		return n
	end

	function self:have_count()
		local n = 0
		for _, _ in pairs(have) do
			n = n + 1
		end
		return n
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
