-- Buildat: extensions/luanti_client/skyvis.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- How much of the sky the camera can see in each direction, as a cube of
-- CELLS x CELLS values per face, which res/PBRVoxel.glsl multiplies its
-- reflections of the sky cube map by. That is the whole indoor/outdoor
-- treatment: there is no second, dimmed cube map and no single blend value
-- deciding which one a surface gets. Standing in a tunnel mouth, the walls
-- stop reflecting sky while the mouth still does.
--
-- Ported from builtin/voxel_shading's module.lua, which does the same thing
-- against buildat's own voxelworld; what changed is where the voxel data
-- comes from -- here the caller hands over volumes -- and that the parts a
-- Luanti client has no use for (the technique switching, the skybox, the
-- benchmarks' specular emphasis) are not here. The reasoning behind the
-- constants and the jittering is in that file and is not repeated.
--
--   local vis = skyvis.new(magic, buildat, collect)
--   vis:update(origin, dt)   -- every frame; dt of nil snaps
--
-- collect(origin) returns the voxel data to march through, as
--   {chunk_size = {x=, y=, z=}, registry = <VoxelRegistry>,
--    volumes = {{x=, y=, z=, volume = <Volume>}, ...}}
-- or nil for "no data near here", which is answered as open sky. It is
-- called once a sweep, not once a frame.

local M = {}

local FACES = 6
local CELLS = 6                -- Per face, per axis; keep in step with the
                               -- shader's SKYVIS_CELLS
local CELL_COUNT = FACES * CELLS * CELLS
local RAYS_PER_CELL = 4
local CELLS_PER_UPDATE = 36
local RAY_VOXELS = 64
local SKY_VIS_BLEND = 0.10
local SNAP_SWEEPS = 2
local MAX_IN_FLIGHT = 2
-- How often the shader parameter is put on the render path's scene passes
-- again, rather than only set on the commands that already carry it; see
-- push() for why the two are not the same call
local DECLARE_EVERY_FRAMES = 60

M.RAY_VOXELS = RAY_VOXELS
M.CELL_COUNT = CELL_COUNT

-- Face f is axis (f - f % 2) / 2 -- 0 x, 1 y, 2 z -- and sign 1 for even f,
-- -1 for odd. u runs along the lowest-numbered axis that is not the face's
-- own and v along the highest. The shader takes a direction apart the same
-- way, so the two only have to agree with each other.
local FACE_AXES = {
	{major = "x", u = "y", v = "z", sign =  1},
	{major = "x", u = "y", v = "z", sign = -1},
	{major = "y", u = "x", v = "z", sign =  1},
	{major = "y", u = "x", v = "z", sign = -1},
	{major = "z", u = "x", v = "y", sign =  1},
	{major = "z", u = "x", v = "y", sign = -1},
}
local AXIS_OFFSET = {x = 0, y = 1, z = 2}
local CELL_SIZE = 2.0 / CELLS

-- Where each cell's rays sample: a fixed per-cell offset out of the R2 low
-- discrepancy sequence, a step the whole sweep takes, and a Hammersley set
-- within the cell. One offset for the whole cube would make every cell err
-- the same way at the same moment, which reads as the scene pulsing.
local CELL_JITTER_U = {}
local CELL_JITTER_V = {}
for i = 1, CELL_COUNT do
	CELL_JITTER_U[i] = (i * 0.7548776662) % 1.0
	CELL_JITTER_V[i] = (i * 0.5698402909) % 1.0
end
local SWEEP_STEP_U = 0.6180339887
local SWEEP_STEP_V = 0.4142135624

local function radical_inverse_2(n)
	local r, f = 0.0, 0.5
	while n > 0 do
		r = r + (n % 2) * f
		n = math.floor(n / 2)
		f = f * 0.5
	end
	return r
end

local STRAT_U = {}
local STRAT_V = {}
for k = 1, RAYS_PER_CELL do
	STRAT_U[k] = (k - 0.5) / RAYS_PER_CELL
	STRAT_V[k] = radical_inverse_2(k - 1)
end

-- Which cell a direction belongs to, 1-based, the way the shader places one:
-- the largest component picks the face and the other two, divided by it, are
-- the position on it. Only the self-check uses this; the sweep goes the other
-- way. Exposed so that the check is of the same arithmetic the shader does.
function M.cell_of(x, y, z)
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	local face, u, v, major
	if ax >= ay and ax >= az then
		face = x > 0 and 1 or 2; major = ax; u, v = y, z
	elseif ay >= az then
		face = y > 0 and 3 or 4; major = ay; u, v = x, z
	else
		face = z > 0 and 5 or 6; major = az; u, v = x, y
	end
	if major <= 0 then return nil end
	local function cell_index(t)
		local c = math.floor((t / major + 1.0) / CELL_SIZE)
		return math.max(0, math.min(CELLS - 1, c))
	end
	local col, row = cell_index(u), cell_index(v)
	return ((face - 1) * CELLS + row) * CELLS + col + 1
end

function M.new(magic, buildat, collect)
	local self = {}

	-- The directions, three numbers to a ray, in cell order: one flat array
	-- rather than a table per ray, because the engine reads every one of them
	-- every frame and a table each was most of what the sampling cost.
	local dirs = {}
	for i = 1, CELL_COUNT * RAYS_PER_CELL * 3 do
		dirs[i] = 0.0
	end

	-- What the shader is using now, and what the sweep in progress has found.
	-- Starting fully lit: a world that has not arrived yet looks like it is
	-- outdoors, which it usually is.
	local sky_vis = {}
	local sweep_vis = {}
	for i = 1, CELL_COUNT do
		sky_vis[i] = 1.0
		sweep_vis[i] = 1.0
	end
	local sweep_next = 1
	local sweep_index = 0
	local declare_countdown = 0
	local in_flight = {}
	local sky_vis_buffer = magic.VectorBuffer:new()
	local sky_vis_param = nil
	local sky_vis_dirty = false
	-- Other shader parameters that belong on the same scene passes, by name.
	-- The sky colour the reflections are multiplied by is one; it is set when
	-- the sky changes, and pushed with the visibility because getting a
	-- parameter onto the render path is the same walk either way.
	local params = {SpecEmphasis = 1.0}

	-- The one table handed to buildat.cast_voxel_rays, reused: only the slice
	-- bounds, the origin and the volumes change between calls
	local ray_args = {
		directions = dirs,
		max_steps = RAY_VOXELS,
		-- Not used: skylight says the sky is open above a voxel, which is
		-- nothing to do with whether the sky lies along the ray
		stop_skylight = 0,
		-- Consecutive rays are one cell's, and the engine hands back their
		-- average per cell rather than what each of them found
		rays_per_cell = RAYS_PER_CELL,
		first = 1,
		count = 1,
		origin = {x = 0, y = 0, z = 0},
		volumes = {},
	}
	local have_volumes = false

	local function aim_dirs(index)
		local su = (index * SWEEP_STEP_U) % 1.0
		local sv = (index * SWEEP_STEP_V) % 1.0
		local i = 1
		for face = 1, FACES do
			local a = FACE_AXES[face]
			local mo = AXIS_OFFSET[a.major] + 1
			local uo = AXIS_OFFSET[a.u] + 1
			local vo = AXIS_OFFSET[a.v] + 1
			for row = 0, CELLS - 1 do
				for col = 0, CELLS - 1 do
					local bu = CELL_JITTER_U[i] + su
					local bv = CELL_JITTER_V[i] + sv
					local base = (i - 1) * RAYS_PER_CELL * 3
					for k = 1, RAYS_PER_CELL do
						local ju = (bu + STRAT_U[k]) % 1.0 - 0.5
						local jv = (bv + STRAT_V[k]) % 1.0 - 0.5
						dirs[base + mo] = a.sign
						dirs[base + uo] = (col + 0.5 + ju) * CELL_SIZE - 1.0
						dirs[base + vo] = (row + 0.5 + jv) * CELL_SIZE - 1.0
						base = base + 3
					end
					i = i + 1
				end
			end
		end
	end

	local function begin_sweep()
		sweep_next = 1
		sweep_index = sweep_index + 1
		aim_dirs(sweep_index)
	end
	begin_sweep()

	-- What the caller has to hand over, once a sweep. An empty answer is a
	-- world that has not arrived: outdoors is the right answer for it.
	local function take_volumes(origin)
		local got = collect(origin)
		if got == nil or got.volumes[1] == nil then
			have_volumes = false
			return false
		end
		ray_args.chunk_size = got.chunk_size
		ray_args.registry = got.registry
		ray_args.volumes = got.volumes
		have_volumes = true
		return true
	end

	local function keep_slice(first_cell, count_cells, out)
		local vis = out.visibility
		for c = 1, count_cells do
			sweep_vis[first_cell + c - 1] = vis[c]
		end
	end

	-- f is how much of the sweep's rays to take; 1.0 replaces the values
	local function blend_cells(first, count, f)
		for i = first, first + count - 1 do
			sky_vis[i] = sky_vis[i] + (sweep_vis[i] - sky_vis[i]) * f
		end
		sky_vis_dirty = true
	end

	local function sweep_all_open()
		for i = 1, CELL_COUNT do
			sweep_vis[i] = 1.0
		end
	end

	local function aim_args(first_cell, count_cells)
		ray_args.first = (first_cell - 1) * RAYS_PER_CELL + 1
		ray_args.count = count_cells * RAYS_PER_CELL
	end

	local function submit_slice(first_cell, count_cells)
		aim_args(first_cell, count_cells)
		in_flight[#in_flight + 1] = {first = first_cell, count = count_cells,
				job = buildat.cast_voxel_rays_start(ray_args)}
	end

	-- Blends in what has finished, oldest first, and stops at the first slice
	-- that has not: they are taken in the order they were cast.
	local function collect_slices(f)
		while in_flight[1] ~= nil do
			local slice = in_flight[1]
			local out = buildat.cast_voxel_rays_collect(slice.job)
			if out == nil then
				return
			end
			table.remove(in_flight, 1)
			keep_slice(slice.first, slice.count, out)
			blend_cells(slice.first, slice.count, f)
		end
	end

	-- Anything in flight is reading volumes it holds itself, so dropping the
	-- handles is enough; what they find is no longer wanted
	local function drop_slices()
		for i = #in_flight, 1, -1 do
			in_flight[i] = nil
		end
	end

	-- The values go on the render path's scene pass commands rather than on
	-- materials: Urho hands a scene pass command's shader parameters to every
	-- batch it draws, so this reaches every chunk in one call instead of
	-- hundreds. Declaring the name means walking the commands, which is not
	-- cheap enough for every frame, so that happens now and then and the
	-- per-frame path only updates the commands that already carry it.
	local function push()
		if sky_vis_dirty then
			sky_vis_dirty = false
			buildat.write_floats(sky_vis_buffer, sky_vis)
			sky_vis_param = magic.Variant(sky_vis_buffer)
		end
		if sky_vis_param == nil then return end
		local viewport = magic.renderer:GetViewport(0)
		if viewport == nil then return end
		local render_path = viewport.renderPath
		if render_path == nil then return end
		declare_countdown = declare_countdown - 1
		if declare_countdown <= 0 then
			declare_countdown = DECLARE_EVERY_FRAMES
			for i = 0, render_path:GetNumCommands() - 1 do
				local command = render_path:GetCommand(i)
				if command ~= nil and command.type == magic.CMD_SCENEPASS then
					command:SetShaderParameter("SkyVis", sky_vis_param)
					for name, value in pairs(params) do
						command:SetShaderParameter(name, value)
					end
				end
			end
			return
		end
		render_path:SetShaderParameter("SkyVis", sky_vis_param)
		for name, value in pairs(params) do
			render_path:SetShaderParameter(name, value)
		end
	end

	-- A shader parameter to keep on the scene passes along with the
	-- visibility; see params above
	function self:set_param(name, value)
		params[name] = value
		-- On the next frame rather than at the next declaring walk, so a sky
		-- that changes colour does not wait a second for it
		declare_countdown = 0
	end

	-- dt of nil snaps, for a camera that has been moved rather than has
	-- moved: the same averaging done at once, so a screenshot taken right
	-- after a teleport is as settled as one taken later.
	function self:update(origin, dt)
		ray_args.origin.x = origin.x
		ray_args.origin.y = origin.y
		ray_args.origin.z = origin.z
		if dt == nil then
			-- What is out on a worker was cast from where the camera used to
			-- be, and blending it in afterwards would undo part of the snap
			drop_slices()
			for sweep = 1, SNAP_SWEEPS do
				begin_sweep()
				if take_volumes(origin) then
					aim_args(1, CELL_COUNT)
					keep_slice(1, CELL_COUNT,
							buildat.cast_voxel_rays(ray_args))
				else
					sweep_all_open()
				end
				blend_cells(1, CELL_COUNT, sweep == 1 and 1.0 or 1.0 / sweep)
			end
			begin_sweep()
			push()
			return
		end
		-- Each frame's cells are handed to the shader as their own rays land,
		-- rather than a whole sweep at a time: waiting for the sweep steps
		-- every reflection in the scene together, six frames apart.
		collect_slices(SKY_VIS_BLEND)
		while #in_flight < MAX_IN_FLIGHT do
			if sweep_next == 1 and not take_volumes(origin) then
				sweep_all_open()
				blend_cells(1, CELL_COUNT, SKY_VIS_BLEND)
				begin_sweep()
				break
			end
			local first = sweep_next
			local count = math.min(CELLS_PER_UPDATE, CELL_COUNT - sweep_next + 1)
			submit_slice(first, count)
			sweep_next = sweep_next + count
			if sweep_next > CELL_COUNT then
				begin_sweep()
			end
		end
		push()
	end

	-- What the shader is being told, for the counters and the self-check
	function self:value_of(cell)
		return sky_vis[cell]
	end

	function self:has_volumes()
		return have_volumes
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
