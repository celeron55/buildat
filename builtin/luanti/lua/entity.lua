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
local __send_inventory = __luanti_send_inventory
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

function PlayerRef:get_look_dir()
	local o = state_of(self)
	if not o then
		return vector.new(0, 0, 1)
	end
	local h, v = o.look.h, o.look.v
	return vector.new(-math.sin(h) * math.cos(v), math.sin(v),
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

PlayerRef.get_look_yaw = PlayerRef.get_look_horizontal
PlayerRef.set_look_yaw = PlayerRef.set_look_horizontal
PlayerRef.get_look_pitch = PlayerRef.get_look_vertical
PlayerRef.set_look_pitch = PlayerRef.set_look_vertical

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
	return {up = false, down = false, left = false, right = false,
			jump = false, aux1 = false, sneak = false, dig = false,
			place = false, LMB = false, RMB = false, zoom = false}
end

function PlayerRef:get_player_control_bits()
	return 0
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

-- What a HUD and a sky are is the client's, and there is no client half yet:
-- these keep nothing and answer with nothing, rather than being missing and
-- taking a mod down on the line that sets one
for _, name in ipairs({
	"hud_remove", "hud_change", "hud_set_flags", "hud_set_hotbar_image",
	"hud_set_hotbar_selected_image", "set_sky", "set_sun", "set_moon",
	"set_stars", "set_clouds", "set_lighting", "override_day_night_ratio",
	"set_minimap_modes", "send_mapblock", "set_fov", "set_nametag_color",
	"hud_set_hotbar_image_selected",
}) do
	PlayerRef[name] = function() end
end

function PlayerRef:hud_add() return nil end
function PlayerRef:hud_get() return nil end
function PlayerRef:hud_get_flags()
	return {hotbar = true, healthbar = true, crosshair = true,
			wielditem = true, breathbar = true, minimap = true,
			minimap_radar = true, basic_debug = true, chat = true}
end
function PlayerRef:hud_get_hotbar_image() return "" end
function PlayerRef:hud_get_hotbar_selected_image() return "" end
function PlayerRef:get_sky(as_table)
	if as_table then
		return {base_color = nil, type = "regular", textures = {},
				clouds = true}
	end
	return nil, "regular", {}, true
end
function PlayerRef:get_sky_color() return {} end
function PlayerRef:get_sun() return {visible = true} end
function PlayerRef:get_moon() return {visible = true} end
function PlayerRef:get_stars() return {visible = true} end
function PlayerRef:get_clouds() return {density = 0.4} end
function PlayerRef:get_lighting() return {shadows = {intensity = 0}} end
function PlayerRef:get_day_night_ratio() return nil end
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

local function pos_string(pos)
	return math.floor(pos.x) .. "," .. math.floor(pos.y) .. "," ..
			math.floor(pos.z)
end

function core.show_formspec(playername, formname, formspec)
	if type(playername) ~= "string" or type(formspec) ~= "string" then
		return false
	end
	form_nodes[playername] = nil
	__show_formspec(playername, tostring(formname or ""), formspec, "")
	return true
end

-- The form a node carries in its own metadata, which is what a chest is.
-- Luanti's client opens one itself; here the server does, because the node
-- metadata is the server's.
local function show_node_formspec(playername, pos, formspec)
	form_nodes[playername] = {x = math.floor(pos.x), y = math.floor(pos.y),
			z = math.floor(pos.z)}
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
function core.__use_node(playername, under, above)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref then
		return false
	end
	-- A node with a formspec in its metadata opens it, which is what
	-- Luanti's own client does before it asks the server to place anything
	local meta = core.get_meta(under)
	local spec = meta and meta:get_string("formspec") or ""
	if spec ~= "" then
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

--
-- An inventory action
--
-- What picking a stack up in one slot and putting it down in another comes
-- to. Luanti's own client sends the move when the stack is put down rather
-- than when it is picked up, so this is one message and the client's "held"
-- is only a drawing.
--
-- simplified: the player's own inventory. A node's and a detached one want
-- the allow_/on_ callbacks around them first, and those are the same message
-- with more done about it; see "what is left of M4" in
-- doc/plan/luanti_module_plan.md.

-- The inventory a formspec location names, and the node position if it is a
-- node's. "current_name" and "context" are the node the open form is about.
local function inventory_at(ref, playername, location)
	if location == "current_player" or
			string.sub(location, 1, 7) == "player:" then
		return ref:get_inventory(), nil
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
	local from_inv, from_pos = inventory_at(ref, playername, a[2] or "")
	local to_inv, to_pos = inventory_at(ref, playername, a[5] or "")
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
	if from_pos or to_pos then
		local moving = ItemStack(stack)
		moving:set_count(count)
		count = allowed_count(ref, playername, from_pos, from_list, from_i,
				to_pos, to_list, to_i, count, moving)
		if count <= 0 then
			return
		end
	end
	if not move_stack(from_inv, from_list, from_i, to_inv, to_list, to_i,
			count) then
		return
	end
	if from_pos or to_pos then
		local moved_stack = ItemStack(stack)
		moved_stack:set_count(count)
		moved(ref, from_pos, from_list, from_i, to_pos, to_list, to_i, count,
				moved_stack)
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
	saved_players[name] = {
		pos = t.pos,
		look = t.look,
		hp = t.hp,
		breath = t.breath,
		wield_index = 1,
		fields = t.fields or {},
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
	core.log("verbose", "check_players: a player survived being written down")
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
	}
	o.props.hp_max = 20
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
	core.log("action", "Player " .. name .. " joined")
	for _, cb in ipairs(core.registered_on_joinplayers or {}) do
		local ok, err = pcall(cb, ref, nil)
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
		-- The form the player's own inventory key opens, when a mod has
		-- changed it. It is sent when it changes rather than when it is
		-- asked for, so that opening it costs no round trip.
		if o and o.inventory_formspec ~= o.sent_inventory_formspec then
			o.sent_inventory_formspec = o.inventory_formspec
			__player_formspec(name, o.inventory_formspec or "")
		end
	end
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
	send_inventories()
end

-- vim: set noet ts=4 sw=4:
