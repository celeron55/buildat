-- Buildat: extension/luanti_client/particles.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's particle descriptions, out of ADD_PARTICLESPAWNER and
-- SPAWN_PARTICLE.
--
-- The wire format is ParticleParameters::deSerialize and
-- Client::handleCommand_AddParticleSpawner in Luanti's own source. The layout
-- is built out of three shapes, which is what most of this file is:
--   value  -- one f32, or three of them for a vector
--   range  -- min, max, and a bias that skews where inside them a pick lands
--   tween  -- a style, a repetition count, an offset, and a start and an end
-- so a spawner's position is a tween of a range of vectors: fifteen floats.
--
-- Everything after the fields read here is optional on the wire: Luanti's own
-- reader stops when the stream runs out, which is what lets an older client
-- read a newer server's packet. This stops at the node fields for the same
-- reason -- drag, jitter, bounce, the attractors and the texture pool are
-- past that point and are not read.
--
-- simplified: only protocol 42 and up, which is Luanti 5.6 and up. Before
-- that the tweens are not on the wire at all and the ranges are laid out
-- differently; a spawner from such a server is dropped rather than read
-- wrong. See doc/luanti_client.txt for which servers this client is for.

local M = {}

M.MIN_PROTOCOL = 42

-- style, in Luanti's TweenStyle order
M.TWEEN_FORWARD = 0
M.TWEEN_REVERSE = 1
M.TWEEN_PULSE = 2
M.TWEEN_FLICKER = 3

local function read_range(r, read_value)
	local min = read_value(r)
	local max = read_value(r)
	return {min = min, max = max, bias = r:f32()}
end

local function read_tween(r, read_inner)
	local style = r:u8()
	if style >= 4 then
		style = M.TWEEN_FORWARD
	end
	local reps = r:u16()
	local beginning = r:f32()
	return {style = style, reps = reps, beginning = beginning,
			start = read_inner(r), stop = read_inner(r)}
end

local function read_f32(r)
	return r:f32()
end

local function read_v3f(r)
	local x, y, z = r:v3f()
	return {x, y, z}
end

local function read_f32_range(r)
	return read_range(r, read_f32)
end

local function read_v3f_range(r)
	return read_range(r, read_v3f)
end

-- parse_particle(r, protocol) -> a description of one particle
--
-- One particle has no ranges and no tweens: it is where it is and it moves
-- the way it moves. This is ParticleParameters::deSerialize.
function M.parse_particle(r, protocol)
	local p = {}
	p.pos = read_v3f(r)
	p.vel = read_v3f(r)
	p.acc = read_v3f(r)
	p.exptime = r:f32()
	p.size = r:f32()
	p.collision = r:u8() ~= 0
	p.texture = r:longstring()
	p.vertical = r:u8() ~= 0
	p.collision_removal = r:u8() ~= 0
	p.animation = r:animation()
	p.glow = r:u8()
	p.object_collision = r:u8() ~= 0
	-- The optional tail: which node the particle is a piece of, for a
	-- particle that wears a node's texture rather than one of its own
	if r:remaining() >= 4 then
		p.node_param0 = r:u16()
		p.node_param2 = r:u8()
		p.node_tile = r:u8()
	end
	return p
end

-- parse_spawner(r, protocol) -> a description of a spawner, or nil
--
-- What comes back has, per field, either a plain value or a tween of a range;
-- the caller picks what it can use. server_id is the id the server will
-- delete it by, and attached is the object it follows, or 0 for none.
function M.parse_spawner(r, protocol)
	if protocol < M.MIN_PROTOCOL then
		return nil, "protocol "..protocol.." is older than "..M.MIN_PROTOCOL
	end
	local p = {}
	p.amount = r:u16()
	p.time = r:f32()
	if p.time < 0 then
		return nil, "time < 0"
	end
	p.pos = read_tween(r, read_v3f_range)
	p.vel = read_tween(r, read_v3f_range)
	p.acc = read_tween(r, read_v3f_range)
	p.exptime = read_tween(r, read_f32_range)
	p.size = read_tween(r, read_f32_range)
	p.collision = r:u8() ~= 0
	p.texture = r:longstring()
	p.server_id = r:u32()
	p.vertical = r:u8() ~= 0
	p.collision_removal = r:u8() ~= 0
	p.attached = r:u16()
	p.animation = r:animation()
	p.glow = r:u8()
	p.object_collision = r:u8() ~= 0
	if r:remaining() >= 4 then
		p.node_param0 = r:u16()
		p.node_param2 = r:u8()
		p.node_tile = r:u8()
	end
	return p
end

-- speed_range(vel_min, vel_max) -> the slowest and the fastest a velocity
-- inside that box can be.
--
-- What wants it is Urho3D, which takes a particle's velocity as a direction
-- and a speed and normalizes the direction: a range of velocity *vectors*
-- has to be handed over as the box the direction is picked from plus the
-- magnitudes that box holds. Without the second half every particle leaves
-- at one node a second whatever the game asked for.
--
-- simplified: the speed is then picked independently of the direction, so a
-- particle aimed along a short axis of the box can come out as fast as one
-- aimed along a long one. Exact for a single particle, where the box is one
-- vector.
function M.speed_range(vel_min, vel_max)
	local near, far = 0, 0
	for i = 1, 3 do
		local lo, hi = vel_min[i], vel_max[i]
		local a = math.abs(lo)
		local b = math.abs(hi)
		-- Nothing has to travel along this axis at all when the range
		-- crosses zero; otherwise the shorter end is as slow as it gets
		local closest = (lo <= 0 and hi >= 0) and 0 or math.min(a, b)
		near = near + closest * closest
		far = far + math.max(a, b) * math.max(a, b)
	end
	return math.sqrt(near), math.sqrt(far)
end

-- The middle of a range, and the middle of a tween's starting range: what a
-- description that has no room for a range or a tween gets out of one.
function M.middle(range)
	local min, max = range.min, range.max
	if type(min) == "table" then
		return {(min[1] + max[1]) / 2, (min[2] + max[2]) / 2,
				(min[3] + max[3]) / 2}
	end
	return (min + max) / 2
end

return M
-- vim: set noet ts=4 sw=4:
