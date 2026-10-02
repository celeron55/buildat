-- Buildat: vanilla/client_lua/luanti_sky.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The sky, drawn by Luanti's own shader rather than buildat's.
--
-- `extensions/luanti_client/res/LuantiSky.glsl` is the sky the other Luanti
-- client draws, and this is the second consumer of it -- the same
-- arrangement the world's shaders are already in, one set shared by both
-- clients with `builtin/voxel_shading` left to the nine games that want
-- buildat's look. See [SHADER_HOME] in doc/plan/master_plan.md.
--
-- **What this is not** is a new sky. The launcher works out what colour the
-- sky is at this hour, how far the sun has got and how many stars are out,
-- and goes on doing exactly that; this only takes those answers to a
-- different shader, whose parameters have different names and one different
-- shape. Where the two disagree is written down at each call.
--
-- **Every uniform is set here at creation**, including the ones nothing ever
-- changes: a shader parameter a material never sets reads as zero, and zero
-- for most of these is a black sky.
local log = buildat.Logger("vanilla")
local magic = require("buildat/extension/urho3d")

local M = {}

-- How fast the cloud layer drifts. Luanti's own default is two nodes a
-- second; LuantiSky counts in its own units and says so.
local CLOUD_WIND = {x = 0.004, y = 0.0}
-- How far past white the sun's disc is drawn, which is what makes it read as
-- a light rather than a white circle. The extension's own value.
local SUN_OVEREXPOSURE = 2.5
-- Half the width of the moon's square at a game scale of one, on a plane one
-- unit along its direction: Luanti's own ratio, which the extension carries
-- as MOON_HALF beside SUN_HALF = 0.075.
M.MOON_HALF = 0.048

-- How many stars a game asks for when it says nothing, and how many of the
-- star grid's cells hold one at that count. **The grid is LuantiSky.glsl's
-- own**, two faces of STAR_GRID squared cells, which is about a quarter of a
-- million -- so a thousand stars is four thousandths of them, and a game
-- asking for more gets more in proportion. extensions/luanti_client carries
-- the same two numbers; they belong to the shader both of them drive.
M.STARS_DEFAULT = 1000
M.STAR_DENSITY_DEFAULT = 0.004

-- What the sun and the moon go as they cross the horizon, when the game has
-- not said: Luanti's own default fog_sun_tint #f47d1d and fog_moon_tint
-- #7f99cc. Not the horizon of this hour, which is a washed-out blue and
-- lights a sunset grey. A game's own arrive as game_sky.sun_tint and
-- moon_tint now -- see [SKY_KNOBS] -- and these are the fallback.
M.SUN_TINT = {r = 244 / 255, g = 125 / 255, b = 29 / 255}
M.MOON_TINT = {r = 127 / 255, g = 153 / 255, b = 204 / 255}

-- **The schedule, which is extensions/luanti_client's** (see [LIGHT_SHAPE]
-- in doc/plan/rendering_plan.md: for the sky, the sun, the moon and the
-- light, the extension is the reference implementation and its shape is
-- taken whole). Everything below is in Luanti's own units of the day,
-- 0...24000, so it is a fixed hour however fast a game's clock runs.
--
-- Why a fade and not a switch: a directional light below the horizon shines
-- up through the world, and its specular is then the brightest thing in a
-- night frame, lit from the wrong side of the sky. So the sun is taken out
-- of the scene for the night and the moon is put in, each fading over the
-- hour on either side of the sun being level with the horizon.
local SUN_RISE = 5000     -- nothing before this
local SUN_UP = 6000       -- full sun from here
local SUN_SET = 18000     -- full sun until here
local SUN_DOWN = 19000    -- nothing after this

-- The moon's day is a little longer than the sun's night: it is going
-- before the sun arrives and does not come back until the sun is well gone.
local MOON_FADE_OUT = 4500
local MOON_OUT = 5500
local MOON_FADE_IN = 18500
local MOON_IN = 19500

-- Nothing above the horizon shines from under it. The clocks are where the
-- fade is shaped; this is the line itself, taken from where the body
-- actually is. A couple of degrees of softness, because a light that
-- switches off in one frame is a light that pops.
local HORIZON_FADE = 0.05

-- Where the sun is for the purpose of casting a shadow, which is not quite
-- where it is: a shadow map rasterized afresh every frame from a light that
-- has turned a little between two of them has crawling edges. Holding the
-- direction still for a step at a time trades the crawl for a small jump.
-- A hundred of these is a degree and a half.
local SUN_STEP = 100

-- The half hour either side of the sun crossing the horizon, which is the
-- window dawn and dusk happen in.
local RED_HALF_WIDTH = 500
-- How much of that red the light takes. Not all of it: the tint is the
-- colour a band of sky is painted, which is deeper than the light painting
-- it.
local SUN_TINT_SHARE = 0.9

local function clamp01(v)
	return v < 0 and 0 or (v > 1 and 1 or v)
end

-- 0 before the rise, 1 between the rise and the set, 0 after it, and the way
-- across each ramp in between
local function up_between(t, rise_from, rise_to, set_from, set_to)
	t = (t or 12000) % 24000
	if t <= rise_from or t >= set_to then
		return 0
	elseif t < rise_to then
		return (t - rise_from) / (rise_to - rise_from)
	elseif t <= set_from then
		return 1
	end
	return (set_to - t) / (set_to - set_from)
end

function M.sun_amount(t)
	return up_between(t, SUN_RISE, SUN_UP, SUN_SET, SUN_DOWN)
end

-- The same shape read the other way round, so the four numbers above say
-- when the moon is out rather than being the sun's turned inside out
function M.moon_amount(t)
	return 1 - up_between(t, MOON_FADE_OUT, MOON_OUT, MOON_FADE_IN, MOON_IN)
end

function M.above_horizon(sine_of_elevation)
	return clamp01((sine_of_elevation or 0) / HORIZON_FADE)
end

-- **How far the sun and the moon's orbit is tilted out of the vertical
-- plane**, and who decides it.
--
-- Luanti's default orbit is axis-aligned: the sun rises due east, passes
-- through the zenith and sets due west, and `body_orbit_tilt` is how a game
-- says otherwise. That is a poor light to draw a world by -- every hour
-- lights the same two faces of a cube, and noon drops its shadows straight
-- down -- so this client tilts it when the game has no opinion.
--
-- **A game that has an opinion is obeyed exactly, and keeps being obeyed**,
-- including when it asks for zero: a game that tilts one dimension and not
-- another means the second one, and guessing over the top of it would be
-- worse than the default it replaces.
--
-- `own` is BUILDAT_LUANTI_ORBIT_TILT where it is set, arriving through
-- luanti.world_info(). **Zero is what a comparison against official Luanti
-- wants**, because zero is what Luanti does with a game that never asks.
M.OWN_ORBIT_TILT = 22.8
local game_asked_tilt = false

function M.orbit_tilt(game_tilt, own)
	if game_tilt ~= nil then
		game_asked_tilt = true
		return game_tilt
	end
	if game_asked_tilt then
		-- It had one and has stopped sending it; that is still its sky
		return 0
	end
	if own == nil then
		return M.OWN_ORBIT_TILT
	end
	return own
end

function M.stepped_time(t)
	return math.floor((t or 12000) / SUN_STEP + 0.5) * SUN_STEP
end

function M.low_sun(t)
	t = (t or 12000) % 24000
	local d = math.min(math.abs(t - SUN_RISE), math.abs(t - SUN_DOWN))
	local u = 1 - d / RED_HALF_WIDTH
	if u <= 0 then
		return 0
	end
	return u * u * (3 - 2 * u)
end

-- How much of SUN_TINT the light shines with at this hour
function M.sun_tint_share(t)
	local low = M.low_sun(t)
	return (1 - (1 - low) * (1 - low)) * SUN_TINT_SHARE
end

-- Where the sun is, as a direction to it, with y the sine of its elevation.
-- Luanti's own: the day is stretched so the night takes less than half of it
-- (getWickedTimeOfDay), and the sun rises towards +X and sets towards -X.
--
-- tilt is Luanti's body_orbit_tilt in degrees, which turns the orbit about
-- the axis the sun rises over -- sky.cpp does it as rotateYZBy, so it is the
-- y and z of the direction that turn and the elevation this answers with is
-- the tilted one.
function M.sun_direction(t, tilt)
	t = ((t or 12000) % 24000) / 24000
	local wn = 0.415 / 2
	local w
	if t > wn and t < 1 - wn then
		w = (t - wn) / (1 - wn * 2) * 0.5 + 0.25
	elseif t < 0.5 then
		w = t / wn * 0.25
	else
		w = 1 - (1 - t) / wn * 0.25
	end
	local a = math.rad(w * 360 - 90)
	local x, y, z = math.cos(a), math.sin(a), 0
	if tilt and tilt ~= 0 then
		local r = math.rad(tilt)
		local c, sn = math.cos(r), math.sin(r)
		y, z = y * c - z * sn, y * sn + z * c
	end
	return x, y, z
end

-- The light the sky has before the sun is up ([DAWN_LIGHT]), as a day
-- factor: zero below PREDAWN_LOW, PREDAWN_PEAK at the horizon, and nothing
-- at all above it, where the day's own ramp is larger anyway and takes over
-- without a step. height is the sine of the sun's elevation.
--
-- -18 degrees is where the stretched day puts 4:00, which is where the user
-- saw a bright halo over black ground; the peak is official's
-- time_to_daynight_ratio around daybreak (0.25 at 4:52, 0.35 at 5:07).
local PREDAWN_LOW = -0.309
local PREDAWN_PEAK = 0.3

function M.predawn(height)
	if height >= 0 or height <= PREDAWN_LOW then
		return 0
	end
	-- BUILDAT_LUANTI_NO_PREDAWN=1 turns it off, which is how dawn_light.sh
	-- reads the same hours with and without it
	local off = buildat.get_env("BUILDAT_LUANTI_NO_PREDAWN")
	if off and off ~= "" then
		return 0
	end

	return PREDAWN_PEAK * (height - PREDAWN_LOW) / -PREDAWN_LOW
end

if not (buildat.get_env("BUILDAT_LUANTI_NO_PREDAWN") or ""):find("%S") then
	assert(M.predawn(0.2) == 0 and M.predawn(-0.5) == 0,
			"nothing above the horizon and nothing before it begins")
	assert(math.abs(M.predawn(-0.0001) - PREDAWN_PEAK) < 0.001,
			"and it peaks at the horizon")
	-- Where it hands over: the day's own ramp is the larger of the two from
	-- about -6 degrees up, so nothing steps at the crossing
	local ramp = function(h) return math.max(0, math.min(1, (h + 0.15) / 0.3)) end
	assert(ramp(-0.05) > M.predawn(-0.05), "the day's ramp wins near the horizon")
	assert(ramp(-0.25) < M.predawn(-0.25), "and this one before it")
end

-- What the schedule has to hold, which is the extension's own check: the two
-- never leave the sky empty between them, the moon is out of the way by the
-- time the sun is worth anything, and the clock agrees with where the sun
-- actually is.
do
	assert(M.above_horizon(-1) == 0 and M.above_horizon(0) == 0 and
			M.above_horizon(1) == 1, "the horizon line")

	-- Who decides the orbit's tilt, in the order it has to be decided in.
	-- The stickiness is the point: a game that has spoken once is obeyed
	-- from then on, zero included.
	assert(M.orbit_tilt(nil, nil) == M.OWN_ORBIT_TILT,
			"nobody asked, so it is ours")
	assert(M.orbit_tilt(nil, 0) == 0, "the client was told to use zero")
	assert(M.orbit_tilt(30, nil) == 30, "the game asked for thirty")
	assert(M.orbit_tilt(nil, 45) == 0,
			"the game has had an opinion, so ours stays out of it")
	assert(M.orbit_tilt(0, nil) == 0, "and it may ask for zero")
	-- The check itself was the game that had spoken: the stickiness it
	-- proves outlived it, and every real client ran at zero. Forgotten
	-- here so the first real call is the first.
	game_asked_tilt = false
	assert(M.orbit_tilt(nil, 22) == 22, "and the check leaves no opinion")
	assert(M.sun_amount(12000) == 1 and M.moon_amount(12000) == 0, "noon")
	assert(M.sun_amount(0) == 0 and M.moon_amount(0) == 1, "midnight")
	assert(M.moon_amount(SUN_RISE) > 0.4,
			"the moon is still up at sunrise")
	assert(M.moon_amount(MOON_OUT) == 0 and M.sun_amount(MOON_OUT) > 0.4,
			"the sun has the sky to itself once the moon is gone")
	assert(M.sun_amount(SUN_DOWN) == 0 and M.moon_amount(SUN_DOWN) > 0.4,
			"the moon is up by the time the sun is gone")

	local function elevation(t)
		local _, y = M.sun_direction(t)
		return y
	end
	assert(math.abs(elevation(SUN_RISE)) < 0.02, "the sun rises at 05:00")
	assert(math.abs(elevation(SUN_DOWN)) < 0.02, "the sun sets at 19:00")
	assert(elevation(12000) > 0.9, "the sun is overhead at noon")
	assert(elevation(0) < -0.9, "the sun is under the world at midnight")

	assert(M.low_sun(SUN_RISE) == 1 and M.low_sun(SUN_DOWN) == 1,
			"reddest as the sun crosses")
	assert(M.low_sun(12000) == 0 and M.low_sun(0) == 0,
			"nothing of it at noon or at midnight")
	assert(M.sun_tint_share(SUN_RISE) > 0.89,
			"crossing the horizon the light is nearly all the tint")
	assert(M.sun_tint_share(12000) == 0, "and at noon it is its own colour")
	-- And that what it hands over to is a red rather than a warm white,
	-- which is the whole of what the window is for
	assert(M.SUN_TINT.r - M.SUN_TINT.b > 0.5, "the low sun is red")

	-- The step is a step and nothing more
	assert(M.stepped_time(12049) == 12000 and M.stepped_time(12051) == 12100,
			"the shadow's direction is held still a step at a time")

	-- And a tilted orbit turns the sun out of the vertical plane without
	-- changing how far round the day it is
	local tx, ty, tz = M.sun_direction(12000, 30)
	local ux, uy, uz = M.sun_direction(12000)
	assert(math.abs(tx - ux) < 1e-9, "a tilt leaves the rising axis alone")
	assert(tz > 0.4 and ty < uy,
			"and takes the sun off the vertical plane at noon")
end

function M.new(scene, sun_dir, defaults)
	local node = scene:CreateChild("LuantiSky")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	local material = magic.Material:new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"luanti_client/res/LuantiSky.xml"))
	-- LuantiSky.xml says cull="none" itself, unlike Urho3D's own skybox
	-- technique; a box seen from the inside is entirely back-facing, and a
	-- material that does not say so draws nothing at all.
	box.material = material

	local self = {node = node, material = material}

	-- The cloud colour is a colour here where builtin/voxel_shading takes a
	-- brightness and has the colour baked in, so both halves are kept and
	-- the parameter is written from the two together.
	local cloud_rgb = {r = 0.9, g = 0.92, b = 0.95}
	local cloud_light = defaults.cloud_light or 1.0

	local function put_cloud()
		material:SetShaderParameter("CloudColor", magic.Vector3(
				cloud_rgb.r * cloud_light,
				cloud_rgb.g * cloud_light,
				cloud_rgb.b * cloud_light))
	end

	-- Everything, at what the sky looked like before any game said anything
	material:SetShaderParameter("SunDirection", magic.Vector3(
			-sun_dir.x, -sun_dir.y, -sun_dir.z))
	material:SetShaderParameter("SkyTop", magic.Vector3(
			defaults.zenith.r, defaults.zenith.g, defaults.zenith.b))
	material:SetShaderParameter("SkyHorizon", magic.Vector3(
			defaults.horizon.r, defaults.horizon.g, defaults.horizon.b))
	material:SetShaderParameter("SunTint", magic.Vector3(
			defaults.sun_color.r, defaults.sun_color.g,
			defaults.sun_color.b))
	material:SetShaderParameter("SunSize", defaults.sun_half)
	material:SetShaderParameter("SunOverexposure", SUN_OVEREXPOSURE)
	-- The moon is a body of its own here, drawn opposite the sun. Half its
	-- width is Luanti's own ratio to the sun's, which the extension carries
	-- as MOON_HALF.
	material:SetShaderParameter("MoonSize", M.MOON_HALF)
	material:SetShaderParameter("MoonTextured", 0.0)
	material:SetShaderParameter("SunTextured", 0.0)
	material:SetShaderParameter("StarDensity", 0.0)
	material:SetShaderParameter("StarColor", magic.Vector3(0.9, 0.9, 1.0))
	material:SetShaderParameter("StarFade", 0.0)
	material:SetShaderParameter("CloudCoverage", defaults.cloud_cover)
	material:SetShaderParameter("CloudAlpha", 1.0)
	material:SetShaderParameter("CloudWind", magic.Vector2(
			CLOUD_WIND.x, CLOUD_WIND.y))
	-- What a player who cannot see the sky is under, and whether the game
	-- allows the dimming at all. Luanti's own indoors default is #646464
	-- and auto_dim_skybox is on; see set_indoors() below and [CAVE_SKY].
	material:SetShaderParameter("SkyIndoors", magic.Vector3(0.39, 0.39, 0.39))
	material:SetShaderParameter("SkyAutoDim", 1.0)
	put_cloud()

	-- The gradient's two ends, and how much of the sky is cloud. Anything
	-- nil is left as it is, which is what the old sky did too.
	function self:set_look(zenith, horizon, cloud_cover)
		if zenith then
			material:SetShaderParameter("SkyTop", magic.Vector3(
					zenith.r, zenith.g, zenith.b))
		end
		if horizon then
			material:SetShaderParameter("SkyHorizon", magic.Vector3(
					horizon.r, horizon.g, horizon.b))
		end
		if cloud_cover then
			material:SetShaderParameter("CloudCoverage",
					math.max(0, math.min(1, cloud_cover)))
		end
	end

	-- The pbr path's cloud: lit rather than coloured ([CLOUD_LIGHT]);
	-- the two vectors the shader adds, computed by the caller from the
	-- sun and the sky of the hour
	function self:set_cloud_lit(sun, sky)
		material:SetShaderParameter("CloudSun",
				magic.Vector3(sun.r, sun.g, sun.b))
		material:SetShaderParameter("CloudSky",
				magic.Vector3(sky.r, sky.g, sky.b))
	end

	function self:set_cloud_light(k)
		if k == nil then
			return
		end
		cloud_light = math.max(0, k)
		put_cloud()
	end

	function self:set_cloud_color(c)
		if c == nil then
			return
		end
		cloud_rgb = {r = c.r or 0.9, g = c.g or 0.92, b = c.b or 0.95}
		put_cloud()
	end

	-- Half the width of the square, and what colour it is. Zero turns it
	-- off, which is how a game says its sun or its moon is not there.
	function self:set_sun_look(half, color)
		material:SetShaderParameter("SunSize", math.max(0, half or 0))
		if color then
			material:SetShaderParameter("SunTint", magic.Vector3(
					color.r or color[1] or 1, color.g or color[2] or 1,
					color.b or color[3] or 1))
		end
	end

	-- The game's own picture of it, or nil for the shader's painted square.
	-- LuantiSky reads the sun's from sDiffMap and the moon's from
	-- sNormalMap -- two units because a material has no third one this
	-- needs.
	-- The disc at a radiance, for the pbr path; zero is Luanti's square
	function self:set_sun_radiance(r, g, b)
		material:SetShaderParameter("SunRadiance", magic.Vector3(r, g, b))
	end

	function self:set_sun_texture(texture)
		if texture then
			material:SetTexture(magic.TU_DIFFUSE, texture)
			material:SetShaderParameter("SunTextured", 1.0)
		else
			material:SetShaderParameter("SunTextured", 0.0)
		end
	end

	-- The moon is drawn opposite the sun, which is where Luanti puts it, so
	-- it needs no direction of its own: half its width is the whole of what
	-- says it is there. Its colour is the shader's, a moon having no tint to
	-- take from the horizon.
	function self:set_moon_look(half)
		material:SetShaderParameter("MoonSize", math.max(0, half or 0))
	end

	function self:set_moon_texture(texture)
		if texture then
			material:SetTexture(magic.TU_NORMAL, texture)
			material:SetShaderParameter("MoonTextured", 1.0)
		else
			material:SetShaderParameter("MoonTextured", 0.0)
		end
	end

	-- **Where the two skies disagree.** builtin/voxel_shading folds how many
	-- stars there are and how visible they are into one density, and takes a
	-- size; LuantiSky keeps the two apart and has no size. So the count goes
	-- to the density and the night ramp goes to the fade, which is the
	-- better shape: stars come out rather than appearing one by one.
	function self:set_star_look(density, color, fade)
		material:SetShaderParameter("StarDensity", math.max(0, density or 0))
		material:SetShaderParameter("StarFade",
				math.max(0, math.min(1, fade or 1)))
		if color then
			material:SetShaderParameter("StarColor", magic.Vector3(
					color.r or color[1] or 0.9, color.g or color[2] or 0.9,
					color.b or color[3] or 1.0))
		end
	end

	-- The way the light travels, as a Light's direction is, so the sun
	-- itself is the other way -- which is what the old sky took too.
	function self:set_sun_direction(dir)
		if dir then
			material:SetShaderParameter("SunDirection", magic.Vector3(
					-dir.x, -dir.y, -dir.z))
		end
	end

	-- The colour a direction that cannot see the sky is drawn as, already
	-- multiplied by how light it is, and whether the game lets this happen.
	-- What the mix is by is the sky visibility cube, per direction, which
	-- the client keeps for the reflections already -- so a cave goes dark
	-- and a tunnel mouth does not, without anything having to work out
	-- which is which. See [CAVE_SKY] in doc/plan/rendering_plan.md.
	function self:set_indoors(color, brightness)
		if color == nil then
			return
		end
		local k = math.max(0, brightness or 1)
		material:SetShaderParameter("SkyIndoors", magic.Vector3(
				(color.r or 0.39) * k, (color.g or 0.39) * k,
				(color.b or 0.39) * k))
	end

	function self:set_auto_dim(on)
		material:SetShaderParameter("SkyAutoDim", on and 1.0 or 0.0)
	end

	-- The gradient shaped as the path trace's rather than as Luanti's; see
	-- cSkyPhysical in the shader
	function self:set_physical(on)
		material:SetShaderParameter("SkyPhysical", on and 1.0 or 0.0)
	end

	-- How much sky the camera can see, as one number rather than a
	-- direction: 0 in a cave and 1 anywhere that is not one. **The sky is
	-- edited only once there is no sky to see**, which is the rule the halos
	-- cost -- mixing per direction darkened the real sky in a blob around
	-- every occluder, the visibility cube being camera-local and thirty
	-- degrees to a cell while the sky is at infinity. See [CAVE_SKY].
	function self:set_outside(k)
		material:SetShaderParameter("SkyOutside",
				math.max(0, math.min(1, k or 1)))
	end

	function self:enabled(on)
		node.enabled = on and true or false
	end

	log:info("the sky is Luanti's own shader")
	return self
end

return M
-- vim: set noet ts=4 sw=4:
