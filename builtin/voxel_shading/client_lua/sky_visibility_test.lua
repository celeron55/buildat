-- Self-check for the sky visibility sweep in module.lua, which is the one
-- piece of that file with logic in it rather than plumbing. Runs the real
-- module against a made-up voxel world; everything the module talks to is
-- stubbed here.
--
--   $ lua builtin/voxel_shading/client_lua/sky_visibility_test.lua
--
-- Run from the repository root. The direction lookup below is the shader's,
-- written a second time: what it checks is that a cell the client fills
-- looking one way is the cell the shader reads looking that same way.

local MODULE = "builtin/voxel_shading/client_lua/module.lua"

-- The module asks voxelworld for the chunk size and the chunks around the
-- camera, and hands them to buildat.cast_voxel_rays, which is engine C++. Both
-- are stubbed here: world(p) is the voxel data -- nil where there is none,
-- else a voxel with an id and a skylight of 0..15 -- and the stub marcher
-- below implements the contract that binding documents. What this checks is
-- the module's own part: which way a cell looks, how a ray's answer becomes a
-- cell value, and that the shader's lookup finds the cell the client filled.
-- Ids are as the games register them: 0 is no voxel at all, 1 is air, and
-- everything above that is solid.
local AIR, ROCK = 1, 2
local CHUNK = 16
local world = nil

local function fake_voxel(id, skylight)
	return {id = id, skylight = skylight}
end

local RAY = {BLOCKED = 0, NO_DATA = 1, RANGE = 2, SKYLIGHT = 3}

-- Stands in for buildat.cast_voxel_rays. Steps voxel by voxel rather than by
-- the binding's DDA, which is close enough for a world made of slabs.
local function cast_voxel_rays(args)
	local status, skylight_out, steps_out = {}, {}, {}
	local n = 0
	for di = args.first, args.first + args.count - 1 do
		local dir = args.directions[di]
		if dir == nil then break end
		n = n + 1
		local len = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
		local st, sky, steps = RAY.RANGE, -1, 0
		for i = 1, args.max_steps do
			steps = i
			local v = world({
				x = args.origin.x + dir.x / len * i,
				y = args.origin.y + dir.y / len * i,
				z = args.origin.z + dir.z / len * i,
			})
			if v == nil then
				st = RAY.NO_DATA
				break
			end
			if v.id ~= AIR then
				st = RAY.BLOCKED
				break
			end
			sky = v.skylight
			if args.stop_skylight > 0 and sky >= args.stop_skylight then
				st = RAY.SKYLIGHT
				break
			end
		end
		status[n], skylight_out[n], steps_out[n] = st, sky, steps
	end
	return {count = n, status = status, skylight = skylight_out,
			steps = steps_out, hit_id = {}}
end

local voxelworld_stub
voxelworld_stub = {
	material_cb = nil,
	sub_material_update = function(cb) voxelworld_stub.material_cb = cb end,
	chunk_size_voxels = {x = CHUNK, y = CHUNK, z = CHUNK},
	get_static_node = function(chunk_p) return {chunk_p = chunk_p} end,
	get_volume = function(node) return {} end,
	get_voxel_registry = function() return {} end,
}

-- The shader gets the values as a buffer parameter; here the buffer keeps
-- them as a table so the test can read them back
local function fake_buffer()
	return {floats = {}}
end

local function fake_write_floats(buffer, values)
	local floats = {}
	for i, v in ipairs(values) do floats[i] = v end
	buffer.floats = floats
end

-- The values reach the shader as a parameter on the render path's scene pass
-- commands; this is the one command a viewport is stubbed to have
local params = {}
local scene_pass_command = {
	type = 2, -- CMD_SCENEPASS
	SetShaderParameter = function(self, name, value) params[name] = value end,
}
local render_path = {
	GetNumCommands = function() return 1 end,
	GetCommand = function(self, i) return scene_pass_command end,
	-- The real one sets the value on every command that already carries the
	-- name, which after the first declaring walk is the scene pass
	SetShaderParameter = function(self, name, value)
		if params[name] ~= nil then params[name] = value end
	end,
}
local viewport = {renderPath = render_path}
local material = {
	SetShaderParameter = function(self, name, value) params[name] = value end,
	SetTechnique = function() end,
	SetTexture = function() end,
}
local node = {
	GetID = function() return 1 end,
	GetComponent = function(self, name)
		return {GetMaterial = function(self, i)
			return i == 0 and material or nil
		end}
	end,
}

local camera_pos = {x = 0.0, y = 0.0, z = 0.0}
local camera_node = {GetWorldPosition = function() return camera_pos end}

local env = setmetatable({
	buildat = {Vector3 = function(x, y, z) return {x = x, y = y, z = z} end,
		VOXEL_RAY = RAY,
		write_floats = fake_write_floats,
		get_time_us = function() return 0 end,
		cast_voxel_rays = cast_voxel_rays,
		-- The threaded pair, as the engine's contract describes it: start
		-- takes what the blocking call takes, collect answers nil until the
		-- marching is done. Ready on the second ask rather than the first, so
		-- the module's waiting path is exercised and not just the lucky one.
		cast_voxel_rays_start = function(args)
			return {out = cast_voxel_rays(args), polls = 0}
		end,
		cast_voxel_rays_collect = function(job)
			job.polls = job.polls + 1
			if job.polls < 2 then return nil end
			return job.out
		end,
		Logger = function()
			return setmetatable({},
					{__index = function() return function() end end})
		end},
	require = function(name)
		if name == "buildat/module/voxelworld" then return voxelworld_stub end
		return {
			cache = {GetResource = function() return {} end},
			Vector3 = function(x, y, z) return {x = x, y = y, z = z} end,
			Material = {new = function() return material end},
			renderer = {GetViewport = function() return viewport end},
			CMD_SCENEPASS = 2,
			VectorBuffer = {new = fake_buffer},
			-- The real one copies; a shallow copy of the floats is enough here
			Variant = function(buffer)
				local copy = {}
				for i, v in ipairs(buffer.floats) do copy[i] = v end
				return copy
			end,
		}
	end,
}, {__index = _G})

local src = assert(io.open(MODULE)):read("*a")
local chunk
if setfenv then -- Lua 5.1, which is what the client runs
	chunk = assert(loadstring(src, MODULE))
	setfenv(chunk, env)
else
	chunk = assert(load(src, MODULE, "t", env))
end
local M = chunk()

M.set_camera(camera_node)

-- GetSkyVisibility() from PBRVoxel.glsl, in Lua
local CELLS = 6

local function vis_at(vals, x, y, z)
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	local m, u, v, face
	if ax >= ay and ax >= az then
		m, face, u, v = ax, (x >= 0 and 0 or 1), y, z
	elseif ay >= az then
		m, face, u, v = ay, (y >= 0 and 2 or 3), x, z
	else
		m, face, u, v = az, (z >= 0 and 4 or 5), x, y
	end
	local function grid(a)
		return math.max(0.0, math.min(CELLS - 1.0,
				(a / m + 1.0) * (CELLS / 2) - 0.5))
	end
	local fu, fv = grid(u), grid(v)
	local c0, r0 = math.floor(fu), math.floor(fv)
	local c1 = math.min(c0 + 1, CELLS - 1)
	local r1 = math.min(r0 + 1, CELLS - 1)
	local function cell(row, col)
		return vals[face * CELLS * CELLS + row * CELLS + col + 1]
	end
	local tu, tv = fu - c0, fv - r0
	local a = cell(r0, c0) + (cell(r0, c1) - cell(r0, c0)) * tu
	local b = cell(r1, c0) + (cell(r1, c1) - cell(r1, c0)) * tu
	return a + (b - a) * tv
end

local function sweep(w)
	world = w
	M.update(nil) -- nil snaps: a full sweep, no easing
	assert(#params.SkyVis == 216,
			"expected 216 values, got "..#params.SkyVis)
	return params.SkyVis
end

local DIRS = {
	{"+x",  1,  0,  0}, {"-x", -1,  0,  0},
	{"+y",  0,  1,  0}, {"-y",  0, -1,  0},
	{"+z",  0,  0,  1}, {"-z",  0,  0, -1},
}

-- expect: {["+y"] = 1.0, ...}, only the directions worth pinning
local function check(name, vals, expect)
	local shown = {}
	for _, d in ipairs(DIRS) do
		local got = vis_at(vals, d[2], d[3], d[4])
		table.insert(shown, string.format("%s %.2f", d[1], got))
		local want = expect[d[1]]
		if want and math.abs(got - want) > 0.2 then
			error(string.format("%s: %s is %.3f, expected %.3f",
					name, d[1], got, want))
		end
	end
	print(string.format("ok  %-16s %s", name, table.concat(shown, "  ")))
end

check("open sky", sweep(function(p) return fake_voxel(AIR, 15) end),
		{["+x"] = 1, ["-x"] = 1, ["+y"] = 1, ["-y"] = 1, ["+z"] = 1,
			["-z"] = 1})

check("solid rock", sweep(function(p) return fake_voxel(ROCK, 0) end),
		{["+x"] = 0, ["-x"] = 0, ["+y"] = 0, ["-y"] = 0, ["+z"] = 0,
			["-z"] = 0})

-- No voxel data at all reads as outdoors rather than as rock: a game whose
-- world has not arrived yet is not in a cave
local nodes = voxelworld_stub.get_static_node
voxelworld_stub.get_static_node = function() return nil end
check("no data", sweep(function(p) return nil end),
		{["+x"] = 1, ["+y"] = 1, ["+z"] = 1})
voxelworld_stub.get_static_node = nodes

-- Standing on the ground: sky above, rock below
check("ground", sweep(function(p)
	if p.y < 0 then return fake_voxel(ROCK, 0) end
	return fake_voxel(AIR, 15)
end), {["+y"] = 1, ["-y"] = 0})

-- A tunnel with its mouth eight voxels along +x and open ground beyond it.
-- This is what the resolution is for: a single value, or one per face, cannot
-- say that the sky is only out the mouth. A ray angled enough to meet the
-- tunnel wall before the mouth is stopped by it; one that makes it out keeps
-- going and finds nothing.
local tunnel = sweep(function(p)
	if p.x > 8 then
		return fake_voxel(AIR, 15) -- Outside, in the open
	end
	if math.abs(p.y) > 2 or math.abs(p.z) > 2 then
		return fake_voxel(ROCK, 0)
	end
	return fake_voxel(AIR, math.max(0, math.min(15, (math.floor(p.x) - 4) * 8)))
end)
check("tunnel +x", tunnel,
		{["-x"] = 0, ["+y"] = 0, ["-y"] = 0, ["+z"] = 0, ["-z"] = 0})
local out = vis_at(tunnel, 1, 0, 0)
assert(out > 0.3, "tunnel +x: the mouth of the tunnel is dark: "..out)
-- 45 degrees off the tunnel is into the rock
local off = vis_at(tunnel, 1, 1, 0)
assert(off < out * 0.7, "tunnel +x: rock beside the mouth is lit: "..off)

-- A cavern wider than a ray is long, unlit: every ray runs its whole length
-- through air and meets nothing, so being stopped by rock is not what tells
-- us there is no sky here. The air the rays end in is dark, and that does.
check("dark cavern", sweep(function(p) return fake_voxel(AIR, 0) end),
		{["+x"] = 0, ["-x"] = 0, ["+y"] = 0, ["-y"] = 0, ["+z"] = 0,
			["-z"] = 0})

-- Deep in a cave, dt-driven updates ease rather than snap
world = function(p) return fake_voxel(ROCK, 0) end
for i = 1, 400 do M.update(1 / 60) end
local dark = vis_at(params.SkyVis, 0, 1, 0)
assert(dark < 0.05, "easing never got there: "..dark)
print("ok  eased")
