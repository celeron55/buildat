-- Buildat: builtin/luanti/lua/entity.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The objects: everything in a Luanti world that is not a node. A mod
-- registers an entity and adds one to the map, and from then on it is a
-- luaentity -- a table of the mod's own -- and an ObjectRef, which is the
-- handle everything else holds it by.
--
-- In Luanti this half is C++ and only the prototypes are Lua. Here it is all
-- Lua: an object is a position, a velocity, an acceleration and a box, and
-- the step moves it and tells it what it ran into. That is what the vendored
-- builtin's own entities are written against -- the dropped item and the
-- falling node -- and they are the ones that make a dig and a dug-out
-- support do anything at all.
--
-- simplified, and each is its own milestone rather than a corner cut here:
--
-- * Nothing draws them. The objects are the server's; the client half of the
--   module is what would show them, and until it does a world with an item
--   in it looks empty. Nothing in here depends on that being true.
-- * Nothing saves them. Luanti writes an object into the block it is in and
--   reads it back when the block loads; here the world is loaded whole for
--   the run, so static_save, get_staticdata and the dtime_s an on_activate
--   is given have nothing to be different about yet. M6's map is where they
--   start to.
-- * No players and no attachments, so collide_with_objects, the parent and
--   child of an attachment, and everything a player would point at are the
--   empty answer rather than an answer.
-- * The collision is axis by axis against the voxels a box overlaps, with no
--   stepping up and no sliding along a corner. An item lands on the floor
--   and stays out of a wall, which is what the builtin's entities ask about.

local objects = {}      -- id -> the object's own state
local next_id = 1

local __show_objects = __luanti_show_objects

-- What an entity gets until its initial_properties and set_properties say
-- otherwise. The names are Luanti's, and the ones nothing here reads are
-- kept so that a mod's get_properties() answers with what it set.
local DEFAULT_PROPERTIES = {
	hp_max = 1,
	breath_max = 0,
	physical = false,
	collide_with_objects = true,
	collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
	selectionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
	pointable = true,
	visual = "sprite",
	visual_size = {x = 1, y = 1, z = 1},
	textures = {},
	colors = {},
	spritediv = {x = 1, y = 1},
	initial_sprite_basepos = {x = 0, y = 0},
	is_visible = true,
	makes_footstep_sound = false,
	automatic_rotate = 0,
	stepheight = 0,
	static_save = true,
	shaded = true,
	show_on_minimap = false,
}

local function vec(v)
	return {x = v.x or 0, y = v.y or 0, z = v.z or 0}
end

--
-- ObjectRef
--

local ObjectRef = {}
ObjectRef.__index = ObjectRef

-- A removed object's handle stays valid to hold and answers with nothing,
-- because a mod keeps one across a step as a matter of course
local function state_of(ref)
	return objects[ref.__id]
end

function ObjectRef:is_valid()
	return state_of(self) ~= nil
end

function ObjectRef:get_pos()
	local o = state_of(self)
	return o and vec(o.pos) or nil
end

function ObjectRef:set_pos(pos)
	local o = state_of(self)
	if o then
		o.pos = vec(pos)
	end
end

function ObjectRef:move_to(pos, continuous)
	self:set_pos(pos)
end

function ObjectRef:get_velocity()
	local o = state_of(self)
	return o and vec(o.vel) or nil
end

function ObjectRef:set_velocity(vel)
	local o = state_of(self)
	if o then
		o.vel = vec(vel)
	end
end

function ObjectRef:add_velocity(vel)
	local o = state_of(self)
	if o then
		o.vel = {x = o.vel.x + (vel.x or 0), y = o.vel.y + (vel.y or 0),
				z = o.vel.z + (vel.z or 0)}
	end
end

function ObjectRef:get_acceleration()
	local o = state_of(self)
	return o and vec(o.acc) or nil
end

function ObjectRef:set_acceleration(acc)
	local o = state_of(self)
	if o then
		o.acc = vec(acc)
	end
end

function ObjectRef:get_rotation()
	local o = state_of(self)
	return o and vec(o.rot) or nil
end

function ObjectRef:set_rotation(rot)
	local o = state_of(self)
	if o then
		o.rot = vec(rot)
	end
end

function ObjectRef:get_yaw()
	local o = state_of(self)
	return o and o.rot.y or nil
end

function ObjectRef:set_yaw(yaw)
	local o = state_of(self)
	if o then
		o.rot.y = yaw
	end
end

function ObjectRef:get_properties()
	local o = state_of(self)
	return o and table.copy(o.props) or nil
end

function ObjectRef:set_properties(props)
	local o = state_of(self)
	if not o or type(props) ~= "table" then
		return
	end
	for k, v in pairs(props) do
		o.props[k] = v
	end
	if props.hp_max and o.hp > props.hp_max then
		o.hp = props.hp_max
	end
end

function ObjectRef:get_armor_groups()
	local o = state_of(self)
	return o and table.copy(o.armor_groups) or nil
end

function ObjectRef:set_armor_groups(groups)
	local o = state_of(self)
	if o then
		o.armor_groups = table.copy(groups or {})
	end
end

function ObjectRef:get_hp()
	local o = state_of(self)
	return o and o.hp or 0
end

function ObjectRef:set_hp(hp, reason)
	local o = state_of(self)
	if not o then
		return
	end
	o.hp = math.max(0, math.min(hp, o.props.hp_max or 1))
	if o.hp == 0 and o.le and o.le.on_death then
		o.le:on_death(nil)
	end
	if o.hp == 0 then
		self:remove()
	end
end

function ObjectRef:punch(puncher, time_from_last_punch, tool_capabilities, dir)
	local o = state_of(self)
	if o and o.le and o.le.on_punch then
		o.le:on_punch(puncher, time_from_last_punch, tool_capabilities, dir)
	end
end

function ObjectRef:right_click(clicker)
	local o = state_of(self)
	if o and o.le and o.le.on_rightclick then
		o.le:on_rightclick(clicker)
	end
end

function ObjectRef:get_luaentity()
	local o = state_of(self)
	return o and o.le or nil
end

function ObjectRef:get_entity_name()
	local o = state_of(self)
	return o and o.le and o.le.name or nil
end

function ObjectRef:is_player()
	return false
end

function ObjectRef:remove()
	local o = state_of(self)
	if not o then
		return
	end
	objects[o.id] = nil
	core.luaentities[o.id] = nil
	core.object_refs[o.id] = nil
	if o.le and o.le.on_deactivate then
		o.le:on_deactivate(true)
	end
end

-- The ones there is nothing here to do: what they change is how an object
-- looks, and nothing draws it yet. They answer rather than being missing,
-- because a mod that sets a texture and carries on should carry on.
for _, name in ipairs({
	"set_texture_mod", "set_sprite", "set_animation",
	"set_animation_frame_speed", "set_bone_position", "set_bone_override",
	"set_attach", "set_detach", "set_nametag_attributes", "set_observers",
	"set_bone_rotation", "set_local_animation", "set_eye_offset",
}) do
	ObjectRef[name] = function() end
end

function ObjectRef:get_texture_mod() return "" end
function ObjectRef:get_animation() return {x = 1, y = 1}, 15, 0, true end
function ObjectRef:get_attach() return nil end
function ObjectRef:get_bone_position() return vec({}), vec({}) end
function ObjectRef:get_bone_override() return nil end
function ObjectRef:get_children() return {} end
function ObjectRef:get_nametag_attributes() return {text = "", color = nil} end
function ObjectRef:get_observers() return nil end

--
-- The map of them
--

function core.add_entity(pos, name, staticdata)
	local proto = core.registered_entities[name]
	if proto == nil then
		core.log("error", "add_entity(): no entity called " .. tostring(name))
		return nil
	end
	local id = next_id
	next_id = id + 1
	local ref = setmetatable({__id = id}, ObjectRef)
	local o = {
		id = id,
		ref = ref,
		pos = vec(pos),
		vel = {x = 0, y = 0, z = 0},
		acc = {x = 0, y = 0, z = 0},
		rot = {x = 0, y = 0, z = 0},
		props = table.copy(DEFAULT_PROPERTIES),
		armor_groups = {},
		hp = 1,
	}
	objects[id] = o
	-- The luaentity is the prototype's own table copied per object, which is
	-- what makes self.whatever a field of this one and not of every one
	local le = table.copy(proto)
	le.name = name
	le.object = ref
	o.le = le
	core.luaentities[id] = le
	core.object_refs[id] = ref
	if proto.initial_properties then
		ref:set_properties(proto.initial_properties)
	end
	o.hp = o.props.hp_max or 1
	if le.on_activate then
		local ok, err = pcall(le.on_activate, le, staticdata or "", 0)
		if not ok then
			core.log("error", "on_activate: " .. tostring(err))
		end
	end
	-- on_activate may have removed it, and then there is nothing to hand back
	if objects[id] == nil then
		return nil
	end
	return ref
end

function core.add_item(pos, item)
	return core.spawn_item(pos, item)
end

local function object_list(match)
	local list = {}
	for _, o in pairs(objects) do
		if match(o.pos) then
			list[#list + 1] = o.ref
		end
	end
	return list
end

function core.get_objects_inside_radius(pos, radius)
	local r2 = radius * radius
	return object_list(function(p)
		local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z - pos.z
		return dx * dx + dy * dy + dz * dz <= r2
	end)
end

function core.get_objects_in_area(min_pos, max_pos)
	return object_list(function(p)
		return p.x >= min_pos.x and p.x <= max_pos.x and
				p.y >= min_pos.y and p.y <= max_pos.y and
				p.z >= min_pos.z and p.z <= max_pos.z
	end)
end

--
-- The step
--

-- A voxel stops a box if its definition says walkable. An unknown one --
-- "ignore", which is what the void reads as -- does not, because a world
-- that has not been generated is not a floor.
local function voxel_walkable(x, y, z)
	local def = core.registered_nodes[core.get_node({x = x, y = y, z = z}).name]
	return def ~= nil and def.walkable ~= false
end

-- A node at p fills the voxel from p-0.5 to p+0.5, so the voxels a box
-- overlaps are the ones its corners round to. The shrink is what keeps a box
-- resting exactly on a surface from being inside it.
local SHRINK = 0.001

local function box_range(lo, hi)
	return math.floor(lo + SHRINK + 0.5), math.floor(hi - SHRINK + 0.5)
end

-- The voxel the box ran into, taken along axis i in direction dir so that
-- the one that stops it first is the one that answers
local function box_blocker(pos, box, i, dir)
	local x0, x1 = box_range(pos.x + box[1], pos.x + box[4])
	local y0, y1 = box_range(pos.y + box[2], pos.y + box[5])
	local z0, z1 = box_range(pos.z + box[3], pos.z + box[6])
	local best = nil
	for z = z0, z1 do
		for y = y0, y1 do
			for x = x0, x1 do
				if voxel_walkable(x, y, z) then
					local p = {x = x, y = y, z = z}
					if best == nil or (dir > 0 and p[i] < best[i]) or
							(dir < 0 and p[i] > best[i]) then
						best = p
					end
				end
			end
		end
	end
	return best
end

local AXIS_MIN = {x = 1, y = 2, z = 3}
local AXIS_MAX = {x = 4, y = 5, z = 6}

local function move_axis(o, i, d, box, result)
	if d == 0 then
		return
	end
	local was = o.pos[i]
	o.pos[i] = was + d
	local hit = box_blocker(o.pos, box, i, d)
	if hit == nil then
		return
	end
	-- Put it against the face it ran into rather than back where it was, so
	-- that a falling thing comes to rest on the floor and not above it
	if d > 0 then
		o.pos[i] = hit[i] - 0.5 - box[AXIS_MAX[i]] - SHRINK
	else
		o.pos[i] = hit[i] + 0.5 - box[AXIS_MIN[i]] + SHRINK
	end
	if (d > 0 and o.pos[i] < was) or (d < 0 and o.pos[i] > was) then
		-- It was already inside; leave it where it was rather than pushing
		-- it further in. The builtin's item entity looks for this and works
		-- itself out of a node it is stuck in.
		o.pos[i] = was
	end
	local old_v = vec(o.vel)
	o.vel[i] = 0
	result.collides = true
	if i == "y" and d < 0 then
		result.touching_ground = true
	end
	result.collisions[#result.collisions + 1] = {
		type = "node",
		axis = i,
		node_pos = hit,
		new_pos = vec(o.pos),
		old_velocity = old_v,
		new_velocity = vec(o.vel),
	}
end

local function step_object(o, dtime)
	local props = o.props
	o.vel = {
		x = o.vel.x + o.acc.x * dtime,
		y = o.vel.y + o.acc.y * dtime,
		z = o.vel.z + o.acc.z * dtime,
	}
	local dx, dy, dz = o.vel.x * dtime, o.vel.y * dtime, o.vel.z * dtime
	local moveresult = nil
	if props.physical then
		local box = props.collisionbox or DEFAULT_PROPERTIES.collisionbox
		moveresult = {
			touching_ground = false,
			collides = false,
			standing_on_object = false,
			collisions = {},
		}
		-- Axis at a time, y last, so that a box sliding along the floor is
		-- not stopped by the floor it is already resting on
		move_axis(o, "x", dx, box, moveresult)
		move_axis(o, "z", dz, box, moveresult)
		move_axis(o, "y", dy, box, moveresult)
	else
		o.pos = {x = o.pos.x + dx, y = o.pos.y + dy, z = o.pos.z + dz}
	end
	if o.le and o.le.on_step then
		core.set_last_run_mod(o.le.mod_origin)
		local ok, err = pcall(o.le.on_step, o.le, dtime, moveresult)
		if not ok then
			core.log("error", "entity " .. tostring(o.le.name) .. ": " ..
					tostring(err))
		end
	end
end

-- Where every object is and how big it is, once per step: the module puts a
-- node in the scene for each, and the scene is what every client is already
-- being sent. A box the size of the collision box, because what an object
-- looks like is the client half's and this is what says where they are
-- until then.
-- Whether anything was on screen last time, so that a world with no objects
-- in it -- which is most of a step -- does not cross into the module and
-- out to the scene twenty times a second to say so
local anything_shown = false

local function show_objects()
	local v = {}
	for id, o in pairs(objects) do
		local box = o.props.collisionbox or DEFAULT_PROPERTIES.collisionbox
		if o.props.is_visible == false then
			box = nil
		end
		if box then
			-- The node is at the middle of the box and scaled to its size,
			-- and a zero side would be a node nobody can see anyway
			local sx = math.max(box[4] - box[1], 0.05)
			local sy = math.max(box[5] - box[2], 0.05)
			local sz = math.max(box[6] - box[3], 0.05)
			v[#v + 1] = id
			v[#v + 1] = o.pos.x + (box[1] + box[4]) / 2
			v[#v + 1] = o.pos.y + (box[2] + box[5]) / 2
			v[#v + 1] = o.pos.z + (box[3] + box[6]) / 2
			v[#v + 1] = sx
			v[#v + 1] = sy
			v[#v + 1] = sz
		end
	end
	if #v == 0 and not anything_shown then
		return
	end
	anything_shown = #v > 0
	__show_objects(v)
end

function core.__step_objects(dtime)
	-- Over the ids taken first, because a step adds and removes objects
	local ids = {}
	for id, _ in pairs(objects) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local o = objects[id]
		if o then
			step_object(o, dtime)
		end
	end
	show_objects()
end

-- vim: set noet ts=4 sw=4:
