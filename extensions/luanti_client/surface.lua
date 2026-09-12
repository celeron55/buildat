-- Buildat: extension/luanti_client/surface.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What a node's surface is made of, guessed from its definition.
--
-- The atlas derives a normal map and a spec map from six numbers per texture
-- segment (see src/interface/atlas.h), and the PBR voxel shader reads them.
-- Luanti says nothing about any of them: a node definition knows its drawtype,
-- its groups and whether it waves, and that is what there is to go on. So this
-- is a guess, and it is in a file of its own so that it can be argued with
-- without touching the world.
--
-- The numbers:
--   roughness      0 = mirror, 1 = chalk
--   spec_strength  how much light the surface returns at all
--   bumpiness      how much the texture's own luminance becomes relief
--   translucency   how much light comes through from behind
--   spots          animated sparkle: moving highlights, for water
--   static_spots   the same but standing still: facets in sand, snow, ore
--
-- Not here: metalness. The spec map's four channels are full and cMetallic is
-- per material, so metal nodes read as very glossy dielectrics.

local M = {}

-- Luanti's NodeDrawType; nodedef.lua has the whole list
local DRAWTYPE_LIQUID = 2
local DRAWTYPE_FLOWINGLIQUID = 3
local DRAWTYPE_GLASSLIKE = 4
local DRAWTYPE_ALLFACES = 5
local DRAWTYPE_ALLFACES_OPTIONAL = 6
local DRAWTYPE_PLANTLIKE = 9
local DRAWTYPE_FIRELIKE = 14
local DRAWTYPE_GLASSLIKE_FRAMED = 13
local DRAWTYPE_GLASSLIKE_FRAMED_OPTIONAL = 15
local DRAWTYPE_PLANTLIKE_ROOTED = 17

local NODEDEF_ALPHAMODE_BLEND = 0

-- What everything is before anything is known about it: a painted texture with
-- a wide, weak highlight, which is what these textures are painted as
local DEFAULT = {
	roughness = 0.95,
	spec_strength = 0.2,
	bumpiness = 0.3,
	translucency = 0,
	spots = 0,
	static_spots = 0,
}

-- A name that says what a node is made of when its groups do not. Games whose
-- nodes carry no groups worth reading are common enough that this is worth the
-- dozen patterns; the groups win where there are any.
local BY_NAME = {
	{"water", {roughness = 0.25, spec_strength = 0.9, bumpiness = 0,
			spots = 0.10}},
	{"lava", {roughness = 0.6, spec_strength = 0.3, bumpiness = 0.2}},
	{"ice", {roughness = 0.10, spec_strength = 1.0, bumpiness = 0.1,
			static_spots = 0.15}},
	{"glass", {roughness = 0.10, spec_strength = 1.0, bumpiness = 0}},
	{"crystal", {roughness = 0.15, spec_strength = 0.9, bumpiness = 0.1,
			static_spots = 0.25}},
	{"gem", {roughness = 0.15, spec_strength = 0.9, static_spots = 0.25}},
	{"diamond", {roughness = 0.12, spec_strength = 1.0, static_spots = 0.3}},
	{"mese", {roughness = 0.2, spec_strength = 0.8, static_spots = 0.25}},
	{"metal", {roughness = 0.35, spec_strength = 0.8, bumpiness = 0.1}},
	{"steel", {roughness = 0.35, spec_strength = 0.8, bumpiness = 0.1}},
	{"copper", {roughness = 0.40, spec_strength = 0.7, bumpiness = 0.1}},
	{"bronze", {roughness = 0.40, spec_strength = 0.7, bumpiness = 0.1}},
	{"tin", {roughness = 0.35, spec_strength = 0.8, bumpiness = 0.1}},
	{"gold", {roughness = 0.30, spec_strength = 0.9, bumpiness = 0.1}},
	{"snow", {roughness = 0.85, spec_strength = 0.35, bumpiness = 0.2,
			static_spots = 0.30}},
	{"sand", {roughness = 1.0, spec_strength = 0.15, bumpiness = 0.6,
			static_spots = 0.20}},
	{"ore", {static_spots = 0.20, spec_strength = 0.5, roughness = 0.6}},
}

local function copy(t)
	local out = {}
	for k, v in pairs(DEFAULT) do
		out[k] = v
	end
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

local function group(def, name)
	return (def.groups or {})[name] or 0
end

-- What a node's surface is: a table of the six numbers. def is what
-- nodedef.parse() returned.
function M.for_node(def)
	if not def then
		return copy(nil)
	end
	local drawtype = def.drawtype or 0
	local blend = def.alpha_mode == NODEDEF_ALPHAMODE_BLEND
	local out

	if drawtype == DRAWTYPE_LIQUID or drawtype == DRAWTYPE_FLOWINGLIQUID then
		-- A liquid's highlights move because the liquid does; lava is the one
		-- that does not want them, and its name is what says so
		out = copy({roughness = 0.25, spec_strength = 0.9, bumpiness = 0,
				spots = 0.10})
	elseif drawtype == DRAWTYPE_PLANTLIKE or
			drawtype == DRAWTYPE_PLANTLIKE_ROOTED or
			drawtype == DRAWTYPE_ALLFACES or
			drawtype == DRAWTYPE_ALLFACES_OPTIONAL then
		-- Leaves and plants: lit from behind as much as from in front, which
		-- is the whole of what makes a canopy read as a canopy
		out = copy({roughness = 0.8, spec_strength = 0.25, bumpiness = 0.2,
				translucency = 0.65, spots = 0.15})
	elseif drawtype == DRAWTYPE_GLASSLIKE or
			drawtype == DRAWTYPE_GLASSLIKE_FRAMED or
			drawtype == DRAWTYPE_GLASSLIKE_FRAMED_OPTIONAL or blend then
		out = copy({roughness = 0.10, spec_strength = 1.0, bumpiness = 0,
				static_spots = 0.10})
	elseif group(def, "crumbly") > 0 then
		-- Dirt, sand, gravel: matte, and rough enough that the texture's own
		-- luminance is worth reading as relief
		out = copy({roughness = 1.0, spec_strength = 0.1, bumpiness = 0.7})
	elseif group(def, "cracky") > 0 then
		out = copy({roughness = 0.7, spec_strength = 0.4, bumpiness = 0.35})
	elseif group(def, "snappy") > 0 or group(def, "fleshy") > 0 then
		out = copy({roughness = 1.0, spec_strength = 0.05, bumpiness = 0.15})
	elseif group(def, "choppy") > 0 then
		-- Wood: a little sheen along the grain, and the grain itself
		out = copy({roughness = 0.85, spec_strength = 0.2, bumpiness = 0.4})
	else
		out = copy(nil)
	end

	-- A name that says what it is overrides what its drawtype guessed, because
	-- "stone with an ore in it" and "stone" are the same drawtype and the same
	-- group and are not the same surface. Liquids keep what the drawtype gave
	-- them apart from lava, which is why this runs after and not before.
	local name = def.name or ""
	for _, entry in ipairs(BY_NAME) do
		if string.find(name, entry[1], 1, true) then
			for k, v in pairs(entry[2]) do
				out[k] = v
			end
			break
		end
	end

	-- Something that gives off light is lit by itself and not by the sun, and
	-- a highlight crawling over a torch reads as a mistake
	if (def.light_source or 0) > 0 then
		out.spots = 0
		out.static_spots = 0
		out.spec_strength = math.min(out.spec_strength, 0.1)
	end

	-- What waves is moving, so its sparkle moves with it; what does not, does
	-- not. waving is 1 for plants and 2 for leaves.
	if (def.waving or 0) == 0 and out.spots > 0 and
			drawtype ~= DRAWTYPE_LIQUID and
			drawtype ~= DRAWTYPE_FLOWINGLIQUID then
		out.static_spots = math.max(out.static_spots, out.spots)
		out.spots = 0
	end

	-- Fire is drawn as light, not as a surface
	if drawtype == DRAWTYPE_FIRELIKE then
		out.spec_strength = 0
		out.spots = 0
		out.static_spots = 0
	end
	return out
end

-- What the guessing has to hold, checked at load: the cases the table above is
-- written for actually come out of it.
do
	local water = M.for_node({name = "default:water_source", drawtype = 2})
	assert(water.spots > 0 and water.roughness < 0.4, "surface: water")
	local leaves = M.for_node({name = "default:leaves", drawtype = 5,
			waving = 2, groups = {snappy = 3}})
	assert(leaves.translucency > 0.3, "surface: leaves")
	local dirt = M.for_node({name = "default:dirt", drawtype = 0,
			groups = {crumbly = 3}})
	assert(dirt.bumpiness > 0.5 and dirt.spec_strength < 0.2, "surface: dirt")
	local sand = M.for_node({name = "default:sand", drawtype = 0,
			groups = {crumbly = 3}})
	assert(sand.static_spots > 0, "surface: sand")
	local torch = M.for_node({name = "default:torch", drawtype = 7,
			light_source = 14})
	assert(torch.static_spots == 0 and torch.spots == 0, "surface: torch")
	local glass = M.for_node({name = "default:glass", drawtype = 4})
	assert(glass.roughness < 0.2 and glass.spec_strength > 0.9,
			"surface: glass")
	local plain = M.for_node(nil)
	assert(plain.roughness == 0.95 and plain.spots == 0, "surface: default")
end

return M
-- vim: set noet ts=4 sw=4:
