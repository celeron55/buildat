-- Buildat: luanti_launcher/client_lua/player.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Copied from extensions/luanti_client/player.lua, which is where it was
-- written and where its own checks are (extensions/luanti_client/test.lua);
-- edit it there and copy it here, or the other way round, rather than
-- letting the two drift. Nothing in it knows Luanti's protocol or Urho3D,
-- which is what makes it the same file in both places.
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
-- Luanti's own step height: a player walks onto anything this much higher
-- without jumping, which is what makes a stair or a slab walkable
M.STEP_HEIGHT = 0.6
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

-- What a voxel that is a whole cube is made of, in its own coordinates: the
-- shorthand solid() returns true for
local CUBE = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}

-- The box as an offset from the position, per axis (1 = x, 2 = y, 3 = z)
local OFF_LO = {-M.RADIUS, 0, -M.RADIUS}
local OFF_HI = {M.RADIUS, M.HEIGHT, M.RADIUS}

-- What a player with nothing done to them moves by; see self.override
local EMPTY_OVERRIDE = {}

-- How much of a node's move_resistance counts, which is Luanti's own
-- constant: resistance 0 still leaves seven tenths of the drag, and each
-- point adds three tenths more. See ClientEnvironment::step().
local RESISTANCE_FACTOR = 0.3

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
--
-- solid(x, y, z) says what is at a node position: false for nothing, true for
-- the whole voxel, or the boxes it is made of, each {x0, y0, z0, x1, y1, z1}
-- in the voxel's own -0.5...0.5 coordinates. A box the player is already
-- inside of does not stop them, which is what lets somebody the server put
-- inside a wall walk out of it.
local function move_axis(p, axis, d, solid)
	if d == 0 then
		return false
	end
	-- The two axes the box does not move along, as the span it covers there
	local a1, a2
	for a = 1, 3 do
		if a ~= axis then
			if not a1 then a1 = a else a2 = a end
		end
	end
	local lo1, hi1 = p[a1] + OFF_LO[a1], p[a1] + OFF_HI[a1]
	local lo2, hi2 = p[a2] + OFF_LO[a2], p[a2] + OFF_HI[a2]
	local u0, u1 = cell_lo(lo1), cell_hi(hi1)
	local v0, v1 = cell_lo(lo2), cell_hi(hi2)

	-- The cells the box moves through, nearest first. It starts at the cell
	-- the moving edge is already in rather than the next one: a voxel made
	-- of boxes can have one below the player's feet in the same cell as the
	-- feet -- standing on a slab is exactly that -- and a box the player is
	-- already past is skipped below anyway.
	local from, to, step
	if d > 0 then
		from = cell_hi(p[axis] + OFF_HI[axis])
		to = cell_hi(p[axis] + d + OFF_HI[axis])
		step = 1
	else
		from = cell_lo(p[axis] + OFF_LO[axis])
		to = cell_lo(p[axis] + d + OFF_LO[axis])
		step = -1
	end

	-- Touching is not overlapping: a player standing exactly on a surface is
	-- not inside it
	local E = 1e-9
	local q = {0, 0, 0}
	for c = from, to, step do
		q[axis] = c
		local stop = nil
		for u = u0, u1 do
			q[a1] = u
			for v = v0, v1 do
				q[a2] = v
				local what = solid(q[1], q[2], q[3])
				if what then
					local boxes = what == true and CUBE or what
					for _, b in ipairs(boxes) do
						-- The box where it is in the world
						local b_lo1 = q[a1] + b[a1]
						local b_hi1 = q[a1] + b[a1 + 3]
						local b_lo2 = q[a2] + b[a2]
						local b_hi2 = q[a2] + b[a2 + 3]
						if b_hi1 > lo1 + E and b_lo1 < hi1 - E and
								b_hi2 > lo2 + E and b_lo2 < hi2 - E then
							local at
							if d > 0 then
								at = q[axis] + b[axis] - OFF_HI[axis]
								if at >= p[axis] - E and
										(not stop or at < stop) then
									stop = at
								end
							else
								at = q[axis] + b[axis + 3] - OFF_LO[axis]
								if at <= p[axis] + E and
										(not stop or at > stop) then
									stop = at
								end
							end
						end
					end
				end
			end
		end
		if stop and ((d > 0 and stop < p[axis] + d) or
				(d < 0 and stop > p[axis] + d)) then
			p[axis] = stop
			return true
		end
	end
	p[axis] = p[axis] + d
	return false
end

M.move_axis = move_axis

-- One horizontal move, stepping up onto what is low enough to step onto: the
-- move is tried again from a step up, and what the player then stands on is
-- found by settling back down. Only from the ground, so a jump does not
-- climb a wall.
local function move_horizontal(p, axis, d, solid, on_ground)
	local direct = {p[1], p[2], p[3]}
	local hit = move_axis(direct, axis, d, solid)
	local function take(q)
		p[1], p[2], p[3] = q[1], q[2], q[3]
	end
	if not hit or not on_ground then
		take(direct)
		return hit
	end
	-- No room to rise, or still blocked up there: the plain move it is
	local up = {p[1], p[2], p[3]}
	if move_axis(up, 2, M.STEP_HEIGHT, solid) then
		take(direct)
		return true
	end
	if move_axis(up, axis, d, solid) then
		take(direct)
		return true
	end
	move_axis(up, 2, -M.STEP_HEIGHT, solid)
	take(up)
	return false
end

M.move_horizontal = move_horizontal

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
-- is_solid(x, y, z) says what stops the player at those integer coordinates:
-- false for nothing, true for the whole voxel, or the boxes it is made of.
-- It is asked about nodes that may not have arrived, and should say true for
-- those: standing still in a world that has not loaded is better than falling
-- through it.
--
-- is_liquid(x, y, z) says whether it is something to swim in. Optional.
function M.new(is_solid, is_liquid, is_climbable, resistance_at)
	local self = {
		x = 0, y = 0, z = 0,
		vx = 0, vy = 0, vz = 0,
		on_ground = false,
		in_liquid = false,
		-- Whether a ladder or a vine is holding the player up; see
		-- is_climbable and the vertical part of update()
		climbing = false,
		-- How fast the player was going down when they last hit something,
		-- in nodes a second, or nil. Whoever reads it clears it.
		landed_at = nil,
		-- Flying and going through walls are off by default and keys toggle
		-- them; a server that does not give the player the fly and noclip
		-- privileges will pull them back with its movement checks
		fly = false,
		noclip = false,
		movement = M.DEFAULT_MOVEMENT,
		-- What a mod has done to how this player moves: Luanti's
		-- physics_override, which multiplies rather than replaces. Ones
		-- until the server says otherwise; see M.sub_physics in the
		-- module's client half.
		override = {speed = 1, jump = 1, gravity = 1, sneak = 1,
				sneak_glitch = 0},
	}

	-- The server put the player here, so whatever we thought is wrong
	function self:set_position(x, y, z)
		self.x, self.y, self.z = x, y, z
		self.vy = 0
	end

	-- A push the server gave the player, out of TOCLIENT_PLAYER_SPEED: an
	-- explosion, a jump pad, being hit. It is added to the speed once, as
	-- Luanti adds it, and then the physics has it: the vertical part is what
	-- gravity works off, and the horizontal part decays at whatever the
	-- acceleration is, because the keys are a target rather than a force.
	function self:add_velocity(x, y, z)
		self.vx = self.vx + (x or 0)
		self.vy = self.vy + (y or 0)
		self.vz = self.vz + (z or 0)
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

		local nx = math.floor(self.x + 0.5)
		local ny = math.floor(self.y + 0.5)
		local nz = math.floor(self.z + 0.5)
		self.in_liquid = is_liquid ~= nil and is_liquid(nx, ny, nz)
		-- A ladder is climbed from inside it or from the node the head is
		-- in, which is how a player on the bottom rung holds on
		self.climbing = is_climbable ~= nil and not self.fly and
				not self.noclip and
				(is_climbable(nx, ny, nz) or is_climbable(nx, ny + 1, nz))
		-- How much what they are standing in holds them back
		local resistance = (resistance_at ~= nil and not self.noclip) and
				resistance_at(nx, ny, nz) or 0

		-- What a mod has multiplied this player's movement by, which is
		-- ones unless the server has said otherwise
		local ov = self.override or EMPTY_OVERRIDE
		local ov_speed = ov.speed or 1
		-- Horizontal: accelerate towards what the keys ask for
		local speed = m.speed_walk
		if wish.fast then
			speed = m.speed_fast
		elseif wish.sneak and not self.fly and (ov.sneak or 1) ~= 0 then
			speed = m.speed_crouch
		end
		speed = speed * ov_speed
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
		elseif self.climbing then
			-- Held on to rather than fallen past: up with jump, down with
			-- sneak, and still otherwise. Luanti's own climb has no gravity
			-- in it either.
			self.vy = 0
			if wish.jump then
				self.vy = m.speed_climb * ov_speed
			elseif wish.sneak then
				self.vy = -m.speed_climb * ov_speed
			end
		elseif self.in_liquid then
			if wish.jump then
				self.vy = m.speed_walk * ov_speed
			else
				self.vy = self.vy - m.gravity * (ov.gravity or 1) * dtime
				if self.vy < -m.liquid_sink then
					self.vy = -m.liquid_sink
				end
			end
		elseif self.on_ground and wish.jump then
			self.vy = m.speed_jump * (ov.jump or 1)
		else
			self.vy = self.vy - m.gravity * (ov.gravity or 1) * dtime
		end

		-- What being in something thick does, which is Luanti's own
		-- arithmetic out of ClientEnvironment::step(): a drag along the
		-- direction of travel, scaled by the node's resistance. In a liquid
		-- it is capped at the smooth fluidity, so water pulls a walk down to
		-- its own pace instead of stopping it; out of one -- a game can put
		-- resistance on anything -- it is proportional to the speed, which
		-- is what makes a cobweb a cobweb.
		--
		-- simplified: the two fluidity constants are the defaults and the
		-- physics_override's own fluidity multipliers are not applied, this
		-- module not having them. The shape of the sum is Luanti's.
		if resistance > 0 then
			local len = math.sqrt(self.vx * self.vx + self.vy * self.vy +
					self.vz * self.vz)
			if len > 1e-6 then
				local dl
				if self.in_liquid then
					dl = math.min(len * 10 / m.liquid_fluidity,
							m.liquid_fluidity_smooth)
				else
					dl = len
				end
				dl = dl * (resistance * RESISTANCE_FACTOR +
						(1 - RESISTANCE_FACTOR))
				local take = math.min(dl * dtime * 10, len)
				local k = take / len
				self.vx = self.vx - self.vx * k
				self.vy = self.vy - self.vy * k
				self.vz = self.vz - self.vz * k
			end
		end

		local p = {self.x, self.y, self.z}
		-- Vertically first, so that whether the player is standing on
		-- something is settled before a step up is considered
		if move_axis(p, 2, self.vy * dtime, stops) then
			self.on_ground = self.vy < 0
			-- How hard the landing was, in nodes a second, for whoever
			-- tells the server about it. Left here to be read and cleared:
			-- this module knows nothing about damage, and what a fall costs
			-- is the game's arithmetic and not the physics'.
			if self.vy < 0 then
				self.landed_at = -self.vy
			end
			self.vy = 0
		else
			self.on_ground = false
		end

		-- Then along each horizontal axis on its own, which is what makes a
		-- walk into a wall at an angle slide along it. Anything up to a step
		-- height is walked onto rather than into, so a stair or a slab does
		-- not need a jump; a whole voxel does, which is what Luanti asks for
		-- as well.
		local hit_x = move_horizontal(p, 1, self.vx * dtime, stops,
				self.on_ground)
		local hit_z = move_horizontal(p, 3, self.vz * dtime, stops,
				self.on_ground)
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

-- What a liquid does, which is the part of this that had no caller until
-- 2026-09-15: the launcher built a player with no is_liquid at all, so a
-- swim was a walk through air. Empty space, so nothing to stand on, and one
-- of the two worlds is water.
do
	local nothing_stops = function() return false end
	local all_water = function() return true end

	local dry = M.new(nothing_stops)
	local wet = M.new(nothing_stops, all_water)
	for _ = 1, 100 do
		dry:update(0.1, {x = 0, z = 0})
		wet:update(0.1, {x = 0, z = 0})
	end
	assert(dry.in_liquid == false and wet.in_liquid == true,
			"player: a world of water is not being noticed")
	-- Ten seconds of falling: in air that is a speed no game survives, in
	-- water it is the sinking speed and no more
	assert(dry.vy < -50, "player: nothing slows a fall through air")
	assert(wet.vy >= -M.DEFAULT_MOVEMENT.liquid_sink - 0.001,
			"player: sinking is not clamped to liquid_sink")
	-- And jumping is how you get out of it, from anywhere rather than only
	-- off the ground
	wet:update(0.1, {x = 0, z = 0, jump = true})
	assert(wet.vy > 0 and not wet.on_ground,
			"player: jumping in water does not lift the player")

	-- And how hard a landing was, which is what a fall costs somebody:
	-- dropped onto a floor from high enough to be going fast
	local ground = function(x, y, z) return y <= 0 end
	local dropped = M.new(ground)
	dropped:set_position(0, 30, 0)
	for _ = 1, 100 do
		dropped:update(0.05, {x = 0, z = 0})
		if dropped.landed_at then
			break
		end
	end
	assert(dropped.landed_at and dropped.landed_at > 14,
			"player: a long fall does not report how hard it landed")
	assert(dropped.on_ground, "player: the fall did not end on the ground")

	-- And what something thick does to a walk: the same push into the same
	-- empty space, through air, through water's own resistance, and through
	-- a node seven times as thick -- which is what makes a cobweb a cobweb,
	-- and out of a liquid Luanti's sum takes the whole speed at that point.
	local thin = M.new(nothing_stops)
	local wettish = M.new(nothing_stops, nil, nil, function() return 1 end)
	local web = M.new(nothing_stops, nil, nil, function() return 7 end)
	for _ = 1, 40 do
		thin:update(0.05, {x = 1, z = 0})
		wettish:update(0.05, {x = 1, z = 0})
		web:update(0.05, {x = 1, z = 0})
	end
	assert(wettish.vx > 0 and wettish.vx < thin.vx * 0.9,
			"player: a node that holds a body back does not slow it")
	assert(web.vx < wettish.vx,
			"player: a thicker node is not thicker")

	-- A ladder holds the player where they are, and jump and sneak move
	-- them along it -- which is the whole of climbing
	local ladder = M.new(nothing_stops, nil, all_water)
	for _ = 1, 20 do
		ladder:update(0.1, {x = 0, z = 0})
	end
	assert(ladder.climbing and math.abs(ladder.vy) < 1e-9,
			"player: a ladder does not hold the player up")
	ladder:update(0.1, {x = 0, z = 0, jump = true})
	assert(ladder.vy > 0, "player: jump does not climb")
	ladder:update(0.1, {x = 0, z = 0, sneak = true})
	assert(ladder.vy < 0, "player: sneak does not climb down")

	-- And what a mod has multiplied the movement by: no gravity is no
	-- falling at all, and twice the speed is twice as fast once the
	-- acceleration has got there
	local floating = M.new(nothing_stops)
	floating.override = {gravity = 0}
	local slow = M.new(nothing_stops)
	local quick = M.new(nothing_stops)
	quick.override = {speed = 2}
	for _ = 1, 50 do
		floating:update(0.1, {x = 0, z = 0})
		slow:update(0.1, {x = 1, z = 0})
		quick:update(0.1, {x = 1, z = 0})
	end
	assert(math.abs(floating.vy) < 1e-9,
			"player: a gravity override of zero still pulls")
	assert(quick.vx > slow.vx * 1.9,
			"player: the speed override does nothing")
end

return M
-- vim: set noet ts=4 sw=4:
