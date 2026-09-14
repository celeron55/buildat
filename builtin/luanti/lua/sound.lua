-- The sounds a game plays
--
-- core.sound_play() and the two calls that talk about one afterwards. What
-- reaches the client is a record per sound on the luanti:sound channel; the
-- client makes an Urho3D SoundSource of it, at a place in the world or in
-- the player's own head, and the fades run there.
--
-- The shape is this module's own rather than Luanti's wire format, because
-- there is no wire here to be compatible with. What does come from Luanti is
-- the group: a game names "default_dig_cracky" and the media holds
-- default_dig_cracky.1.ogg and .2.ogg, one of which is picked per play. The
-- module knows what media it serves, so the file is picked here and the
-- client is told which one.
--
-- simplified: no start_time, because seeking is not in the sandbox's
-- SoundSource -- a game uses it for music a player rejoins in the middle of.

local next_handle = 0
-- handle -> who was told about it, so that a stop or a fade reaches the same
-- clients. An ephemeral sound is not in here: the game said it will not talk
-- about that one again.
--
-- simplified: nothing says when a sound has finished -- the client knows and
-- does not report it, which is what Luanti's TOSERVER_REMOVED_SOUNDS is --
-- so this is bounded by dropping the oldest handles rather than by the
-- sounds ending. A stop or a fade for one of those does nothing, which
-- takes a thousand sounds played since to reach.
local PLAYING_MAX = 1024
local playing = {}
local playing_order = {}

local function number_or(v, default)
	local n = tonumber(v)
	return n or default
end

-- Who hears it: one player, everyone, or everyone but one -- which is what
-- to_player and exclude_player are
local function listeners(parameters)
	local to = parameters.to_player
	if type(to) == "string" and to ~= "" then
		return {to}
	end
	local out = {}
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		if name ~= parameters.exclude_player then
			out[#out + 1] = name
		end
	end
	return out
end

local function send(names, flat)
	if __luanti_send_sound == nil then
		return
	end
	for _, name in ipairs(names) do
		__luanti_send_sound(name, flat)
	end
end

function core.sound_play(spec, parameters, ephemeral)
	if type(spec) == "string" then
		spec = {name = spec}
	end
	if type(spec) ~= "table" or type(spec.name) ~= "string" or
			spec.name == "" then
		return nil
	end
	parameters = type(parameters) == "table" and parameters or {}
	-- One file of the group, or nothing at all when the game ships none:
	-- a sound nobody has is not worth a packet
	local file = __luanti_sound_file and __luanti_sound_file(spec.name) or nil
	if file == nil or file == "" then
		return nil
	end
	local gain = number_or(spec.gain, 1.0) * number_or(parameters.gain, 1.0)
	local pitch = number_or(spec.pitch, 1.0) * number_or(parameters.pitch, 1.0)
	local fade = number_or(parameters.fade, number_or(spec.fade, 0))
	local handle = next_handle
	next_handle = next_handle + 1
	-- Where it is: on an object, at a place, or in the player's own head,
	-- which is Luanti's own three
	local location, x, y, z, object_id = "local", 0, 0, 0, 0
	if parameters.object ~= nil then
		location = "object"
		object_id = tonumber(parameters.object.__id) or 0
		local p = parameters.object.get_pos and parameters.object:get_pos()
		if p then
			x, y, z = p.x, p.y, p.z
		end
	elseif type(parameters.pos) == "table" then
		location = "pos"
		x = number_or(parameters.pos.x, 0)
		y = number_or(parameters.pos.y, 0)
		z = number_or(parameters.pos.z, 0)
	end
	local names = listeners(parameters)
	send(names, {"play", tostring(handle), file, tostring(gain),
			tostring(pitch), parameters.loop and "1" or "0", tostring(fade),
			location, tostring(x), tostring(y), tostring(z),
			tostring(object_id),
			tostring(number_or(parameters.max_hear_distance, 32))})
	if ephemeral then
		return nil
	end
	playing[handle] = names
	playing_order[#playing_order + 1] = handle
	if #playing_order > PLAYING_MAX then
		playing[table.remove(playing_order, 1)] = nil
	end
	return handle
end

function core.sound_stop(handle)
	local names = playing[tonumber(handle) or -1]
	if names == nil then
		return
	end
	playing[tonumber(handle)] = nil
	send(names, {"stop", tostring(handle)})
end

-- The gain moves by step a second until it is at gain, and a sound faded to
-- nothing stops; which way it goes is which side of the target it is on,
-- because Luanti's own step sign is not to be trusted.
function core.sound_fade(handle, step, gain)
	local names = playing[tonumber(handle) or -1]
	if names == nil then
		return
	end
	if (tonumber(gain) or 0) <= 0 then
		playing[tonumber(handle)] = nil
	end
	send(names, {"fade", tostring(handle), tostring(number_or(step, 1)),
			tostring(number_or(gain, 0))})
end
