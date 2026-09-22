-- Buildat: extensions/luanti_client/res/minimap.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's minimap, the way both Luanti clients draw it ([EXT_HUD_PARITY]):
-- the world around the player from above. Urho3D's View3D is what makes
-- one possible at all -- a UI element that renders a scene into a texture
-- of its own size -- and what it renders is the world itself rather than a
-- picture built out of what the client knows: an orthographic camera over
-- the player, looking down, on the scene that is already there.
--
-- Official's V walks the modes: off, the surface at three sizes, the radar
-- at three -- minimap.cpp's. The radar is a thin slice at the player's
-- height, seen from just above it; the surface is the world from high up.
-- simplified: north stays up and the radar shows the tops of the nodes at
-- the player's level rather than official's air-or-not scan.
--
-- Served by the luanti module as luanti/minimap.lua for the sandbox and
-- dofile'd by the extension, so what it needs comes in the call:
--   new{magic =, scene =, parent = <UI element>, render_path = <or nil>,
--       w =, h =, height = <or 120>}
--                       -> a minimap, placed by the caller (m.view)
-- height is how far over the player the surface camera sits, which is
-- what it can see down through: under the fog's start, or the picture is
-- the fog's colour (the extension's fog begins at 0.7 of its view range).
--   m:set_mode(i)       -> MODES[i] applied; m.mode is i
--   m:follow(p, dt)     -> over p, drawn again a few times a second
--   m:destroy()
local M = {}

local HZ = 4
-- How far over the player the surface camera sits, which is what it can
-- see down through: a player under a mountain sees the mountain
local HEIGHT = 120

M.MODES = {
	{label = "Minimap hidden", nodes = 0},
	{label = "Minimap in surface mode, Zoom x4", nodes = 64},
	{label = "Minimap in surface mode, Zoom x2", nodes = 128},
	{label = "Minimap in surface mode, Zoom x1", nodes = 256},
	{label = "Minimap in radar mode, Zoom x4", nodes = 64, radar = true},
	{label = "Minimap in radar mode, Zoom x2", nodes = 128, radar = true},
	{label = "Minimap in radar mode, Zoom x1", nodes = 256, radar = true},
}

function M.new(o)
	local magic = o.magic
	local HEIGHT = o.height or HEIGHT
	local m = {mode = 2, height = HEIGHT, timer = 0}
	local view = o.parent:CreateChild("View3D")
	view.size = magic.IntVector2(o.w, o.h)
	-- A picture of the world costs a second pass over the world, so it is
	-- drawn a few times a second rather than every frame
	view.autoUpdate = false
	local node = o.scene:CreateChild("minimap_camera")
	local cam = node:CreateComponent("Camera")
	cam.orthographic = true
	cam.orthoSize = 64
	cam.nearClip = 0.5
	cam.farClip = HEIGHT * 4
	node.direction = magic.Vector3(0, -1, 0)
	-- Not the element's own scene: this one is the world's and has to
	-- outlive every form and HUD there is
	view:SetView(o.scene, cam, false)
	-- And drawn the way the world is drawn: the window's own render path
	-- carries the tonemap, and an HDR scene without it is white
	if o.render_path then
		view:GetViewport().renderPath = o.render_path:Clone()
	end
	m.view, m.camera = view, node

	function m:set_mode(i)
		self.mode = i
		local mode = M.MODES[i]
		self.view.visible = mode.nodes > 0
		if mode.nodes > 0 then
			local c = self.camera:GetComponent("Camera")
			c.orthoSize = mode.nodes
			-- From an eye, so the slice reaches under the feet
			c.farClip = mode.radar and 4 or HEIGHT * 4
			self.height = mode.radar and 1.5 or HEIGHT
		end
		return mode.label
	end

	function m:next_mode()
		return self:set_mode(self.mode % #M.MODES + 1)
	end

	function m:follow(p, dt)
		self.camera.position = magic.Vector3(p.x, p.y + self.height, p.z)
		self.timer = self.timer + dt
		if self.timer < 1 / HZ then
			return
		end
		self.timer = 0
		self.view:QueueUpdate()
	end

	function m:destroy()
		self.camera:Remove()
		self.view:Remove()
	end

	m:set_mode(m.mode)
	return m
end

return M
-- vim: set noet ts=4 sw=4:
