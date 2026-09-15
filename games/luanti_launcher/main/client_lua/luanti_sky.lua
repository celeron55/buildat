-- Buildat: luanti_launcher/client_lua/luanti_sky.lua
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
local log = buildat.Logger("luanti_launcher")
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

	function self:enabled(on)
		node.enabled = on and true or false
	end

	log:info("the sky is Luanti's own shader")
	return self
end

return M
-- vim: set noet ts=4 sw=4:
