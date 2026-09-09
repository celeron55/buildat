-- Buildat: extension/luanti_client/shapes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's node shapes, as the quads a voxel definition takes.
--
-- Most of a game's node types are not cubes: stairs, slabs, fences, doors,
-- panes, plants, rails, torches. buildat's voxel registry takes a list of
-- quads per voxel and the mesher copies them into the chunk's mesh, so what
-- is needed here is the quads -- and what a node's shape is is Luanti's
-- business, which is why this file exists rather than the engine knowing
-- about node boxes.
--
-- A quad's corners are in the voxel's own cube, which runs -0.5...0.5, wound
-- so that the right-handed cross product of its first two edges points out of
-- the shape; the mesher takes that as the normal too. The corners are given
-- in the order top left, top right, bottom right, bottom left as the face is
-- seen from outside, and the texture coordinates follow: 0,0 is the top left
-- of the tile.

local M = {}

-- Where a box's face takes its piece of the tile from, which is the part of
-- the node the face covers. Luanti does the same, in
-- MapblockMeshGenerator::getNodeBoxTextureCoords; a slab's side shows the
-- bottom half of its texture rather than the whole of it squashed.
--
-- box is {x0, y0, z0, x1, y1, z1} in node units. What comes out is appended
-- to out.
function M.box_quads(box, out)
	local x0, y0, z0 = box[1], box[2], box[3]
	local x1, y1, z1 = box[4], box[5], box[6]
	-- The box's corners as fractions of the node
	local tx1, ty1, tz1 = x0 + 0.5, y0 + 0.5, z0 + 0.5
	local tx2, ty2, tz2 = x1 + 0.5, y1 + 0.5, z1 + 0.5

	local function quad(tile, p, uv)
		out[#out + 1] = {tile = tile, p = p, uv = uv}
	end

	-- +Y, across in +X and down the texture in -Z
	quad(1, {x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0},
			{tx1, 1 - tz2, tx2, 1 - tz2, tx2, 1 - tz1, tx1, 1 - tz1})
	-- -Y, across in +X and down in +Z
	quad(2, {x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1},
			{tx1, tz1, tx2, tz1, tx2, tz2, tx1, tz2})
	-- +X, across in +Z and down in -Y
	quad(3, {x1, y1, z0, x1, y1, z1, x1, y0, z1, x1, y0, z0},
			{tz1, 1 - ty2, tz2, 1 - ty2, tz2, 1 - ty1, tz1, 1 - ty1})
	-- -X, across in -Z
	quad(4, {x0, y1, z1, x0, y1, z0, x0, y0, z0, x0, y0, z1},
			{tz1, 1 - ty2, tz2, 1 - ty2, tz2, 1 - ty1, tz1, 1 - ty1})
	-- +Z, across in -X
	quad(5, {x1, y1, z1, x0, y1, z1, x0, y0, z1, x1, y0, z1},
			{1 - tx2, 1 - ty2, 1 - tx1, 1 - ty2, 1 - tx1, 1 - ty1,
			1 - tx2, 1 - ty1})
	-- -Z, across in +X
	quad(6, {x0, y1, z0, x1, y1, z0, x1, y0, z0, x0, y0, z0},
			{tx1, 1 - ty2, tx2, 1 - ty2, tx2, 1 - ty1, tx1, 1 - ty1})
	return out
end

-- Two quads across the node's diagonals, which is what a plant is: a flower,
-- a sapling, a bush, and near enough a torch or a flame. scale is the node's
-- visual_scale, so a plant shorter than a node stands on its floor.
function M.plant_quads(scale, out)
	out = out or {}
	local h = -0.5 + (scale or 1) * 1.0
	if h > 0.5 then
		h = 0.5
	end
	local d = 0.5
	-- Along +X+Z, and along +X-Z
	out[#out + 1] = {tile = 1,
			p = {-d, h, -d, d, h, d, d, -0.5, d, -d, -0.5, -d},
			uv = {0, 0, 1, 0, 1, 1, 0, 1}}
	out[#out + 1] = {tile = 1,
			p = {-d, h, d, d, h, -d, d, -0.5, -d, -d, -0.5, d},
			uv = {0, 0, 1, 0, 1, 1, 0, 1}}
	return out
end

-- One quad just off the floor, which is what a rail or anything else painted
-- on the ground is
function M.flat_quads(out)
	out = out or {}
	local y = -0.5 + 1.0 / 16
	local d = 0.5
	out[#out + 1] = {tile = 1,
			p = {-d, y, d, d, y, d, d, y, -d, -d, y, -d},
			uv = {0, 0, 1, 0, 1, 1, 0, 1}}
	return out
end

-- The quads for a node, or nil for one that is a cube and wants none.
--
-- drawtype and node_box are what nodedef.lua read; DRAWTYPE in that file says
-- what the numbers are. What comes back is the quads and whether they want
-- drawing from both sides, which single quads do and boxes do not.
function M.for_node(def)
	local drawtype = def.drawtype
	if drawtype == 12 then -- NDT_NODEBOX
		local box = def.node_box
		if not box or #box.boxes == 0 then
			return nil
		end
		local out = {}
		for _, b in ipairs(box.boxes) do
			M.box_quads(b, out)
		end
		return out, false
	end
	if drawtype == 9 or drawtype == 17 then -- PLANTLIKE, PLANTLIKE_ROOTED
		return M.plant_quads(def.visual_scale), true
	end
	if drawtype == 7 or drawtype == 14 then -- TORCHLIKE, FIRELIKE
		return M.plant_quads(def.visual_scale), true
	end
	if drawtype == 8 then -- SIGNLIKE
		return M.plant_quads(def.visual_scale), true
	end
	if drawtype == 11 then -- RAILLIKE
		return M.flat_quads(), true
	end
	return nil
end

return M
-- vim: set noet ts=4 sw=4:
