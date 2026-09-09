-- Buildat: extension/luanti_client/player.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The player's box in the world: what the keys do to it, what stops it, and
-- what gravity does to it.
--
-- Luanti's player is an axis-aligned box 0.6 nodes across and 1.75 tall whose
-- bottom face is the position the server talks about. This knows nothing of
-- the protocol or of Urho3D: it asks whether the node at an integer
-- coordinate stops the player, which is what makes it checkable without
-- either of them (see test.lua).
--
-- Collisions are resolved one axis at a time, and only against the nodes the
-- box moves into. Resolving axis by axis is what makes sliding along a wall
-- work; looking only at the nodes ahead is what keeps a player who is already
-- inside a node -- the server put them there, or something was built on them
-- -- able to move out of it.

local M = {}

M.RADIUS = 0.3
M.HEIGHT = 1.75
-- Where the eyes are above the feet, which is what the camera follows
M.EYE_HEIGHT = 1.625
-- Luanti's movement defaults, which is what TOCLIENT_MOVEMENT carries and
-- what a game changes when it wants a different feel. Nodes a second, and
-- nodes a second squared.
M.DEFAULT_MOVEMENT = {
	acceleration_default = 3,
	acceleration_air = 2,
	acceleration_fast = 10,
	speed_walk = 4,
	speed_crouch = 1.35,
	speed_fast = 20,
	speed_climb = 3,
	speed_jump = 6.5,
	liquid_fluidity = 1,
	liquid_fluidity_smooth = 0.5,
	liquid_sink = 10,
	gravity = 9.81,
}

-- The box as an offset from the position, per axis (1 = x, 2 = y, 3 = z)
local OFF_LO = {-M.RADIUS, 0, -M.RADIUS}
local OFF_HI = {M.RADIUS, M.HEIGHT, M.RADIUS}

-- Acceleration on the wire is in voxels/s² only after another factor of BS;
-- see where it is used below.
local BS_ACCEL = 10

-- A node at integer coordinate i covers [i - 0.5, i + 0.5]. These are the
-- first and last node a span reaches into; touching is not overlapping, which
-- is what lets the player stand exactly on a surface.
local function cell_lo(v)
	return math.floor(v + 0.5)
end

local function cell_hi(v)
	return math.ceil(v - 0.5)
end

-- Moves the box along one axis until something stops it. p is {x, y, z} and
-- is changed in place; returns true if something stopped it.
local function move_axis(p, axis, d, is_solid)
	if d == 0 then
		return false
	end
	-- The two axes the box does not move along, as the cells it covers there
	local a1, a2
	for a = 1, 3 do
		if a ~= axis then
			if not a1 then a1 = a else a2 = a end
		end
	end
	local u0, u1 = cell_lo(p[a1] + OFF_LO[a1]), cell_hi(p[a1] + OFF_HI[a1])
	local v0, v1 = cell_lo(p[a2] + OFF_LO[a2]), cell_hi(p[a2] + OFF_HI[a2])

	-- The cells the box moves into, nearest first
	local from, to, step
	if d > 0 then
		from = cell_hi(p[axis] + OFF_HI[axis]) + 1
		to = cell_hi(p[axis] + d + OFF_HI[axis])
		step = 1
	else
		from = cell_lo(p[axis] + OFF_LO[axis]) - 1
		to = cell_lo(p[axis] + d + OFF_LO[axis])
		step = -1
	end

	local q = {0, 0, 0}
	q[a1], q[a2] = 0, 0
	for c = from, to, step do
		q[axis] = c
		for u = u0, u1 do
			q[a1] = u
			for v = v0, v1 do
				q[a2] = v
				if is_solid(q[1], q[2], q[3]) then
					if d > 0 then
						p[axis] = c - 0.5 - OFF_HI[axis]
					else
						p[axis] = c + 0.5 - OFF_LO[axis]
					end
					return true
				end
			end
		end
	end
	p[axis] = p[axis] + d
	return false
end

M.move_axis = move_axis

local function never_solid()
	return false
end

-- Moves v towards target by at most max
local function approach(v, target, max)
	if target > v then
		return math.min(target, v + max)
	end
	return math.max(target, v - max)
end

-- new(is_solid, is_liquid)
--
-- is_solid(x, y, z) says whether the node at those integer coordinates stops
-- the player. It is asked about nodes that may not have arrived, and should
-- say yes for those: standing still in a world that has not loaded is better
-- than falling through it.
--
-- is_liquid(x, y, z) says whether it is something to swim in. Optional.
function M.new(is_solid, is_liquid)
	local self = {
		x = 0, y = 0, z = 0,
		vx = 0, vy = 0, vz = 0,
		on_ground = false,
		in_liquid = false,
		-- Flying and going through walls are off by default and keys toggle
		-- them; a server that does not give the player the fly and noclip
		-- privileges will pull them back with its movement checks
		fly = false,
		noclip = false,
		movement = M.DEFAULT_MOVEMENT,
	}

	-- The server put the player here, so whatever we thought is wrong
	function self:set_position(x, y, z)
		self.x, self.y, self.z = x, y, z
		self.vy = 0
	end

	-- One step of the player's own physics. wish is what the keys say:
	--   x, z    the direction to walk in, in world coordinates, any length
	--   jump    up, and out of the water
	--   sneak   down when flying, slower on the ground
	--   fast    the fast speed and the fast acceleration
	-- Returns the position after the step.
	--
	-- simplified: a liquid is something with a sinking speed and a way out of
	-- it, and that is all. Viscosity, the two fluidity constants, being partly
	-- submerged and the difference between a source and a flowing node are
	-- not used; LocalPlayer::move() in Luanti is what does all of that.
	function self:update(dtime, wish)
		if dtime <= 0 then
			return self.x, self.y, self.z
		end
		-- A frame long enough to fall several nodes in is a frame the server
		-- would not believe anyway
		if dtime > 0.2 then
			dtime = 0.2
		end
		local m = self.movement
		-- Going through walls is the collision test answering no to
		-- everything, which is also how a player who ended up inside
		-- something gets out
		local stops = self.noclip and never_solid or is_solid

		self.in_liquid = is_liquid ~= nil and
				is_liquid(math.floor(self.x + 0.5),
						math.floor(self.y + 0.5),
						math.floor(self.z + 0.5))

		-- Horizontal: accelerate towards what the keys ask for
		local speed = m.speed_walk
		if wish.fast then
			speed = m.speed_fast
		elseif wish.sneak and not self.fly then
			speed = m.speed_crouch
		end
		local len = math.sqrt(wish.x * wish.x + wish.z * wish.z)
		local target_x, target_z = 0, 0
		if len > 0 then
			target_x = wish.x / len * speed
			target_z = wish.z / len * speed
		end
		local accel = m.acceleration_air
		if self.fly then
			accel = m.acceleration_fast
		elseif self.on_ground then
			accel = wish.fast and m.acceleration_fast or
					m.acceleration_default
		end
		-- Luanti multiplies the acceleration it sent by BS (10) when it
		-- receives TOCLIENT_MOVEMENT and then again in LocalPlayer::move,
		-- while speeds get BS only once. In voxel units that leaves the
		-- effective acceleration ten times the wire value.
		local max = accel * BS_ACCEL * dtime
		self.vx = approach(self.vx, target_x, max)
		self.vz = approach(self.vz, target_z, max)

		-- Vertical
		if self.fly or self.noclip then
			self.vy = 0
			if wish.jump then
				self.vy = speed
			end
			if wish.sneak then
				self.vy = self.vy - speed
			end
		elseif self.in_liquid then
			if wish.jump then
				self.vy = m.speed_walk
			else
				self.vy = self.vy - m.gravity * dtime
				if self.vy < -m.liquid_sink then
					self.vy = -m.liquid_sink
				end
			end
		elseif self.on_ground and wish.jump then
			self.vy = m.speed_jump
		else
			self.vy = self.vy - m.gravity * dtime
		end

		local p = {self.x, self.y, self.z}
		-- Vertically first, so that whether the player is standing on
		-- something is settled before a step up is considered
		if move_axis(p, 2, self.vy * dtime, stops) then
			self.on_ground = self.vy < 0
			self.vy = 0
		else
			self.on_ground = false
		end

		-- Then along each horizontal axis on its own, which is what makes a
		-- walk into a wall at an angle slide along it
		--
		-- Nothing steps up: every node is a full cube here, and a full node
		-- is something Luanti makes the player jump over too. Luanti's step
		-- height of 0.6 is for the stairs and slabs whose collision boxes are
		-- lower than a node, and those need the boxes read out of the node
		-- definitions first.
		local hit_x = move_axis(p, 1, self.vx * dtime, stops)
		local hit_z = move_axis(p, 3, self.vz * dtime, stops)
		if hit_x then
			self.vx = 0
		end
		if hit_z then
			self.vz = 0
		end
		self.x, self.y, self.z = p[1], p[2], p[3]
		return self.x, self.y, self.z
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
