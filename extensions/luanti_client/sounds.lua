-- Buildat: extension/luanti_client/sounds.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The sounds the server asks for: PLAY_SOUND, STOP_SOUND and FADE_SOUND.
--
-- A server names a sound *group*, not a file: a game ships three recordings
-- of a footstep as "step.1.ogg", "step.2.ogg" and "step.3.ogg", and asking
-- for "step" plays one of them at random. So the announced media has to be
-- sorted into groups before a name can be turned into something to play,
-- which is what groups() does.
--
-- What is here is the reading and the grouping. Playing one is world.lua's,
-- because the scene and the camera are there and a sound at a position is a
-- node in the scene.

local M = {}

-- Luanti's BS: one node is this many of the units a position comes in
local BS = 10.0

-- Luanti's SoundLocation
M.LOCAL = 0
M.POSITION = 1
M.OBJECT = 2

-- The group a sound file is in: "name.3.ogg" and "name.ogg" are both in
-- group "name". Only a single digit, which is what Luanti's own list of
-- suffixes allows. nil for a file that is not a sound at all.
function M.group_of(filename)
	local base = filename:match("^(.*)%.%d%.ogg$")
	if base then
		return base
	end
	return filename:match("^(.*)%.ogg$")
end

-- groups(names) -> group name -> the file names in it, sorted so that which
-- file a random pick lands on does not depend on the order the media
-- arrived in
function M.groups(names)
	local out = {}
	for _, name in ipairs(names) do
		local group = M.group_of(name)
		if group then
			local list = out[group]
			if not list then
				list = {}
				out[group] = list
			end
			list[#list + 1] = name
		end
	end
	for _, list in pairs(out) do
		table.sort(list)
	end
	return out
end

-- PLAY_SOUND. The id is the server's own and is what STOP_SOUND and
-- FADE_SOUND name later; a negative one is a sound the server does not
-- expect to talk about again.
--
-- ephemeral and start_time came in 5.2 and 5.8, so a server older than one
-- of them simply stops sending and what is left keeps its default.
function M.read_play(r)
	local id = r:s32()
	local spec = {}
	spec.name = r:string()
	spec.gain = r:f32()
	spec.location = r:u8()
	local x, y, z = r:v3f()
	spec.pos = {x / BS, y / BS, z / BS}
	spec.object_id = r:u16()
	spec.loop = r:u8() ~= 0
	spec.fade = r:f32()
	spec.pitch = r:f32()
	spec.ephemeral = false
	spec.start_time = 0
	if r:remaining() >= 1 then
		spec.ephemeral = r:u8() ~= 0
	end
	if r:remaining() >= 4 then
		spec.start_time = r:f32()
	end
	return id, spec
end

function M.read_stop(r)
	return r:s32()
end

-- FADE_SOUND: the gain to end at and how much of it a second to move
function M.read_fade(r)
	local id = r:s32()
	local step = r:f32()
	local gain = r:f32()
	return id, step, gain
end

-- One step of a fade: where the gain is after dtime, and whether it is
-- there. Luanti's step is per second and its sign is not to be trusted --
-- what says which way it goes is which side of the target the gain is on.
function M.fade_step(gain, target, step, dtime)
	local by = math.abs(step) * dtime
	if gain < target then
		gain = math.min(target, gain + by)
	else
		gain = math.max(target, gain - by)
	end
	return gain, gain == target
end

return M
-- vim: set noet ts=4 sw=4:
