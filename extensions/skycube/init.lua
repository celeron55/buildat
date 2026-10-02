-- Buildat: extensions/skycube/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The sky, rendered into a small cube for the world to reflect: sun, moon
-- and dawn where they are, rather than the gradient VoxelSky.xml baked at
-- build time with a sun disc at one fixed direction. One piece for both
-- Luanti clients -- apps/vanilla and extensions/luanti_client --
-- since the sky shader and the zone handover are shared between them. See
-- [SKY_REFLECTIONS] in doc/plan/rendering_plan.md.
--
--   local skycube = require("buildat/extension/skycube")  -- the sandbox hands out .safe
--   local cube = skycube.new(magic, sky_material)  -- the skybox's material
--   zone.zoneTexture = cube.texture
--   cube:update()   -- when the sky has moved enough to show
--
-- The cube is a scene of its own holding one Skybox that shares the sky's
-- material, so whatever the client sets on the material -- the hour's
-- colours, the sun's direction, the moon -- is what the cube draws, and
-- six viewports on the cube's faces with one camera each at the origin.
-- The faces are drawn only when update() asks: a reflection nobody
-- watches change is not worth six renders a frame.
local M = {safe = {}}

-- 64 a side: a reflection is mip-blurred by roughness and a mirror of the
-- sky at this size is a sky
local SIZE = 64

-- Where each of Urho3D's six faces looks: the same directions, set the
-- same way (the node's direction, world up), that View.cpp gives a point
-- light's shadow cameras, so the faces land where the cube-map sampler
-- expects them
local FACES = {
	{face = "FACE_POSITIVE_X", dir = {1, 0, 0}},
	{face = "FACE_NEGATIVE_X", dir = {-1, 0, 0}},
	{face = "FACE_POSITIVE_Y", dir = {0, 1, 0}},
	{face = "FACE_NEGATIVE_Y", dir = {0, -1, 0}},
	{face = "FACE_POSITIVE_Z", dir = {0, 0, 1}},
	{face = "FACE_NEGATIVE_Z", dir = {0, 0, -1}},
}

local Cube = {}
Cube.__index = Cube

function M.safe.new(magic, material)
	local self = setmetatable({}, Cube)
	self.scene = magic.Scene()
	self.scene:CreateComponent("Octree")
	local node = self.scene:CreateChild("Sky")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	box.material = material

	-- Half floats: the sky is drawn in HDR at the reference's radiances
	-- (several times white, see [PBR_FIT]) and eight bits would clip it
	self.texture = magic.TextureCube:new()
	if not self.texture:SetSize(SIZE, magic.Graphics.GetRGBAFloat16Format(),
			magic.TEXTURE_RENDERTARGET) then
		error("skycube: could not make a " .. SIZE .. " render target cube")
	end
	-- The texture held by the engine, not only by whoever draws with it:
	-- a Lua handle does not count in Urho3D's reference count, and when
	-- a game with its own six-picture skybox took the cube off the
	-- world's zone, the cube was freed under these surfaces and the next
	-- update() wrote into freed memory (nodecore, 2026-09-21: the client
	-- died ten seconds in). A Zone of the cube's own scene holds it; the
	-- scene is held by the faces' viewports.
	local hold = node:CreateComponent("Zone")
	hold.zoneTexture = self.texture
	hold.priority = -1000
	self.surfaces = {}
	for i, f in ipairs(FACES) do
		local cam_node = self.scene:CreateChild("Face" .. i)
		cam_node.direction = magic.Vector3(f.dir[1], f.dir[2], f.dir[3])
		local camera = cam_node:CreateComponent("Camera")
		camera.fov = 90
		camera.nearClip = 0.1
		camera.farClip = 100
		local surface = self.texture:GetRenderSurface(magic[f.face])
		surface:SetViewport(0, magic.Viewport:new(self.scene, camera))
		surface.updateMode = magic.SURFACE_MANUALUPDATE
		self.surfaces[i] = surface
	end
	self:update()
	return self
end

-- Draw the six faces again, on the next frame
-- **One face a frame, not six in one** ([CLIENT_FRAME], 2026-09-26).
-- Six faces queued together are six scene renders in the same frame, and
-- on a client whose frame is already the GPU's that shows as a bump once
-- a second: a settled VoxeLibre world peaked at 0.055 to 0.073 s with
-- them together and 0.049 to 0.057 with the cube left alone. The sky
-- moves slowly enough that a face which is five frames behind the others
-- cannot be told apart -- what a player would see is the bump.
--
-- `update()` asks for a refresh; the faces go out one a frame from
-- `tick()`, which the game calls every frame.
function Cube:update()
	self.due = #self.surfaces
end

function Cube:tick()
	if (self.due or 0) <= 0 then
		return
	end
	local i = #self.surfaces - self.due + 1
	self.due = self.due - 1
	local surface = self.surfaces[i]
	if surface then
		surface:QueueUpdate()
	end
end

-- Everything at once, for the first build of the cube: a world whose
-- reflections are a sixth of a sky for the first frames looks wrong in a
-- way a moving sky does not
function Cube:update_now()
	self.due = 0
	for _, surface in ipairs(self.surfaces) do
		surface:QueueUpdate()
	end
end

return M
