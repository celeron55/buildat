-- Buildat: extensions/luanti_client/res/camera_motion.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- View bobbing and the wield hand's motion as official Luanti has them
-- (src/client/camera.cpp), one module for both Luanti clients
-- ([VIEW_BOB]). Everything is in nodes and degrees; official's numbers
-- are in BS units (ten to the node) and are divided here once.
--
--   local motion = camera_motion.new()
--   motion.amount = 1.0            -- view_bobbing_amount; 0 turns it off
--   local m = motion:update(dt, {walking =, swimming =, climbing =,
--       flying =, speed = <nodes/s>, digging = <bool>, wield_changed = <bool>})
--   m.offset  = {x, y, z}          -- the camera's, in the camera's own axes
--   m.roll    = degrees            -- the camera's roll
--   m.hand    = {x, y, z}          -- the hand's offset from its rest, nodes
--
-- simplified: the arm's inertia on the look (official's addArmInertia,
-- off by default there too) and the tool reload's dip are not here; the
-- dig swing is the bob's own swing held while digging.

local M = {}

local function modf(x)
	return x - math.floor(x)
end

function M.new()
	local self = {
		amount = 1.0,
		-- official's m_view_bobbing_anim (0..1, the walk cycle), _state
		-- (0 off, 1 on, 2 fading out) and _speed (BS units per second)
		anim = 0, state = 0, speed = 0,
		-- official's m_wield_change_timer: -0.125..0.125, the hand dips
		-- through zero on a wield change
		wield_change = 0.125,
	}
	-- A plain copy of the method, not a metatable: the sandbox has no
	-- setmetatable
	self.update = M.update
	return self
end

function M.update(self, dt, s)
	-- The timer first, as official's update() runs it before the camera
	if s.wield_changed then
		self.wield_change = -0.125
	end
	self.wield_change = math.min(self.wield_change + dt, 0.125)

	if self.state ~= 0 then
		local offset = dt * self.speed * 0.030
		if self.state == 2 then
			-- Fading out: to the nearest rest, 0, 0.5 or 1
			if self.anim < 0.25 then
				self.anim = self.anim - offset
			elseif self.anim > 0.75 then
				self.anim = self.anim + offset
			elseif self.anim < 0.5 then
				self.anim = math.min(0.5, self.anim + offset)
			else
				self.anim = math.max(0.5, self.anim - offset)
			end
			if self.anim <= 0 or self.anim >= 1 or
					math.abs(self.anim - 0.5) < 0.01 then
				self.anim = 0
				self.state = 0
			end
		else
			self.anim = modf(self.anim + offset)
		end
	end

	local out = {offset = {0, 0, 0}, roll = 0, hand = {0, 0, 0}}
	if self.amount ~= 0 and self.anim ~= 0 then
		local bobfrac = modf(self.anim * 2)
		local bobdir = self.anim < 0.5 and 1 or -1
		local bobtmp = math.sin((bobfrac ^ 1.2) * math.pi)
		-- official's bobvec, BS units: (0.3 * bobdir * sin, -0.28 * tmp^2, 0)
		out.offset = {0.03 * bobdir * math.sin(bobfrac * math.pi) * self.amount,
				-0.028 * bobtmp * bobtmp * self.amount, 0}
		-- Degrees: official hands this to Irrlicht's rotateXYBy, which
		-- takes degrees, so the roll is under a tenth of one. Read as
		-- radians and converted, it was fifty times that -- the bob
		-- "ten times too strong" on the box ([BOX_PLAYTEST_2] 10).
		out.roll = -0.03 * bobdir * bobtmp * math.pi * self.amount
	end

	-- The hand: the change's dip (|timer| * 320 - 40, BS), and the bob's
	-- swing while walking; while digging official slerps the hand toward
	-- a swing pose -- here the same swing, held
	local hand_y = (math.abs(self.wield_change) * 320 - 40) / 10
	local bobfrac = modf(self.anim)
	local hand_x = -math.sin(bobfrac * math.pi * 2) * 3 / 10
	hand_y = hand_y + math.sin(modf(bobfrac * 2) * math.pi) * 3 / 10
	local hand_z = 0
	if s.digging then
		local digfrac = modf((s.dig_anim or 0))
		hand_x = hand_x - 50 * math.sin((digfrac ^ 0.8) * math.pi) / 10
		hand_y = hand_y + 24 * math.sin(digfrac * 1.8 * math.pi) / 10
		hand_z = 25 * 0.5 / 10
	end
	out.hand = {hand_x, hand_y, hand_z}

	-- Start, continue or stop the bob, as official decides after the
	-- camera is placed: walking on the ground, swimming or climbing, and
	-- never while flying
	if (s.walking or s.swimming or s.climbing) and not s.flying then
		self.state = 1
		self.speed = math.min((s.speed or 0) * 10, 70)
	elseif self.state == 1 then
		self.state = 2
		self.speed = 60
	end
	return out
end

-- The check: a walk bobs and comes to rest, a stop fades to nothing, a
-- flight never starts, a wield change dips the hand and returns
do
	local m = M.new()
	local first = m:update(0.016, {walking = true, speed = 4})
	assert(first.roll == 0 and first.offset[2] == 0, "the first frame is still")
	local lowest, rolled = 0, 0
	for _ = 1, 60 do
		local r = m:update(0.016, {walking = true, speed = 4})
		lowest = math.min(lowest, r.offset[2])
		rolled = math.max(rolled, math.abs(r.roll))
	end
	assert(lowest < -0.02 and lowest > -0.03, "the bob dips about 0.028: " .. lowest)
	assert(rolled > 0.05 and rolled < 0.1, "the roll under a tenth of a degree: " .. rolled)
	for _ = 1, 120 do
		m:update(0.016, {walking = false, speed = 0})
	end
	assert(m.state == 0 and m.anim == 0, "stopped, the bob fades out")
	local r = m:update(0.016, {walking = true, flying = true, speed = 4})
	assert(m.state == 0, "no bob while flying")
	m = M.new()
	local rest = m:update(0.016, {}).hand[2]
	local dipped = m:update(0.016, {wield_changed = true}).hand[2]
	assert(dipped < rest - 0.3, "a wield change dips the hand: " .. rest .. " -> " .. dipped)
	for _ = 1, 20 do
		r = m:update(0.016, {})
	end
	assert(math.abs(r.hand[2] - rest) < 1e-6, "and it comes back")
end

return M
-- vim: set noet ts=4 sw=4:
