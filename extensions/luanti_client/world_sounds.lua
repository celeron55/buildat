-- Buildat: extension/luanti_client/world_sounds.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The sounds: a part of world.lua's M.new, which calls this with what it
-- reads of M.new's ([SPLITS]: moved out as it was).

return function(self, magic, scene, sounds_proto, SOUND_NEAR, SOUND_FAR,
		sounds, object_nodes)
	-- play_sound(id, spec, resource)
	--
	-- spec is what sounds.lua read out of PLAY_SOUND and resource the name
	-- of one file of the group it asked for -- picking which one is the
	-- caller's, because which files there are is the media's business.
	--
	-- A sound attached to an object starts where the object is and follows
	-- it, which is what a mob's own noises want.
	--
	-- simplified: start_time is ignored, because seeking is not in the
	-- sandbox's SoundSource. A game uses it for background music a player
	-- rejoins in the middle of.
	function self:play_sound(id, spec, resource)
		local sound = magic.cache:GetResource("Sound", resource)
		if not sound then
			return false
		end
		sound.looped = spec.loop and true or false
		local node = scene:CreateChild("sound_"..tostring(id))
		local source
		-- A sound attached to an object starts where the object is and
		-- follows it; one at a position stays there; one that is neither is
		-- in the player's own head and has no position at all.
		local follows = spec.location == sounds_proto.OBJECT and
				spec.object_id ~= 0 and spec.object_id or nil
		if spec.location == sounds_proto.LOCAL then
			source = node:CreateComponent("SoundSource")
		else
			local at = follows and object_nodes[follows]
			if at and at.at_x then
				node.position = magic.Vector3(at.at_x,
						at.at_y + (at.offset or 0), at.at_z)
			else
				node.position = magic.Vector3(spec.pos[1], spec.pos[2],
						spec.pos[3])
			end
			source = node:CreateComponent("SoundSource3D")
			source.nearDistance = SOUND_NEAR
			source.farDistance = SOUND_FAR
		end
		source.soundType = magic.SOUND_EFFECT
		local gain = spec.gain or 1.0
		-- A fade on the packet means it starts silent and comes up to the
		-- gain it asked for
		local entry = {node = node, source = source, gain = gain,
				started = false, object_id = follows}
		if spec.fade and spec.fade > 0 then
			entry.target = gain
			entry.step = spec.fade
			gain = 0
		end
		source.gain = gain
		if spec.pitch and spec.pitch > 0 and spec.pitch ~= 1 then
			source.frequency = sound.frequency * spec.pitch
		end
		source:Play(sound)
		-- A sound the server gave no id keeps none: it said it will not talk
		-- about it again, and the update below takes the node away when it
		-- has finished
		self:stop_sound(id)
		sounds[id] = entry
		return true
	end

	function self:stop_sound(id)
		local entry = sounds[id]
		if not entry then
			return
		end
		sounds[id] = nil
		entry.source:Stop()
		entry.node:Remove()
	end

	-- FADE_SOUND: gain moves by step a second until it is at gain, and a
	-- sound faded to nothing stops
	function self:fade_sound(id, step, gain)
		local entry = sounds[id]
		if not entry then
			return
		end
		entry.target = gain
		entry.step = step
	end

	-- The fades, and the nodes of the sounds that have finished
	function self:update_sounds(dtime)
		for id, entry in pairs(sounds) do
			-- A sound attached to an object goes where the object goes: a
			-- mob's own noises come from the mob rather than from where it
			-- was when it made them
			local follow = entry.object_id and object_nodes[entry.object_id]
			if follow and follow.at_x and
					(follow.at_x ~= entry.at_x or
					follow.at_y ~= entry.at_y or
					follow.at_z ~= entry.at_z) then
				entry.at_x, entry.at_y, entry.at_z =
						follow.at_x, follow.at_y, follow.at_z
				entry.node.position = magic.Vector3(follow.at_x,
						follow.at_y + (follow.offset or 0), follow.at_z)
			end
			if entry.target then
				local gain, done = sounds_proto.fade_step(entry.gain,
						entry.target, entry.step, dtime)
				entry.gain = gain
				entry.source.gain = gain
				if done then
					entry.target = nil
					if gain <= 0 then
						self:stop_sound(id)
					end
				end
			end
			-- Not on the frame it started: a source has not been mixed yet
			-- and says it is not playing
			if sounds[id] then
				if entry.started and not entry.source.playing then
					self:stop_sound(id)
				end
				entry.started = true
			end
		end
	end

	function self:sound_count()
		local n = 0
		for _, _ in pairs(sounds) do
			n = n + 1
		end
		return n
	end
end
-- vim: set noet ts=4 sw=4:
