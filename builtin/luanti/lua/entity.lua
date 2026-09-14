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
-- * No attachments, so collide_with_objects and the parent and child of an
--   attachment are the empty answer rather than an answer.
-- * The collision is axis by axis against the voxels a box overlaps, with no
--   stepping up and no sliding along a corner. An item lands on the floor
--   and stays out of a wall, which is what the builtin's entities ask about.

local objects = {}      -- id -> the object's own state
local next_id = 1

local __show_objects = __luanti_show_objects
local __show_object_props = __luanti_show_object_props
local __send_inventory = __luanti_send_inventory
local __send_player_pos = __luanti_send_player_pos

-- The client's own bars: how much life and breath the player has. Luanti
-- sends these as their own packets and draws hearts and bubbles for them;
-- what a game draws instead is the HUD elements above, and the healthbar
-- and breathbar flags are how it says so.
-- Defined where the rest of the HUD is sent, far below; a player's hotbar is
-- set from up here as well
local send_hotbar

local function send_stats(o)
	if o and o.player_name and __luanti_send_hud then
		__luanti_send_hud(o.player_name, {"stats",
				tostring(o.hp or 0),
				tostring((o.props and o.props.hp_max) or 20),
				tostring(o.breath or 10),
				tostring((o.props and o.props.breath_max) or 10)})
	end
end

-- What Luanti's server tells a mod when something about a player changed.
-- The names are its own, and its own builtin listens: the hearts and the
-- bubbles on the screen are statbar HUD elements that the builtin adds,
-- changes and takes away as these arrive. Without them a player's health
-- is drawn once, at whatever it was when they joined.
local function player_event(o, name)
	if not o or not o.ref then
		return
	end
	for _, cb in ipairs(core.registered_playerevents or {}) do
		local ok, err = pcall(cb, o.ref, name)
		if not ok then
			core.log("error", "playerevent " .. name .. ": " .. tostring(err))
		end
	end
end

local __show_formspec = __luanti_show_formspec
local __player_formspec = __luanti_player_formspec
local __send_node_inventory = __luanti_send_node_inventory

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
	-- The rest of Luanti's own defaults, whether or not anything here reads
	-- them: a mod reads its own object's properties back and does
	-- arithmetic on what it gets. VoxeLibre's environmental sounds add
	-- eye_height to the player's position at every join, and with that one
	-- missing the whole callback died on "arithmetic on a nil value" --
	-- which is what a default nobody thought was needed looks like from the
	-- other side. See src/object_properties.h in Luanti.
	eye_height = 1.625,
	zoom_fov = 0,
	glow = 0,
	backface_culling = true,
	use_texture_alpha = false,
	damage_texture_modifier = "^[brighten",
	nametag = "",
	nametag_color = "#ffffffff",
	infotext = "",
	wield_item = "",
	mesh = "",
	automatic_face_movement_dir = false,
	automatic_face_movement_max_rotation_per_sec = -1,
	rotate_selectionbox = false,
	nametag_scale_z = false,
}

local function vec(v)
	return {x = v.x or 0, y = v.y or 0, z = v.z or 0}
end

-- What the API hands back: a vector with its metatable, because a mod calls
-- methods on what it is given -- pos:round(), pos:offset(0, 5, 0). The
-- vendored builtin is what has vector, so this is a call and not a copy of
-- one made while this file loaded.
local function out_vec(v)
	return vector.new(v.x, v.y, v.z)
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
	return o and out_vec(o.pos) or nil
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
	return o and out_vec(o.vel) or nil
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
	return o and out_vec(o.acc) or nil
end

function ObjectRef:set_acceleration(acc)
	local o = state_of(self)
	if o then
		o.acc = vec(acc)
	end
end

function ObjectRef:get_rotation()
	local o = state_of(self)
	return o and out_vec(o.rot) or nil
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
	-- With the metatables, because a property can be a vector and a mod
	-- reading one back expects what it put in
	local o = state_of(self)
	return o and table.copy_with_metatables(o.props) or nil
end

-- The properties Luanti keeps as vectors rather than as whatever table a
-- mod handed over: a mod setting one from a plain table reads a vector back
local PROPERTY_VECTOR2 = {spritediv = true, initial_sprite_basepos = true}
local PROPERTY_VECTOR3 = {visual_size = true}

function ObjectRef:set_properties(props)
	local o = state_of(self)
	if not o or type(props) ~= "table" then
		return
	end
	for k, v in pairs(props) do
		if PROPERTY_VECTOR2[k] and type(v) == "table" then
			v = vector2.new(v.x or v[1] or 0, v.y or v[2] or 0)
		elseif PROPERTY_VECTOR3[k] and type(v) == "table" then
			v = vector.new(v.x or v[1] or 0, v.y or v[2] or 0, v.z or v[3] or 0)
		end
		o.props[k] = v
	end
	if props.hp_max and o.hp > props.hp_max then
		o.hp = props.hp_max
	end
	if o.player_name then
		player_event(o, "properties_changed")
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
		-- Who did it, which a mod reads to know what killed its mob; the
		-- hit points are already zero here, which is what Luanti's own
		-- on_death sees too
		o.le:on_death(type(reason) == "table" and reason.object or nil)
	end
	if o.hp == 0 then
		self:remove()
	end
end

-- A punch is the entity's own on_punch first, and the damage the tool does
-- second -- unless the entity says it dealt with it, which is what returning
-- true from on_punch means in Luanti. What the damage is is
-- core.get_hit_params(), rated by this object's armour groups.
function ObjectRef:punch(puncher, time_from_last_punch, tool_capabilities, dir)
	local o = state_of(self)
	if not o then
		return
	end
	-- What it would do is worked out first, because on_punch is told: a mod
	-- that draws a damage number reads that argument and not the hit points
	local hit = core.get_hit_params(o.armor_groups, tool_capabilities,
			time_from_last_punch)
	local handled = false
	if o.le and o.le.on_punch then
		handled = o.le:on_punch(puncher, time_from_last_punch,
				tool_capabilities, dir, hit.hp) and true or false
	end
	if handled or o.hp == nil then
		return
	end
	if hit.hp > 0 then
		self:set_hp(o.hp - hit.hp, {type = "punch", object = puncher})
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
	if o.guid then
		core.objects_by_guid[o.guid] = nil
	end
	if o.le and o.le.on_deactivate then
		o.le:on_deactivate(true)
	end
end

-- The ones there is nothing here to do: what they change is how an object
-- looks, and nothing draws it yet. They answer rather than being missing,
-- because a mod that sets a texture and carries on should carry on.
for _, name in ipairs({
	"set_texture_mod", "set_sprite", "set_animation",
	"set_animation_frame_speed",
	"set_nametag_attributes", "set_observers",
	"set_local_animation", "set_eye_offset",
}) do
	ObjectRef[name] = function() end
end

-- Where a bone of a model is put, which a mod sets to aim a gun, open a lid
-- or sit a rider down. Luanti keeps the newer override form and answers the
-- older position-and-rotation one out of it, which is what this does.
--
-- simplified: like the attachments above, this is what was set and read
-- back and not what is drawn -- the models are in their rest pose here. What
-- a mod cares about between one call and the next is that its own numbers
-- survive, angles included: nothing is normalised, so a rotation of a
-- thousand degrees comes back as a thousand degrees.
local function bone_property(v, default)
	return {vec = vector.new(v and v.vec or default),
			interpolation = v and v.interpolation or 0,
			absolute = v and v.absolute or false}
end

function ObjectRef:set_bone_override(bone, override)
	local o = state_of(self)
	if o == nil or bone == nil then
		return
	end
	o.bones = o.bones or {}
	if override == nil then
		o.bones[bone] = nil
		return
	end
	o.bones[bone] = {
		position = bone_property(override.position, vector.zero()),
		rotation = bone_property(override.rotation, vector.zero()),
		scale = bone_property(override.scale, vector.new(1, 1, 1)),
	}
end

function ObjectRef:get_bone_override(bone)
	local o = state_of(self)
	local have = o and o.bones and o.bones[bone] or nil
	return {
		position = bone_property(have and have.position, vector.zero()),
		rotation = bone_property(have and have.rotation, vector.zero()),
		scale = bone_property(have and have.scale, vector.new(1, 1, 1)),
	}
end

function ObjectRef:get_bone_overrides()
	local o = state_of(self)
	local out = {}
	for bone, _ in pairs(o and o.bones or {}) do
		out[bone] = self:get_bone_override(bone)
	end
	return out
end

-- The older pair, which is the same thing with the rotation in degrees
function ObjectRef:set_bone_position(bone, position, rotation)
	self:set_bone_override(bone, {
		position = {vec = position or vector.zero(), absolute = true},
		rotation = {vec = (rotation or vector.zero()):apply(math.rad),
				absolute = true},
	})
end

function ObjectRef:get_bone_position(bone)
	local override = self:get_bone_override(bone)
	return override.position.vec, override.rotation.vec:apply(math.deg)
end

-- What is riding what. A mod attaches a player to a boat, a mob to a mob and
-- an item to a hand, and reads it back; the callbacks it hears are the
-- parent's on_attach_child and on_detach_child and the child's own
-- on_detach.
--
-- simplified: this is the bookkeeping and not the drawing. Nothing moves a
-- child with its parent yet, which is M5's "attachments and bones" -- what
-- it wants is the parent's place and the bone's, and the client half has
-- neither. A mod that attaches and reads back gets what it set.
function ObjectRef:set_attach(parent, bone, position, rotation, forced_visible)
	local o = state_of(self)
	local p = parent and state_of(parent) or nil
	if o == nil or p == nil or parent == self then
		return
	end
	if o.attached_to then
		self:set_detach()
	end
	o.attached_to = {ref = parent, bone = bone, position = position,
			rotation = rotation, forced_visible = forced_visible}
	p.children = p.children or {}
	p.children[#p.children + 1] = self
	if p.le and p.le.on_attach_child then
		p.le:on_attach_child(self)
	end
end

function ObjectRef:get_attach()
	local o = state_of(self)
	local a = o and o.attached_to or nil
	if a == nil then
		return nil
	end
	return a.ref, a.bone, a.position, a.rotation, a.forced_visible
end

function ObjectRef:set_detach()
	local o = state_of(self)
	local a = o and o.attached_to or nil
	if a == nil then
		return
	end
	o.attached_to = nil
	local p = state_of(a.ref)
	if p and p.children then
		for i, child in ipairs(p.children) do
			if child == self then
				table.remove(p.children, i)
				break
			end
		end
	end
	if p and p.le and p.le.on_detach_child then
		p.le:on_detach_child(self)
	end
	if o.le and o.le.on_detach then
		o.le:on_detach(a.ref)
	end
end

function ObjectRef:get_children()
	local o = state_of(self)
	local out = {}
	for _, child in ipairs(o and o.children or {}) do
		out[#out + 1] = child
	end
	return out
end

function ObjectRef:get_guid()
	local o = state_of(self)
	return o and o.guid or nil
end

function ObjectRef:get_texture_mod() return "" end
function ObjectRef:get_animation() return {x = 1, y = 1}, 15, 0, true end




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
	-- What a mod holds an object by when a reference will not do: unique
	-- while the world runs, and in the table Luanti keeps them in.
	--
	-- simplified: it is this run's own id and not something the world
	-- remembers. Luanti's survives a restart, which is what a mod storing
	-- one in its own storage is relying on; nothing here stores objects
	-- across a run to begin with.
	o.guid = "obj" .. id
	core.objects_by_guid[o.guid] = ref
	-- The luaentity is a table of its own with the prototype as its
	-- metatable, which is what Luanti's own luaentity_Add does: what a mod
	-- sets on self belongs to this entity, and everything else is found
	-- through the prototype -- including what the prototype inherits from a
	-- class of its own, which is how every mob mod is written. A copy of
	-- the prototype would lose exactly that.
	if rawget(proto, "__index") == nil then
		proto.__index = proto
	end
	local le = setmetatable({}, proto)
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

-- One of the entities an imported world was holding, with the state its own
-- on_activate wrote. A game that does not register it says so once per kind
-- rather than per entity, which is the importer's to count, so this only
-- says whether it was made.
function core.__import_entity(x, y, z, name, staticdata)
	if core.registered_entities[name] == nil then
		return false
	end
	return core.add_entity({x = x, y = y, z = z}, name, staticdata) ~= nil
end

-- An item nobody registered is not dropped at all, which is what Luanti's
-- own l_add_item answers with nil for: a typo in a mod would otherwise put
-- an entity in the world holding nothing anybody can name.
function core.add_item(pos, item)
	local stack = ItemStack(item)
	if stack:is_empty() or not stack:is_known() then
		return nil
	end
	return core.spawn_item(pos, stack)
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
-- Players
--
-- A player is an object with somebody on the other end of it: it is in the
-- same table as the entities, so everything that looks for objects finds it,
-- and what is different is that nothing here moves it -- where a player is
-- is what their client says.
--
-- simplified: no physics, no privileges, no chat and no HUD. The client
-- half is what would draw a HUD or open a formspec, and the HUD calls here
-- keep what they are told so that a mod reading them back gets what it set.
-- Damage is what a mod does with set_hp; nothing else takes hit points off
-- a player, because nothing else knows where the player has walked.

local players = {}      -- name -> the object's id

-- Everything an object has, and the rest below
local PlayerRef = setmetatable({}, {__index = ObjectRef})
PlayerRef.__index = PlayerRef

-- Every object by the name that outlives a restart; a player's is their
-- name, which is what Luanti uses and what a mod stores
core.objects_by_guid = {}

function PlayerRef:is_player()
	return true
end

-- A player's client moves the player and says so; when the server moves one
-- instead -- a spawn, a teleport, a mod putting them somewhere -- the client
-- has to be told, or it walks on from where it thought it was.
local function tell_the_client(o)
	if o and o.player_name and __send_player_pos then
		-- And which object is theirs, because a client that cannot tell its
		-- own from the rest points at itself: it is standing inside it; and
		-- which way they are facing, which a world they have been in before
		-- saved along with where they stood
		__send_player_pos(o.player_name, o.pos.x, o.pos.y, o.pos.z, o.id,
				o.look.h, o.look.v)
	end
end

function PlayerRef:set_pos(pos)
	ObjectRef.set_pos(self, pos)
	tell_the_client(state_of(self))
end

function PlayerRef:move_to(pos, continuous)
	self:set_pos(pos)
end

function PlayerRef:get_player_name()
	local o = state_of(self)
	return o and o.player_name or ""
end

function PlayerRef:get_guid()
	return self:get_player_name()
end

function PlayerRef:get_meta()
	local o = state_of(self)
	return o and o.meta or nil
end

function PlayerRef:get_inventory()
	local o = state_of(self)
	return o and o.inventory or nil
end

function PlayerRef:add_pos(v)
	local o = state_of(self)
	if o then
		o.pos = {x = o.pos.x + (v.x or 0), y = o.pos.y + (v.y or 0),
				z = o.pos.z + (v.z or 0)}
		tell_the_client(o)
	end
end

-- Luanti builds the reason out of what the caller passed and says where the
-- change came from, and the registered callbacks see the difference before
-- the hit points move -- the difference itself, which is not clamped to the
-- range the hit points end up in.
--
-- The callbacks are not run in a pcall here, which is the one place in this
-- module where that is so: whoever called set_hp() is a mod, the callback
-- is a mod's, and an error between two of them belongs to the caller rather
-- than to the module.
function PlayerRef:set_hp(hp, reason)
	local o = state_of(self)
	if not o then
		return
	end
	local t = {}
	for k, v in pairs(type(reason) == "table" and reason or {}) do
		t[k] = v
	end
	if type(reason) == "string" then
		t.type = reason
	end
	t.type = t.type or "set_hp"
	t.from = t.from or "mod"
	local hp_max = o.props.hp_max or 20
	local change = math.floor(tonumber(hp) or 0) - o.hp
	-- Kept inside a 32-bit integer, so that asking for the smallest number
	-- there is does not become one smaller still
	change = math.max(-2147483648, math.min(2147483647, change))
	-- Damage does nothing to somebody who is already dead
	if o.hp <= 0 and change < 0 then
		return
	end
	if core.registered_on_player_hpchange then
		local modified = core.registered_on_player_hpchange(self, change, t)
		if type(modified) == "number" then
			change = modified
		end
	end
	local was = o.hp
	o.hp = math.max(0, math.min(was + change, hp_max))
	send_stats(o)
	player_event(o, "health_changed")
	if o.hp == 0 and was > 0 then
		for _, cb in ipairs(core.registered_on_dieplayers or {}) do
			cb(self, t)
		end
	end
end

function PlayerRef:get_hp()
	local o = state_of(self)
	return o and o.hp or 0
end

-- Luanti's two angles, and the directions they mean (lua_api.md,
-- get_look_vertical and get_look_horizontal): the horizontal one is
-- counter-clockwise from +Z, so it turns towards -X; the vertical one is
-- **positive downwards**, -pi/2 being straight up and pi/2 straight down.
-- This is the same vector Luanti's own l_get_look_dir() builds out of
-- (rotation.Y + 90) and -pitch.
function PlayerRef:get_look_dir()
	local o = state_of(self)
	if not o then
		return vector.new(0, 0, 1)
	end
	local h, v = o.look.h, o.look.v
	return vector.new(-math.sin(h) * math.cos(v), -math.sin(v),
			math.cos(h) * math.cos(v))
end

function PlayerRef:get_look_horizontal()
	local o = state_of(self)
	return o and o.look.h or 0
end

function PlayerRef:set_look_horizontal(h)
	local o = state_of(self)
	if o then
		o.look.h = h
	end
end

function PlayerRef:get_look_vertical()
	local o = state_of(self)
	return o and o.look.v or 0
end

function PlayerRef:set_look_vertical(v)
	local o = state_of(self)
	if o then
		o.look.v = v
	end
end

-- And the deprecated pair, which Luanti keeps and calls broken because each
-- is the other way round from the one above it: its yaw is counter-clockwise
-- from +X rather than +Z, and its pitch is positive upwards. A mod still
-- calling them gets what Luanti gives them.
function PlayerRef:get_look_yaw()
	return self:get_look_horizontal() + math.pi / 2
end

function PlayerRef:set_look_yaw(y)
	self:set_look_horizontal(y - math.pi / 2)
end

function PlayerRef:get_look_pitch()
	return -self:get_look_vertical()
end

function PlayerRef:set_look_pitch(v)
	self:set_look_vertical(-v)
end

function PlayerRef:get_wield_index()
	local o = state_of(self)
	return o and o.wield_index or 1
end

function PlayerRef:set_wield_index(i)
	local o = state_of(self)
	if o then
		o.wield_index = math.max(1, math.floor(tonumber(i) or 1))
	end
end

function PlayerRef:get_wield_list()
	return "main"
end

function PlayerRef:get_wielded_item()
	local o = state_of(self)
	if not o then
		return ItemStack()
	end
	return o.inventory:get_stack("main", o.wield_index)
end

function PlayerRef:set_wielded_item(item)
	local o = state_of(self)
	if not o then
		return false
	end
	o.inventory:set_stack("main", o.wield_index, ItemStack(item))
	return true
end

-- The hotbar is as long as the list behind it, which is what Luanti clamps
-- it to and what a mod setting it expects to read back
function PlayerRef:hud_set_hotbar_itemcount(n)
	local o = state_of(self)
	if not o then
		return false
	end
	n = math.floor(tonumber(n) or 0)
	if n < 1 then
		return false
	end
	o.hotbar = math.min(n, o.inventory:get_size("main"))
	send_hotbar(o)
	return true
end

function PlayerRef:hud_get_hotbar_itemcount()
	local o = state_of(self)
	return o and o.hotbar or 0
end

function PlayerRef:get_breath()
	local o = state_of(self)
	return o and o.breath or 0
end

function PlayerRef:set_breath(b)
	local o = state_of(self)
	if o then
		o.breath = math.max(0, math.floor(tonumber(b) or 0))
		send_stats(o)
		player_event(o, "breath_changed")
	end
end

function PlayerRef:get_physics_override()
	local o = state_of(self)
	return o and table.copy(o.physics) or nil
end

function PlayerRef:set_physics_override(t)
	local o = state_of(self)
	if o and type(t) == "table" then
		for k, v in pairs(t) do
			o.physics[k] = v
		end
	end
end

function PlayerRef:get_player_control()
	local o = state_of(self)
	local c = o and o.control
	if not c then
		return {up = false, down = false, left = false, right = false,
				jump = false, aux1 = false, sneak = false, dig = false,
				place = false, LMB = false, RMB = false, zoom = false}
	end
	-- A copy: what a mod does to the table it is given is its own business
	local out = {}
	for k, v in pairs(c) do
		out[k] = v
	end
	return out
end

-- Luanti's own bit order for the same thing; PlayerControl::getKeysPressed
-- in src/player.cpp
local CONTROL_BITS = {"up", "down", "left", "right", "jump", "aux1",
		"sneak", "dig", "place", "zoom"}

function PlayerRef:get_player_control_bits()
	local o = state_of(self)
	local c = o and o.control
	if not c then
		return 0
	end
	local bits = 0
	for i = 1, #CONTROL_BITS do
		if c[CONTROL_BITS[i]] then
			bits = bits + 2 ^ (i - 1)
		end
	end
	return bits
end

function PlayerRef:get_player_velocity()
	return self:get_velocity()
end

function PlayerRef:add_player_velocity(v)
	self:add_velocity(v)
end

function PlayerRef:get_inventory_formspec()
	local o = state_of(self)
	return o and o.inventory_formspec or ""
end

function PlayerRef:set_inventory_formspec(spec)
	local o = state_of(self)
	if o then
		o.inventory_formspec = tostring(spec or "")
	end
end

function PlayerRef:get_formspec_prepend()
	local o = state_of(self)
	return o and o.formspec_prepend or ""
end

function PlayerRef:set_formspec_prepend(spec)
	local o = state_of(self)
	if o then
		o.formspec_prepend = tostring(spec or "")
	end
end

-- What is still the client's alone, and kept nowhere: these answer with
-- nothing rather than being missing and taking a mod down on the line that
-- sets one
for _, name in ipairs({
	"set_lighting",
	"set_minimap_modes", "send_mapblock", "set_fov", "set_nametag_color",
}) do
	PlayerRef[name] = function() end
end

-- What the client draws its hotbar out of: how many slots, the picture
-- behind them and the one that marks the slot in hand. Luanti's client owns
-- the hotbar and a game only says these three things about it, which is how
-- it is here too -- the launcher draws it, and this is what it is told.
function PlayerRef:hud_set_hotbar_image(name)
	local o = state_of(self)
	if o then
		o.hotbar_image = tostring(name or "")
		send_hotbar(o)
	end
end

function PlayerRef:hud_get_hotbar_image()
	local o = state_of(self)
	return o and o.hotbar_image or ""
end

function PlayerRef:hud_set_hotbar_selected_image(name)
	local o = state_of(self)
	if o then
		o.hotbar_selected_image = tostring(name or "")
		send_hotbar(o)
	end
end

function PlayerRef:hud_get_hotbar_selected_image()
	local o = state_of(self)
	return o and o.hotbar_selected_image or ""
end

-- Luanti's own name for the same thing, which some mods use
PlayerRef.hud_set_hotbar_image_selected =
		PlayerRef.hud_set_hotbar_selected_image

--
-- The sky a game says it has
--
-- Luanti's set_sky and set_clouds. What crosses to the client is what a sky
-- is made of here: the colour overhead, the colour at the horizon and how
-- much of the sky is cloud. The rest of what a mod can say -- a skybox's six
-- textures, the sun's own texture, the stars -- is kept and answered but not
-- drawn.
local SKY_DEFAULT_DAY = "#8cb2e0"
local SKY_DEFAULT_ZENITH = "#215edb"

-- "#rrggbb", a table or a name, as three numbers between zero and one
local function sky_rgb(spec)
	if spec == nil then
		return nil
	end
	local t = core.colorspec_to_table and core.colorspec_to_table(spec)
	if t == nil then
		return nil
	end
	return string.format("%.4f,%.4f,%.4f", (t.r or 0) / 255,
			(t.g or 0) / 255, (t.b or 0) / 255)
end

local function send_sky(o)
	if not o or not o.player_name or not __luanti_send_sky then
		return
	end
	local sky = o.sky or {}
	local clouds = o.clouds_params or {}
	local sky_color = sky.sky_color or {}
	local flat = {}
	local function put(k, v)
		if v ~= nil then
			flat[#flat + 1] = k
			flat[#flat + 1] = tostring(v)
		end
	end
	put("type", sky.type or "regular")
	-- The hours of the sky, which is what makes a night sky dark: Luanti
	-- keeps a colour for the day, one for dawn and one for the night, and
	-- whoever draws it blends between them as the sun goes round
	put("night_zenith", sky_rgb(sky_color.night_sky))
	put("night_horizon", sky_rgb(sky_color.night_horizon))
	put("dawn_zenith", sky_rgb(sky_color.dawn_sky))
	put("dawn_horizon", sky_rgb(sky_color.dawn_horizon))
	-- A plain sky is one colour everywhere, which is what base_color means
	-- when the type says plain; a regular one has the two ends of a gradient
	if (sky.type or "regular") == "plain" then
		local c = sky_rgb(sky.base_color) or sky_rgb(SKY_DEFAULT_DAY)
		put("zenith", c)
		put("horizon", c)
	else
		put("zenith", sky_rgb(sky_color.day_sky) or
				sky_rgb(SKY_DEFAULT_ZENITH))
		put("horizon", sky_rgb(sky_color.day_horizon) or
				sky_rgb(SKY_DEFAULT_DAY))
	end
	-- Luanti's clouds are on unless a sky says otherwise, and how much of
	-- the sky they cover is their density
	local on = sky.clouds
	if on == nil then
		on = true
	end
	put("clouds", on and "1" or "0")
	put("density", clouds.density)
	put("cloud_color", sky_rgb(clouds.color))
	-- What is up there besides the gradient: Luanti's set_sun, set_moon and
	-- set_stars. The pictures a game gives its sun and its moon cross too:
	-- the sky's own square is what is drawn when it gives none.
	local sun = o.sun_params or {}
	local moon = o.moon_params or {}
	local stars = o.star_params or {}
	put("sun_visible", (sun.visible ~= false) and "1" or "0")
	put("sun_scale", sun.scale)
	put("sun_texture", sun.texture or "sun.png")
	put("moon_visible", (moon.visible ~= false) and "1" or "0")
	put("moon_scale", moon.scale)
	put("moon_texture", moon.texture or "moon.png")
	put("stars_visible", (stars.visible ~= false) and "1" or "0")
	put("star_count", stars.count)
	put("star_color", sky_rgb(stars.star_color))
	put("star_scale", stars.scale)
	__luanti_send_sky(o.player_name, flat)
end

-- set_sky(params) and Luanti's older set_sky(bgcolor, type, textures,
-- clouds), which is still what a good many mods call
function PlayerRef:set_sky(params, sky_type, textures, clouds)
	local o = state_of(self)
	if not o then
		return
	end
	if type(params) ~= "table" or sky_type ~= nil then
		params = {base_color = params, type = sky_type,
				textures = textures, clouds = clouds}
	end
	o.sky = table.copy(params)
	send_sky(o)
end

function PlayerRef:get_sky(as_table)
	local o = state_of(self)
	local sky = (o and o.sky) or {}
	if as_table then
		return {base_color = sky.base_color, type = sky.type or "regular",
				textures = sky.textures or {},
				clouds = sky.clouds ~= false,
				sky_color = sky.sky_color}
	end
	return sky.base_color, sky.type or "regular", sky.textures or {},
			sky.clouds ~= false
end

function PlayerRef:get_sky_color()
	local o = state_of(self)
	return ((o and o.sky) or {}).sky_color or {}
end

function PlayerRef:set_clouds(params)
	local o = state_of(self)
	if not o or type(params) ~= "table" then
		return
	end
	o.clouds_params = table.copy(params)
	send_sky(o)
end

-- Luanti's set_sun, set_moon and set_stars. What reaches the sky here is
-- whether each is there and how big it is; the rest is kept so that a mod
-- reads back what it set.
--
-- simplified: a sun or a moon is the sky shader's own square and not a
-- texture, so texture, tonemap and sunrise are kept and not drawn. What
-- would draw them is a quad at the sun's direction with the game's picture
-- on it, which is a thing the skybox does not have.
local function sky_thing_setter(field)
	return function(self, params)
		local o = state_of(self)
		if not o or type(params) ~= "table" then
			return
		end
		o[field] = table.copy(params)
		send_sky(o)
	end
end

PlayerRef.set_sun = sky_thing_setter("sun_params")
PlayerRef.set_moon = sky_thing_setter("moon_params")
PlayerRef.set_stars = sky_thing_setter("star_params")

-- Luanti's own defaults, which is what a mod that never set one reads
function PlayerRef:get_sun()
	local o = state_of(self)
	local t = (o and o.sun_params) or {}
	return {visible = t.visible ~= false,
			texture = t.texture or "sun.png",
			tonemap = t.tonemap or "sun_tonemap.png",
			sunrise = t.sunrise or "sunrisebg.png",
			sunrise_visible = t.sunrise_visible ~= false,
			scale = t.scale or 1}
end

function PlayerRef:get_moon()
	local o = state_of(self)
	local t = (o and o.moon_params) or {}
	return {visible = t.visible ~= false,
			texture = t.texture or "moon.png",
			tonemap = t.tonemap or "moon_tonemap.png",
			scale = t.scale or 1}
end

function PlayerRef:get_stars()
	local o = state_of(self)
	local t = (o and o.star_params) or {}
	return {visible = t.visible ~= false,
			count = t.count or 1000,
			star_color = t.star_color or "#ebebff69",
			scale = t.scale or 1,
			day_opacity = t.day_opacity or 0}
end

function PlayerRef:get_clouds()
	local o = state_of(self)
	local c = (o and o.clouds_params) or {}
	return {density = c.density or 0.4, color = c.color or "#fff0f0e5",
			ambient = c.ambient or "#000000", height = c.height or 120,
			thickness = c.thickness or 16,
			speed = c.speed or {x = 0, z = -2}}
end

--
-- The HUD a game draws itself
--
-- Luanti's HUD is a list of elements per player -- an image, a line of
-- text, a bar of icons -- that the server adds, changes and takes away, and
-- a set of flags saying which of the client's own the game wants drawn.
-- What goes over the wire here is the element as a flat list of strings,
-- under the names Luanti's own HUDADD carries rather than the ones a mod
-- writes: pos, align, dir and the rest. The client half keeps them and
-- whoever is drawing draws them.

local HUD_FLAG = {
	hotbar = 1, healthbar = 2, crosshair = 4, wielditem = 8, breathbar = 16,
	minimap = 32, minimap_radar = 64, basic_debug = 128, chat = 256,
}
local HUD_FLAGS_ALL = 511

local function v2_string(v)
	if type(v) ~= "table" then
		return nil
	end
	return tostring(v.x or 0) .. "," .. tostring(v.y or 0)
end

local function v3_string(v)
	if type(v) ~= "table" then
		return nil
	end
	return tostring(v.x or 0) .. "," .. tostring(v.y or 0) .. "," ..
			tostring(v.z or 0)
end

-- A mod's element as the names the wire carries; nil is left out
local function hud_fields(def)
	local kind = tostring(def.type or def.hud_elem_type or "text")
	-- A waypoint keeps its precision in the item field, which is what
	-- Luanti's own read_hud_element does with it: item is precision plus
	-- one, and an item of zero means ten
	local item = def.item
	if kind == "waypoint" and def.precision ~= nil then
		item = (tonumber(def.precision) or 0) + 1
	end
	return {
		type = kind,
		pos = v2_string(def.position),
		name = def.name and tostring(def.name) or nil,
		scale = v2_string(def.scale),
		text = def.text and tostring(def.text) or nil,
		text2 = def.text2 and tostring(def.text2) or nil,
		number = def.number and tostring(def.number) or nil,
		item = item and tostring(item) or nil,
		dir = def.direction and tostring(def.direction) or nil,
		align = v2_string(def.alignment),
		offset = v2_string(def.offset),
		world_pos = v3_string(def.world_pos),
		size = v2_string(def.size),
		z_index = def.z_index and tostring(def.z_index) or nil,
		style = def.style and tostring(def.style) or nil,
	}
end

-- What a game said the light should be whatever the hour, or nothing
local function send_day_night(o)
	if o and o.player_name and __luanti_send_day_night then
		__luanti_send_day_night(o.player_name,
				o.day_night_ratio and tostring(o.day_night_ratio) or "")
	end
end

local function send_hud(o, flat)
	if o and o.player_name and __luanti_send_hud then
		__luanti_send_hud(o.player_name, flat)
	end
end

-- The hotbar is the client's own and not one of the elements, so it travels
-- as one line of its own rather than through hud_add()
send_hotbar = function(o)
	send_hud(o, {"hotbar", tostring(o.hotbar or 8),
			tostring(o.hotbar_image or ""),
			tostring(o.hotbar_selected_image or "")})
end

-- What a client that arrives is told: every element the game had already
-- added for this player, and the flags
local function send_whole_hud(o)
	if not o then
		return
	end
	send_hud(o, {"clear"})
	for id, def in pairs(o.hud or {}) do
		local flat = {"add", tostring(id)}
		for k, v in pairs(hud_fields(def)) do
			flat[#flat + 1] = k
			flat[#flat + 1] = v
		end
		send_hud(o, flat)
	end
	send_hud(o, {"flags", tostring(o.hud_flags or HUD_FLAGS_ALL)})
	send_hotbar(o)
end

function PlayerRef:hud_add(def)
	local o = state_of(self)
	if not o or type(def) ~= "table" then
		return nil
	end
	o.hud = o.hud or {}
	o.hud_next = (o.hud_next or 0) + 1
	local id = o.hud_next
	o.hud[id] = table.copy(def)
	local flat = {"add", tostring(id)}
	for k, v in pairs(hud_fields(def)) do
		flat[#flat + 1] = k
		flat[#flat + 1] = v
	end
	send_hud(o, flat)
	return id
end

function PlayerRef:hud_remove(id)
	local o = state_of(self)
	if not o or o.hud == nil or o.hud[id] == nil then
		return
	end
	o.hud[id] = nil
	send_hud(o, {"remove", tostring(id)})
end

function PlayerRef:hud_change(id, stat, value)
	local o = state_of(self)
	local def = o and o.hud and o.hud[id]
	if not def then
		return nil
	end
	-- A mod names the field the way it wrote it in the definition, and the
	-- wire carries Luanti's own name for it
	local WIRE = {position = "pos", alignment = "align", direction = "dir",
			hud_elem_type = "type"}
	def[stat] = value
	local key = WIRE[stat] or stat
	local fields = hud_fields(def)
	local v = fields[key]
	if v == nil then
		return nil
	end
	send_hud(o, {"change", tostring(id), key, v})
	return id
end

function PlayerRef:hud_get(id)
	local o = state_of(self)
	return o and o.hud and o.hud[id] or nil
end

function PlayerRef:hud_set_flags(flags)
	local o = state_of(self)
	if not o or type(flags) ~= "table" then
		return
	end
	local value = o.hud_flags or HUD_FLAGS_ALL
	for name, bit in pairs(HUD_FLAG) do
		if flags[name] ~= nil then
			local has = math.floor(value / bit) % 2 == 1
			if flags[name] and not has then
				value = value + bit
			elseif not flags[name] and has then
				value = value - bit
			end
		end
	end
	o.hud_flags = value
	send_hud(o, {"flags", tostring(value)})
	player_event(o, "hud_changed")
end

function PlayerRef:hud_get_flags()
	local o = state_of(self)
	local value = (o and o.hud_flags) or HUD_FLAGS_ALL
	local out = {}
	for name, bit in pairs(HUD_FLAG) do
		out[name] = math.floor(value / bit) % 2 == 1
	end
	return out
end
function PlayerRef:get_lighting() return {shadows = {intensity = 0}} end
-- How much of the day's light the player gets whatever the hour: Luanti's
-- own way for a game to say "this place is always dark" or "always bright",
-- and nil gives the clock back. What it moves is the light, not the sun --
-- the sun goes where the time says either way, which is what Luanti does.
function PlayerRef:override_day_night_ratio(ratio)
	local o = state_of(self)
	if not o then
		return
	end
	if ratio == nil then
		o.day_night_ratio = nil
	else
		o.day_night_ratio = math.max(0, math.min(1, tonumber(ratio) or 1))
	end
	send_day_night(o)
end

function PlayerRef:get_day_night_ratio()
	local o = state_of(self)
	return o and o.day_night_ratio or nil
end
function PlayerRef:get_fov() return 0, false, 0 end
function PlayerRef:get_eye_offset()
	return {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
end

--
-- A player in the save
--
-- What Luanti's player database holds -- where a player is, which way they
-- are looking, their health, their breath, what a mod wrote on them and what
-- is in their inventory -- kept by name, so that it outlives both the
-- client's connection and the run. Step 5d of
-- doc/plan/world_persistence_plan.md.
--
-- simplified: written when a player leaves and at shutdown, not on a timer,
-- so a server that is killed loses what changed since. The clock beside it in
-- the save is written the same way and names the same upgrade path.

local saved_players = {}

local function snapshot_player(o)
	local lists = {}
	for list_name, stacks in pairs(o.inventory:get_lists()) do
		local as_strings = {}
		for i, stack in ipairs(stacks) do
			as_strings[i] = stack:to_string()
		end
		lists[list_name] = as_strings
	end
	local fields = {}
	for k, v in pairs(o.meta.fields) do
		fields[k] = v
	end
	return {
		-- Always where they are: the client is the player and a client is
		-- always somewhere, so this is the position their client last
		-- reported. Where a player who has never been here starts is the
		-- spawn search's business and not this one's.
		pos = {x = o.pos.x, y = o.pos.y, z = o.pos.z},
		look = {h = o.look.h, v = o.look.v},
		hp = o.hp,
		breath = o.breath,
		wield_index = o.wield_index,
		fields = fields,
		inventory = lists,
	}
end

-- The other direction, onto a player who has just been made. The inventory
-- lists are item strings and the fields are strings, which is what the node
-- metadata in the save is written as too.
local function restore_player(o, saved)
	if type(saved) ~= "table" then
		return
	end
	if type(saved.pos) == "table" then
		o.pos = {x = tonumber(saved.pos.x) or 0,
				y = tonumber(saved.pos.y) or 0,
				z = tonumber(saved.pos.z) or 0}
	end
	if type(saved.look) == "table" then
		o.look = {h = tonumber(saved.look.h) or 0,
				v = tonumber(saved.look.v) or 0}
	end
	o.hp = tonumber(saved.hp) or o.hp
	o.breath = tonumber(saved.breath) or o.breath
	o.wield_index = tonumber(saved.wield_index) or o.wield_index
	for k, v in pairs(saved.fields or {}) do
		o.meta.fields[k] = v
	end
	for list_name, stacks in pairs(saved.inventory or {}) do
		o.inventory:set_size(list_name, #stacks)
		for i, str in ipairs(stacks) do
			o.inventory:set_stack(list_name, i, ItemStack(str))
		end
	end
end

-- The module calls these at shutdown and once the mods have loaded, the way
-- it does the node metadata: what an inventory holds is item strings, and an
-- item string means nothing until the mod that registered it is there.
--
-- The auth entries come along, because a privilege a mod granted is as much
-- a part of a player as their health is, and bootstrap.lua keeps them in a
-- table of its own.
function core.__save_players()
	local out = {}
	local n = 0
	for name, id in pairs(players) do
		local o = objects[id]
		if o then
			saved_players[name] = snapshot_player(o)
		end
	end
	for name, saved in pairs(saved_players) do
		out[name] = saved
		n = n + 1
	end
	return core.serialize({players = out, auth = core.__auth_entries}), n
end

function core.__load_players(data)
	local t = core.deserialize(data)
	if type(t) ~= "table" then
		return 0
	end
	local n = 0
	for name, saved in pairs(t.players or {}) do
		saved_players[name] = saved
		n = n + 1
	end
	for name, entry in pairs(t.auth or {}) do
		core.__auth_entries[name] = entry
	end
	return n
end

--
-- Formspecs
--
-- The window a mod puts on a player's screen: a string of elements the client
-- draws and sends back what was pressed in. Nothing here knows what one looks
-- like -- builtin/luanti/client_lua does.

-- Which node a player's open form is about, when it is about one. Luanti
-- calls it the form's context, and "current_name" in a formspec means it;
-- the fields of such a form go to the node rather than to the global
-- callbacks, and so do its inventory lists.
local form_nodes = {}
-- And which detached inventories its lists name, because those belong to
-- nobody and the client has to be sent them the way a node's are. Read out
-- of the spec: a list[] naming one is the only way a form can show one.
local form_detached = {}

local function detached_in_spec(spec)
	local out = {}
	for name in string.gmatch(tostring(spec or ""), "detached:([%w_%-%.:]+)") do
		out[name] = true
	end
	return out
end

local function pos_string(pos)
	return math.floor(pos.x) .. "," .. math.floor(pos.y) .. "," ..
			math.floor(pos.z)
end

function core.show_formspec(playername, formname, formspec)
	if type(playername) ~= "string" or type(formspec) ~= "string" then
		return false
	end
	form_nodes[playername] = nil
	form_detached[playername] = detached_in_spec(formspec)
	__show_formspec(playername, tostring(formname or ""), formspec, "")
	return true
end

-- The form a node carries in its own metadata, which is what a chest is.
-- Luanti's client opens one itself; here the server does, because the node
-- metadata is the server's.
local function show_node_formspec(playername, pos, formspec)
	form_nodes[playername] = {x = math.floor(pos.x), y = math.floor(pos.y),
			z = math.floor(pos.z)}
	form_detached[playername] = detached_in_spec(formspec)
	__show_formspec(playername, "", formspec,
			pos_string(form_nodes[playername]))
end

-- An empty formspec is "take it away", which is what Luanti's own protocol
-- says too
function core.close_formspec(playername, formname)
	if type(playername) ~= "string" then
		return false
	end
	form_nodes[playername] = nil
	form_detached[playername] = nil
	__show_formspec(playername, tostring(formname or ""), "", "")
	return true
end

-- What comes back, as the module hands it over: the player it was, the form
-- it was, and the fields. Luanti runs these in reverse registration order and
-- stops at the first one that says it handled the form.
function core.__player_receive_fields(playername, formname, fields)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref then
		return
	end
	-- A form a node carries goes to that node, which is where Luanti sends
	-- the fields of one too, and nowhere else
	local at = form_nodes[playername]
	if at then
		local def = core.registered_nodes[core.get_node(at).name]
		if def and def.on_receive_fields then
			local ok, err = pcall(def.on_receive_fields, at, formname, fields,
					ref)
			if not ok then
				core.log("error", "on_receive_fields: " .. tostring(err))
			end
		end
		if fields.quit then
			form_nodes[playername] = nil
		end
		return
	end
	for _, cb in ipairs(core.registered_on_player_receive_fields or {}) do
		local ok, handled = pcall(cb, ref, formname, fields)
		if not ok then
			core.log("error", "on_player_receive_fields: " .. tostring(handled))
		elseif handled then
			return
		end
	end
end

-- What the other mouse button comes to: core.item_place(), which is the
-- vendored builtin's own -- so the pointed node's on_rightclick wins if it
-- has one and is not overridden, and the player's wielded item is placed
-- otherwise. Returns whether anything happened.
--
-- simplified: no sneaking, so a node with an on_rightclick cannot be built
-- against. Luanti's client sends whether the player was holding sneak, and
-- this would be that flag.
-- When each player last punched anything, because what a punch is worth is
-- the fraction of the tool's full_punch_interval that has passed since
local last_punch = {}

-- What a click on an object comes to. The wielded item's tool capabilities
-- are what does the damage, the entity's own on_punch runs first and can say
-- it dealt with it, and the tool wears by what it did -- which is Luanti's
-- own order in LuaEntitySAO::punch().
function core.__punch_object(playername, id)
	local pid = players[playername]
	local puncher = pid and core.object_refs[pid] or nil
	local ref = core.object_refs[tonumber(id) or -1]
	if ref == nil or puncher == nil then
		return false
	end
	local wielded = puncher:get_wielded_item()
	local caps = wielded:get_tool_capabilities()
	local now = core.get_us_time() / 1000000
	-- A first punch is worth a whole interval, which is what Luanti's own
	-- "a long time ago" is
	local since = last_punch[playername] and (now - last_punch[playername]) or
			1000000
	last_punch[playername] = now
	local hit = core.get_hit_params(ref:get_armor_groups() or {}, caps, since,
			wielded:get_wear())
	ref:punch(puncher, since, caps, puncher:get_look_dir())
	if hit.wear > 0 then
		wielded:add_wear(hit.wear)
		puncher:set_wielded_item(wielded)
	end
	return true
end

function core.__use_node(playername, under, above, sneak)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref then
		return false
	end
	-- What the client was holding when it clicked. Luanti's own
	-- item_place() reads it: a node with an on_rightclick is used when it
	-- is not held and built against when it is, which is the only way to
	-- put a node down on top of a chest.
	local o = objects[id]
	if o and o.control then
		o.control.sneak = sneak and true or false
	end
	-- A node with a formspec in its metadata opens it, which is what
	-- Luanti's own client does before it asks the server to place anything
	local meta = core.get_meta(under)
	local spec = meta and meta:get_string("formspec") or ""
	if spec ~= "" and not sneak then
		show_node_formspec(playername, under, spec)
		return true
	end
	local pointed = {type = "node", under = under, above = above}
	local wielded = ref:get_wielded_item()
	local before = wielded:to_string()
	local left = core.item_place(wielded, ref, pointed)
	if left ~= nil then
		ref:set_wielded_item(left)
		return left:to_string() ~= before
	end
	-- An on_rightclick that returned nothing still did something
	return true
end

-- What the drop key comes to: the item's own on_drop, which is Luanti's
-- core.item_drop unless the game says otherwise -- it spawns the item as an
-- object and throws it a little way in front of the player. count is how
-- many of the stack go, and nothing is one of them.
--
-- What could not be dropped stays in hand: add_item() failing is the world
-- being full rather than the player having thrown something away.
function core.__drop_wielded(playername, count)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref then
		return false
	end
	local inv = ref:get_inventory()
	local index = ref:get_wield_index()
	local stack = inv:get_stack("main", index)
	if stack:is_empty() then
		return false
	end
	count = tonumber(count) or 0
	local dropped = stack:take_item(count > 0 and count or stack:get_count())
	local def = core.registered_items[dropped:get_name()]
	local on_drop = def and def.on_drop or core.item_drop
	local left = on_drop(dropped, ref, ref:get_pos())
	-- Nothing at all came back from an on_drop of the game's own, which
	-- means it did not take the stack
	if left == nil then
		left = dropped
	end
	if not left:is_empty() then
		stack:add_item(left)
	end
	inv:set_stack("main", index, stack)
	return true
end

--
-- An inventory action
--
-- What picking a stack up in one slot and putting it down in another comes
-- to. Luanti's own client sends the move when the stack is put down rather
-- than when it is picked up, so this is one message and the client's "held"
-- is only a drawing.
--
-- Three kinds of inventory can be either end of it: the player's own, a
-- node's, and one that belongs to nobody. The last two carry callbacks that
-- say how much of a move they allow and are told once it has happened.

-- The inventory a formspec location names, the node position if it is a
-- node's and the name if it is a detached one. "current_name" and "context"
-- are the node the open form is about.
local function inventory_at(ref, playername, location)
	if location == "current_player" or
			string.sub(location, 1, 7) == "player:" then
		return ref:get_inventory(), nil
	end
	local detached = string.match(location, "^detached:(.*)$")
	if detached then
		return core.get_inventory({type = "detached", name = detached}),
				nil, detached
	end
	local pos = nil
	if location == "current_name" or location == "context" then
		pos = form_nodes[playername]
	else
		local x, y, z = string.match(location,
				"^nodemeta:(-?%d+),(-?%d+),(-?%d+)$")
		if x then
			pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
		end
	end
	if not pos then
		return nil, nil
	end
	local meta = core.get_meta(pos)
	return meta and meta:get_inventory() or nil, pos
end

local function same_pos(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

-- How much of a move the nodes it touches allow. Luanti asks the node a
-- stack leaves and the node it goes to; a number is a limit and anything
-- below zero is none at all.
local function allowed_count(ref, playername, from_pos, from_list, from_i,
		to_pos, to_list, to_i, count, stack)
	local function ask(f, ...)
		if not f then
			return count
		end
		local ok, n = pcall(f, ...)
		if not ok then
			core.log("error", "allow_metadata_inventory: " .. tostring(n))
			return 0
		end
		if type(n) ~= "number" then
			return count
		end
		if n < 0 then
			-- Luanti's own "no limit"
			return count
		end
		return math.min(count, n)
	end
	if same_pos(from_pos, to_pos) then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		return ask(def and def.allow_metadata_inventory_move, from_pos,
				from_list, from_i, to_list, to_i, count, ref)
	end
	if from_pos then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		count = ask(def and def.allow_metadata_inventory_take, from_pos,
				from_list, from_i, stack, ref)
	end
	if to_pos and count > 0 then
		local def = core.registered_nodes[core.get_node(to_pos).name]
		count = ask(def and def.allow_metadata_inventory_put, to_pos, to_list,
				to_i, stack, ref)
	end
	return count
end

-- The same two questions for a detached inventory, whose callbacks belong to
-- whoever created it rather than to a node. Luanti asks allow_move when both
-- ends are the same inventory and allow_take/allow_put otherwise, and a
-- number below zero is none at all.
local function detached_allowed(ref, from_name, from_inv, from_list, from_i,
		to_name, to_inv, to_list, to_i, count, stack)
	local function ask(name, f, ...)
		if not f then
			return count
		end
		local ok, n = pcall(f, ...)
		if not ok then
			core.log("error", "detached inventory " .. name .. ": " ..
					tostring(n))
			return 0
		end
		if type(n) ~= "number" then
			return count
		end
		if n < 0 then
			return count
		end
		return math.min(count, n)
	end
	if from_name and from_name == to_name then
		local cb = core.detached_inventories[from_name] or {}
		return ask(from_name, cb.allow_move, from_inv, from_list, from_i,
				to_list, to_i, count, ref)
	end
	if from_name then
		local cb = core.detached_inventories[from_name] or {}
		count = ask(from_name, cb.allow_take, from_inv, from_list, from_i,
				stack, ref)
	end
	if to_name and count > 0 then
		local cb = core.detached_inventories[to_name] or {}
		count = ask(to_name, cb.allow_put, to_inv, to_list, to_i, stack, ref)
	end
	return count
end

local function detached_moved(ref, from_name, from_inv, from_list, from_i,
		to_name, to_inv, to_list, to_i, count, stack)
	local function tell(name, f, ...)
		if not f then
			return
		end
		local ok, err = pcall(f, ...)
		if not ok then
			core.log("error", "detached inventory " .. name .. ": " ..
					tostring(err))
		end
	end
	if from_name and from_name == to_name then
		local cb = core.detached_inventories[from_name] or {}
		tell(from_name, cb.on_move, from_inv, from_list, from_i, to_list,
				to_i, count, ref)
		return
	end
	if from_name then
		local cb = core.detached_inventories[from_name] or {}
		tell(from_name, cb.on_take, from_inv, from_list, from_i, stack, ref)
	end
	if to_name then
		local cb = core.detached_inventories[to_name] or {}
		tell(to_name, cb.on_put, to_inv, to_list, to_i, stack, ref)
	end
end

-- And what the nodes are told once it has happened
local function moved(ref, from_pos, from_list, from_i, to_pos, to_list, to_i,
		count, stack)
	local function tell(f, ...)
		if not f then
			return
		end
		local ok, err = pcall(f, ...)
		if not ok then
			core.log("error", "on_metadata_inventory: " .. tostring(err))
		end
	end
	if same_pos(from_pos, to_pos) then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		tell(def and def.on_metadata_inventory_move, from_pos, from_list,
				from_i, to_list, to_i, count, ref)
		return
	end
	if from_pos then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		tell(def and def.on_metadata_inventory_take, from_pos, from_list,
				from_i, stack, ref)
	end
	if to_pos then
		local def = core.registered_nodes[core.get_node(to_pos).name]
		tell(def and def.on_metadata_inventory_put, to_pos, to_list, to_i,
				stack, ref)
	end
end

-- Returns whether anything moved. count of zero is the whole stack.
local function move_stack(from_inv, from_list, from_i, to_inv, to_list, to_i,
		count)
	if from_inv == to_inv and from_list == to_list and from_i == to_i then
		return false
	end
	local src = from_inv:get_stack(from_list, from_i)
	if src:is_empty() then
		return false
	end
	if count <= 0 or count > src:get_count() then
		count = src:get_count()
	end
	local taken = src:take_item(count)
	local dst = to_inv:get_stack(to_list, to_i)
	local leftover = dst:add_item(taken)
	if leftover:get_count() == taken:get_count() and src:is_empty() and
			not dst:is_empty() then
		-- Nothing fitted and the whole source stack was moving: the two slots
		-- swap, which is what Luanti does with a stack put down on a
		-- different item
		from_inv:set_stack(from_list, from_i, dst)
		to_inv:set_stack(to_list, to_i, taken)
		return true
	end
	-- What did not fit goes back where it came from
	src:add_item(leftover)
	from_inv:set_stack(from_list, from_i, src)
	to_inv:set_stack(to_list, to_i, dst)
	return true
end

-- The round trip is the client's; what can be wrong here is the arithmetic,
-- which is checked at every start
function core.__check_inventory_move()
	local inv = core.__new_inventory({type = "player", name = "__check"})
	inv:set_size("main", 4)
	inv:set_stack("main", 1, ItemStack("__check_item 10"))
	inv:set_stack("main", 2, ItemStack("__check_other 1"))
	local function count_at(i)
		local s = inv:get_stack("main", i)
		return s:get_name(), s:get_count()
	end
	assert(move_stack(inv, "main", 1, inv, "main", 3, 4),
			"inventory move: half a stack onto an empty slot")
	local _, n = count_at(1)
	assert(n == 6, "inventory move: the source keeps the rest")
	local name3, n3 = count_at(3)
	assert(name3 == "__check_item" and n3 == 4,
			"inventory move: the destination gets what was taken")
	assert(move_stack(inv, "main", 3, inv, "main", 1, 0),
			"inventory move: onto the same item")
	local _, n1 = count_at(1)
	assert(n1 == 10 and inv:get_stack("main", 3):is_empty(),
			"inventory move: the same item merges")
	assert(move_stack(inv, "main", 1, inv, "main", 2, 0),
			"inventory move: onto a different item")
	local name1 = count_at(1)
	local name2, n2 = count_at(2)
	assert(name1 == "__check_other" and name2 == "__check_item" and n2 == 10,
			"inventory move: a different item swaps")
	assert(not move_stack(inv, "main", 2, inv, "main", 2, 0),
			"inventory move: onto itself is nothing")
	core.log("verbose", "check_inventory_move: the slots add up")
end

-- What the client sends when a stack is put down: the move, as strings.
function core.__inventory_action(playername, a)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref or type(a) ~= "table" or a[1] ~= "move" then
		return
	end
	local from_inv, from_pos, from_detached =
			inventory_at(ref, playername, a[2] or "")
	local to_inv, to_pos, to_detached =
			inventory_at(ref, playername, a[5] or "")
	if not from_inv or not to_inv then
		core.log("verbose", "inventory action: " .. tostring(a[2]) .. " -> " ..
				tostring(a[5]) .. " is not an inventory this player has")
		return
	end
	local from_list, from_i = a[3] or "", tonumber(a[4]) or 0
	local to_list, to_i = a[6] or "", tonumber(a[7]) or 0
	local count = tonumber(a[8]) or 0
	local stack = from_inv:get_stack(from_list, from_i)
	if stack:is_empty() then
		return
	end
	if count <= 0 or count > stack:get_count() then
		count = stack:get_count()
	end
	if from_pos or to_pos or from_detached or to_detached then
		local moving = ItemStack(stack)
		moving:set_count(count)
		if from_pos or to_pos then
			count = allowed_count(ref, playername, from_pos, from_list,
					from_i, to_pos, to_list, to_i, count, moving)
		end
		if count > 0 and (from_detached or to_detached) then
			count = detached_allowed(ref, from_detached, from_inv, from_list,
					from_i, to_detached, to_inv, to_list, to_i, count, moving)
		end
		if count <= 0 then
			return
		end
	end
	if not move_stack(from_inv, from_list, from_i, to_inv, to_list, to_i,
			count) then
		return
	end
	if from_pos or to_pos or from_detached or to_detached then
		local moved_stack = ItemStack(stack)
		moved_stack:set_count(count)
		if from_pos or to_pos then
			moved(ref, from_pos, from_list, from_i, to_pos, to_list, to_i,
					count, moved_stack)
		end
		if from_detached or to_detached then
			detached_moved(ref, from_detached, from_inv, from_list, from_i,
					to_detached, to_inv, to_list, to_i, count, moved_stack)
		end
	end
end

-- The importer's way in: a player read out of a Luanti world's database.
-- What the save already knows about that name is kept, the way a mod's
-- storage is, so that importing the same world twice does not undo what has
-- happened since the first time. Returns whether the row was taken.
function core.__import_player(name, t)
	if type(name) ~= "string" or name == "" or type(t) ~= "table" then
		return false
	end
	if saved_players[name] or players[name] then
		return false
	end
	local fields = t.fields or {}
	-- A world whose players are files keeps their metadata as one JSON
	-- object rather than a row each, and the parser is here rather than in
	-- the importer. "null" is what Luanti writes for a player who has none.
	if type(t.extended_attributes) == "string" and
			t.extended_attributes ~= "" and t.extended_attributes ~= "null" then
		local decoded = core.parse_json(t.extended_attributes)
		if type(decoded) == "table" then
			for key, value in pairs(decoded) do
				fields[key] = tostring(value)
			end
		else
			core.log("warning", "__import_player(" .. name ..
					"): the extended attributes are not a JSON object")
		end
	end
	saved_players[name] = {
		pos = t.pos,
		look = t.look,
		hp = t.hp,
		breath = t.breath,
		wield_index = 1,
		fields = fields,
		inventory = t.inventory or {},
	}
	return true
end

-- The round trip, on a player made for it rather than on a live one: what
-- can be wrong here is a value that does not survive being written down, and
-- adding a real player would run every mod's join callback to find that out.
function core.__check_players()
	local made = function(fields)
		return {
			pos = {x = 0, y = 0, z = 0},
			look = {h = 0, v = 0},
			hp = 20,
			breath = 10,
			wield_index = 1,
			meta = core.__new_metadata(fields or {}),
			inventory = core.__new_inventory(
					{type = "player", name = "__check"}),
		}
	end
	local from = made({greeting = "hello"})
	from.pos = {x = 1, y = -2, z = 3}
	from.look = {h = 0.5, v = -0.25}
	from.hp = 7
	from.breath = 3
	from.wield_index = 4
	from.inventory:set_size("main", 2)
	from.inventory:set_stack("main", 1, ItemStack("__check_item 3"))
	local wrote = core.serialize(snapshot_player(from))
	local to = made()
	restore_player(to, core.deserialize(wrote))
	assert(to.pos.x == 1 and to.pos.y == -2 and to.pos.z == 3,
			"check_players: the position did not come back")
	assert(to.look.h == 0.5 and to.look.v == -0.25,
			"check_players: the look did not come back")
	assert(to.hp == 7 and to.breath == 3 and to.wield_index == 4,
			"check_players: hp, breath or the wielded slot did not come back")
	assert(to.meta.fields.greeting == "hello",
			"check_players: the metadata did not come back")
	assert(to.inventory:get_stack("main", 1):to_string() == "__check_item 3",
			"check_players: the inventory did not come back")
	-- And the two angles mean what Luanti says they mean, which is the one
	-- thing about them that is easy to get backwards: the horizontal angle
	-- turns from +Z towards -X, and the vertical one is positive downwards.
	local looker = made()
	local check_id = "__check_look"
	objects[check_id] = looker
	local ref = setmetatable({__id = check_id}, PlayerRef)
	looker.look = {h = 0, v = 0}
	local d = ref:get_look_dir()
	assert(math.abs(d.z - 1) < 1e-6, "check_players: h=0 is not +Z")
	looker.look = {h = math.pi / 2, v = 0}
	d = ref:get_look_dir()
	assert(math.abs(d.x + 1) < 1e-6, "check_players: h=pi/2 is not -X")
	looker.look = {h = 0, v = math.pi / 2}
	d = ref:get_look_dir()
	assert(math.abs(d.y + 1) < 1e-6,
			"check_players: a positive vertical angle is not downwards")
	assert(math.abs(ref:get_look_pitch() + math.pi / 2) < 1e-6,
			"check_players: the deprecated pitch is not the other way round")
	objects[check_id] = nil
	core.log("verbose", "check_players: a player survived being written down")
end

-- Where a player who has never been here starts. Luanti's own findSpawnPos
-- takes the game's static_spawnpoint if it has one and otherwise stands the
-- player on the ground the mapgen says is there; this does the same with
-- the ground the map says is there. A world that has not generated around
-- the origin yet has no answer, and then the origin is what is left -- the
-- same place a player started before there was any terrain to stand on.
-- How many points the search looks at before it gives up, and how far out
-- it is allowed to walk. Luanti's numbers, except that its range limit is
-- the mapgen's own.
local SPAWN_TRIES = 4000
local SPAWN_RANGE_MAX = 31000
-- How many of those look at the map's whole column; see get_spawn_level()
local SPAWN_DEEP_TRIES = 8
-- The candidate points are the same sequence in every world, so that a
-- world always spawns a player in the same place: what makes one world's
-- spawn differ from another's is which candidates its mapgen accepts.
local SPAWN_SEQUENCE_SEED = 1337

-- 0...span, out of a generator whose own range is 0...32767
local function spawn_rand_to(pr, span)
	if span <= 32767 then
		return pr:next() % (span + 1)
	end
	return (pr:next() * 32768 + pr:next()) % (span + 1)
end

local function find_spawn_pos()
	local static = core.settings:get("static_spawnpoint")
	if static then
		local x, y, z = string.match(static,
				"^%s*([%d.-]+)%s*,%s*([%d.-]+)%s*,%s*([%d.-]+)%s*$")
		if x then
			return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}, true
		end
		core.log("warning", "static_spawnpoint is not a position: " .. static)
	end
	-- Luanti's own search (Server::findSpawnPos): try a point, and if it is
	-- no good try another one a little further out, so that a spawn lands
	-- near the origin when the origin will do and walks outwards over an
	-- ocean when it will not. The points are random there and pseudo-random
	-- here, seeded from the world's own seed, so that a world always spawns
	-- a player in the same place.
	local pr = PseudoRandom(SPAWN_SEQUENCE_SEED)
	for i = 0, SPAWN_TRIES - 1 do
		local range = math.min(1 + i, SPAWN_RANGE_MAX)
		local x, z = 0, 0
		if i > 0 then
			x = -range + spawn_rand_to(pr, range * 2)
			z = -range + spawn_rand_to(pr, range * 2)
		end
		-- The first few points may have the map's whole column walked when
		-- the mapgen's answer does not match what is there; the rest are
		-- the mapgen's answer and a look at the nodes above it. Six hundred
		-- voxels of map read times four thousand points is half a minute of
		-- the module's thread, and a client waits for that thread.
		local level = core.get_spawn_level(x, z, i < SPAWN_DEEP_TRIES)
		if level ~= nil then
			return {x = x, y = level, z = z}, true
		end
	end
	-- Nowhere to stand yet: the world around the origin has not been
	-- generated deep enough to say. The player waits at the origin and is
	-- put down as soon as it can; see the placement in __step_objects().
	return {x = 0, y = 0, z = 0}, false
end

-- A player who arrives before the world around the spawn has been generated
-- cannot be put on the ground, because the map has no ground to answer with
-- yet. They start where a player with nowhere to be always started, and
-- this stands them on the surface as soon as there is one -- unless they
-- have moved in the meantime, in which case where they are is where they
-- want to be.
local unplaced = {}
local unplaced_timer = 0

local function place_the_unplaced(dtime)
	if next(unplaced) == nil then
		return
	end
	unplaced_timer = unplaced_timer + dtime
	if unplaced_timer < 1 then
		return
	end
	unplaced_timer = 0
	local spawn, known = find_spawn_pos()
	for name, was in pairs(unplaced) do
		local player = core.get_player_by_name(name)
		if player == nil then
			unplaced[name] = nil
		else
			local pos = player:get_pos()
			if math.abs(pos.x - was.x) > 0.5 or
					math.abs(pos.y - was.y) > 0.5 or
					math.abs(pos.z - was.z) > 0.5 then
				unplaced[name] = nil
			elseif known then
				player:set_pos(spawn)
				local o = state_of(player)
				if o then
					o.spawn_known = true
				end
				unplaced[name] = nil
				core.log("action", string.format(
						"Player %s was put on the ground at %.0f, %.0f, %.0f",
						name, spawn.x, spawn.y, spawn.z))
			end
		end
	end
end

-- What the module calls when a client arrives and leaves. The name is the
-- client's, and it is what everything about a player is keyed by.
function core.__add_player(name)
	if players[name] then
		return
	end
	local id = next_id
	next_id = id + 1
	local ref = setmetatable({__id = id}, PlayerRef)
	local o = {
		id = id,
		ref = ref,
		pos = {x = 0, y = 0, z = 0},
		vel = {x = 0, y = 0, z = 0},
		acc = {x = 0, y = 0, z = 0},
		rot = {x = 0, y = 0, z = 0},
		props = table.copy(DEFAULT_PROPERTIES),
		armor_groups = {},
		hp = 20,
		player_name = name,
		meta = core.__new_metadata({}),
		inventory = core.__new_inventory({type = "player", name = name}),
		look = {h = 0, v = 0},
		wield_index = 1,
		hotbar = 8,
		breath = 10,
		physics = {speed = 1, jump = 1, gravity = 1},
		inventory_formspec = "",
		formspec_prepend = "",
		-- What the client says it is holding down. Only sneak is ever set:
		-- it is the one a mod reads, because Luanti's own item_place()
		-- looks at it to decide between a node's on_rightclick and putting
		-- something down against it. The rest are here so that the table is
		-- the shape a mod expects.
		control = {up = false, down = false, left = false, right = false,
				jump = false, aux1 = false, sneak = false, dig = false,
				place = false, LMB = false, RMB = false, zoom = false},
	}
	-- What Luanti gives a player, from its own constants: a mod reads these
	-- off the properties, and so does the builtin's HUD -- the bubbles are
	-- drawn only while the breath is under its maximum, which is no maximum
	-- at all for an entity
	o.props.hp_max = core.PLAYER_MAX_HP_DEFAULT or 20
	o.props.breath_max = core.PLAYER_MAX_BREATH_DEFAULT or 10
	o.props.collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3}
	objects[id] = o
	core.object_refs[id] = ref
	core.objects_by_guid[name] = ref
	players[name] = id
	-- The lists Luanti gives a player, so that a mod can put something in
	-- one without making it first
	o.inventory:set_size("main", 32)
	o.inventory:set_size("craft", 9)
	o.inventory:set_size("craftpreview", 1)
	-- What the last run left, before on_joinplayer runs: a mod's join
	-- callback reads the player it is given, and in Luanti that player has
	-- come out of the database by then
	local new_here = saved_players[name] == nil
	if new_here then
		o.pos, o.spawn_known = find_spawn_pos()
	end
	restore_player(o, saved_players[name])
	-- Luanti's server makes the auth entry when a client logs in, and the
	-- builtin's own join callback expects to find one: here whoever
	-- connects is who they say they are -- a buildat server decided that
	-- one layer down -- so the entry is made with an empty password.
	local handler = core.get_auth_handler and core.get_auth_handler()
	if handler and handler.get_auth and handler.create_auth then
		local ok, entry = pcall(handler.get_auth, name)
		if ok and entry == nil then
			pcall(handler.create_auth, name, "")
		end
	end
	if new_here and not o.spawn_known then
		unplaced[name] = {x = o.pos.x, y = o.pos.y, z = o.pos.z}
	end
	-- A client that arrives is told the HUD the game had already put on it,
	-- which for a player who was here before is everything a mod added the
	-- last time they joined, and what their life and breath are
	send_whole_hud(o)
	send_stats(o)
	send_day_night(o)
	send_sky(o)
	-- And what time it is. The module sends this to everyone every few
	-- seconds of the world's own clock, which under load is a good deal
	-- longer than a few seconds of anyone else's -- and a client with no
	-- clock at all draws the sky it started with. So the first one is here,
	-- where somebody has just arrived and has nothing.
	core.__send_time()
	-- Where the last run left them, or the spawn: either way it is the
	-- server's answer and the client starts there. A player whose spawn the
	-- map cannot answer for yet is not told anything -- a fallback position
	-- would start their client walking from a place the server does not
	-- believe in either -- and the placement below tells them once there is
	-- ground to stand on.
	if not new_here or o.spawn_known then
		tell_the_client(o)
	end
	core.log("action", "Player " .. name .. " joined")
	for _, cb in ipairs(core.registered_on_joinplayers or {}) do
		-- With the traceback, because a game the size of VoxeLibre has
		-- eighty of these and the message alone says nothing about which
		-- mod's it was
		local ok, err = xpcall(function() return cb(ref, nil) end,
				function(e)
					return tostring(e) .. "\n" .. debug.traceback("", 2)
				end)
		if not ok then
			core.log("error", "on_joinplayer: " .. tostring(err))
		end
	end
end

function core.__remove_player(name)
	local id = players[name]
	if id == nil then
		return
	end
	local ref = core.object_refs[id]
	for _, cb in ipairs(core.registered_on_leaveplayers or {}) do
		local ok, err = pcall(cb, ref, false)
		if not ok then
			core.log("error", "on_leaveplayer: " .. tostring(err))
		end
	end
	local o = objects[id]
	if o then
		saved_players[name] = snapshot_player(o)
	end
	players[name] = nil
	objects[id] = nil
	core.object_refs[id] = nil
	core.objects_by_guid[name] = nil
	core.log("action", "Player " .. name .. " left")
end

-- Where a player is and which way they are looking is their client's to say
function core.__set_player_pos(name, x, y, z, look_h, look_v)
	local id = players[name]
	local o = id and objects[id]
	if not o then
		return
	end
	o.pos = {x = x, y = y, z = z}
	if look_h then
		o.look.h = look_h
		o.look.v = look_v or 0
	end
end

-- Which slot the player is holding, as their client says. A mod reads it
-- through get_wield_index() and everything that asks what is in hand -- a
-- dig, a place, a craft -- goes through the same number.
function core.__set_wield_index(name, i)
	local id = players[name]
	local o = id and objects[id]
	if not o then
		return
	end
	local size = o.inventory and o.inventory:get_size("main") or 0
	i = math.floor(tonumber(i) or 1)
	if i < 1 then
		i = 1
	end
	if size > 0 and i > size then
		i = size
	end
	o.wield_index = i
end

function core.get_connected_players()
	local out = {}
	for _, id in pairs(players) do
		local o = objects[id]
		if o then
			out[#out + 1] = o.ref
		end
	end
	return out
end

function core.get_player_by_name(name)
	local id = players[name]
	local o = id and objects[id]
	return o and o.ref or nil
end

-- What the client on the other end is. Nothing here speaks Luanti's
-- protocol, so the version is zero and a mod that asks decides what to do
-- about that -- devtest's own media test reads it and skips itself.
function core.get_player_information(name)
	if players[name] == nil then
		return nil
	end
	return {
		address = "",
		ip_version = 4,
		connection_uptime = 0,
		protocol_version = 0,
		formspec_version = 0,
		lang_code = "",
		version_string = "buildat",
		min_rtt = 0, max_rtt = 0, avg_rtt = 0,
		min_jitter = 0, max_jitter = 0, avg_jitter = 0,
	}
end

function core.get_player_window_information(name)
	return nil
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

-- How often an active object is asked for its static data, which is about
-- what Luanti's own deactivateFarObjects() comes to while an object stays
-- where it is.
local STATICDATA_INTERVAL = 2

-- Luanti asks an active object for its static data every couple of seconds,
-- because that is what it writes into the block the object is in. Nothing
-- here keeps an object in a block -- see the note in core.__step_objects()
-- -- so the string is only held, and this looks like a call made for its
-- side effects alone. It is not optional for all that: a mod is entitled to
-- do its own bookkeeping in get_staticdata(), and **VoxeLibre's mobs do
-- not move without it**. A freshly spawned mcl_mobs mob has no state until
-- something sets one, and the one thing that does is get_staticdata(); with
-- it never called, every mob in the game stood still for ever.
local function ask_for_staticdata(o, dtime)
	local le = o.le
	if le == nil or le.get_staticdata == nil then
		return
	end
	-- Spread over the interval rather than all on one step: the objects of
	-- a game the size of VoxeLibre are serialised here, one table each
	o.staticdata_in = (o.staticdata_in or
			math.random() * STATICDATA_INTERVAL) - dtime
	if o.staticdata_in > 0 then
		return
	end
	o.staticdata_in = STATICDATA_INTERVAL
	core.set_last_run_mod(le.mod_origin)
	local ok, data = pcall(le.get_staticdata, le)
	if ok then
		o.staticdata = data
	else
		core.log("error", "entity " .. tostring(le.name) ..
				" get_staticdata: " .. tostring(data))
	end
end

local function step_object(o, dtime)
	-- Where a player is is their client's to say, and nothing here has an
	-- opinion about it
	if o.player_name then
		return
	end
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
	ask_for_staticdata(o, dtime)
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

-- What an object looks like, as much of it as the client half draws: a shape
-- and one texture. Luanti's visuals are more than these three, and the ones
-- that are not here fall back to the plain box they were before.
--
-- simplified: one texture rather than six for a cube, and a mesh is a cube
-- wearing its first texture. The upgrade path is the shapes themselves --
-- b3dmesh.lua and objmesh.lua in extensions/luanti_client read the two
-- formats Luanti ships -- and it is a milestone of its own.
local function appearance_of(o)
	local props = o.props
	local visual = props.visual or "sprite"
	local textures = props.textures or {}
	if visual == "cube" then
		return "cube", textures[1] or ""
	end
	if visual == "mesh" then
		-- A model: the mesh file, the size it is drawn at and the whole
		-- texture list -- one per material -- because none of that fits in
		-- a texture name. The client asks for the mesh itself by name, once,
		-- on a channel of its own; see core.__model_quads().
		local mesh = props.mesh or ""
		if mesh == "" then
			return "cube", textures[1] or ""
		end
		local v = props.visual_size or {}
		local detail = {mesh,
				tostring(v.x or v[1] or 1) .. "," ..
				tostring(v.y or v[2] or 1) .. "," ..
				tostring(v.z or v[3] or v.x or v[1] or 1)}
		for _, t in ipairs(textures) do
			detail[#detail + 1] = t
		end
		return "mesh", textures[1] or "", table.concat(detail, "\1")
	end
	if visual == "sprite" or visual == "upright_sprite" then
		return "sprite", textures[1] or ""
	end
	if visual == "wielditem" or visual == "item" then
		-- What the item looks like in an inventory is what it looks like
		-- lying on the ground, which is the same expression.
		--
		-- Which item it is, is in the first texture: that is where Luanti's
		-- own builtin item entity puts it and where VoxeLibre's does too.
		-- wield_item is the other spelling and is answered after it, since
		-- an object that sets that and no texture means the same thing.
		local name = textures[1] or ""
		if name == "" then
			name = props.wield_item or ""
		end
		if name == "" then
			return "box", ""
		end
		return "sprite", core.__item_image_of(name) or ""
	end
	return "box", ""
end

-- id -> {kind, texture} as last sent, so that what is sent is what has
-- changed -- and so that a client that connects later can be told the lot
local sent_appearance = {}

-- Every object's look, flat, for a client that has just arrived: the props
-- are sent when they change and a client that was not there missed them.
function core.__object_appearances()
	local out = {}
	for id, look in pairs(sent_appearance) do
		out[#out + 1] = tostring(id)
		out[#out + 1] = look[1]
		out[#out + 1] = look[2]
		out[#out + 1] = look[3] or ""
	end
	return out
end

-- Where an object is drawn, which is where it is unless it is riding
-- something: a child is at its parent's place plus the offset it was
-- attached with. Luanti's attachment offsets are in its own units, ten to
-- the node, and the chain can be more than one deep -- a player on a seat
-- on a cart -- so this follows it up, with a bound in case a mod makes a
-- ring of them.
local function drawn_pos_of(o, depth)
	local a = o.attached_to
	local parent = a and state_of(a.ref) or nil
	if parent == nil or (depth or 0) > 4 then
		return o.pos
	end
	local at = drawn_pos_of(parent, (depth or 0) + 1)
	local offset = a.position or {x = 0, y = 0, z = 0}
	return {
		x = at.x + (offset.x or offset[1] or 0) / 10,
		y = at.y + (offset.y or offset[2] or 0) / 10,
		z = at.z + (offset.z or offset[3] or 0) / 10,
	}
end

local function show_objects()
	local v = {}
	local props_changed = {}
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
			local at = drawn_pos_of(o, 0)
			v[#v + 1] = id
			v[#v + 1] = at.x + (box[1] + box[4]) / 2
			v[#v + 1] = at.y + (box[2] + box[5]) / 2
			v[#v + 1] = at.z + (box[3] + box[6]) / 2
			v[#v + 1] = sx
			v[#v + 1] = sy
			v[#v + 1] = sz
			v[#v + 1] = o.rot and o.rot.y or 0
			local kind, texture, detail = appearance_of(o)
			detail = detail or ""
			local was = sent_appearance[id]
			if not was or was[1] ~= kind or was[2] ~= texture or
					was[3] ~= detail then
				sent_appearance[id] = {kind, texture, detail}
				props_changed[#props_changed + 1] = tostring(id)
				props_changed[#props_changed + 1] = kind
				props_changed[#props_changed + 1] = texture
				props_changed[#props_changed + 1] = detail
			end
		end
	end
	for id, _ in pairs(sent_appearance) do
		if objects[id] == nil then
			sent_appearance[id] = nil
		end
	end
	if #props_changed > 0 then
		__show_object_props(props_changed)
	end
	if #v == 0 and not anything_shown then
		return
	end
	anything_shown = #v > 0
	__show_objects(v)
end

-- What a player is carrying, to their own client and nobody else's. The
-- inventory counts its own changes, so this is the one that has changed since
-- the last step rather than all of them every step.
--
-- The lists go over flat: a name, how many slots it has, and then that many
-- item strings. What reads them is the module's client half.
local function flatten_lists(inv, flat)
	for list_name, stacks in pairs(inv:get_lists()) do
		flat[#flat + 1] = list_name
		flat[#flat + 1] = tostring(#stacks)
		for _, stack in ipairs(stacks) do
			flat[#flat + 1] = stack:to_string()
		end
	end
	return flat
end

local function send_inventories()
	for name, id in pairs(players) do
		local o = objects[id]
		local inv = o and o.inventory
		if inv and inv.gen ~= o.sent_inventory_gen then
			o.sent_inventory_gen = inv.gen
			__send_inventory(name, flatten_lists(inv, {}))
		end
		-- And the node the open form is about, which is a chest's slots.
		-- What is drawn is only ever the one form's node, so one is enough.
		local at = o and form_nodes[name]
		local node_inv = at and core.get_meta(at):get_inventory() or nil
		if node_inv then
			local key = pos_string(at)
			if o.sent_node_at ~= key or node_inv.gen ~= o.sent_node_gen then
				o.sent_node_at = key
				o.sent_node_gen = node_inv.gen
				__send_node_inventory(name, flatten_lists(node_inv, {key}))
			end
		elseif o then
			o.sent_node_at = nil
		end
		-- And the detached inventories the open form names, which belong to
		-- nobody: the same channel with the location for a key, because
		-- that is what a formspec's list[] says and what the client looks
		-- them up by.
		if o then
			o.sent_detached = o.sent_detached or {}
			-- The form a game showed, and the player's own inventory form,
			-- which the client opens by itself whenever it likes
			local wanted = {}
			for inv_name, _ in pairs(form_detached[name] or {}) do
				wanted[inv_name] = true
			end
			for inv_name, _ in pairs(o.own_detached or {}) do
				wanted[inv_name] = true
			end
			for inv_name, _ in pairs(wanted) do
				local inv = core.get_inventory({type = "detached",
						name = inv_name})
				if inv and o.sent_detached[inv_name] ~= inv.gen then
					o.sent_detached[inv_name] = inv.gen
					__send_node_inventory(name,
							flatten_lists(inv, {"detached:" .. inv_name}))
				end
			end
			for inv_name, _ in pairs(o.sent_detached) do
				if not wanted[inv_name] then
					o.sent_detached[inv_name] = nil
				end
			end
		end
		-- The form the player's own inventory key opens, when a mod has
		-- changed it. It is sent when it changes rather than when it is
		-- asked for, so that opening it costs no round trip.
		if o and o.inventory_formspec ~= o.sent_inventory_formspec then
			o.sent_inventory_formspec = o.inventory_formspec
			o.own_detached = detached_in_spec(o.inventory_formspec)
			__player_formspec(name, o.inventory_formspec or "")
		end
	end
end

function core.__step_objects(dtime)
	place_the_unplaced(dtime)
	-- Over the ids taken first, because a step adds and removes objects
	local ids = {}
	for id, _ in pairs(objects) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local o = objects[id]
		-- Where a player is is their client's to say, and everything else
		-- steps while it is in the active range -- which is where a player
		-- is, so a player is always in one. Luanti takes an entity out of
		-- the world entirely when its block stops being active and puts it
		-- back when the block returns.
		--
		-- simplified: it stays in the world here and only stops moving, so
		-- nothing is written into the section it is in and nothing has to
		-- be read back out of it. What that costs is an entity per object
		-- forever; Luanti's static objects are the upgrade path.
		if o and (o.player_name or core.__is_active(o.pos)) then
			step_object(o, dtime)
		end
	end
	show_objects()
	send_inventories()
end

-- vim: set noet ts=4 sw=4:
