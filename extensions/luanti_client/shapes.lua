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

-- Luanti's LIQUID_LEVEL_MASK and LIQUID_LEVEL_MAX: the level a flowing
-- liquid carries in its param2, 0...7.
local LIQUID_LEVELS = 8

-- How high a flowing liquid's surface stands in its own voxel, out of the
-- level in its param2 and the liquid's range. The arithmetic is Luanti's
-- getLiquidNeighborhood: a liquid whose range is shorter than eight spends
-- its levels on the top of the voxel and everything below them is the floor.
--
-- simplified: at the top level the surface is the top of the voxel, which is
-- what Luanti draws for a node with the same liquid above it or a source
-- beside it -- and a node at the top level is nearly always one of those. A
-- level below that gets a flat top, where Luanti slopes it by averaging the
-- levels of the four neighbours around each corner. So a slope reads as
-- steps; the upgrade path is the same per-neighbour data the connected node
-- boxes want.
function M.liquid_top(range, p2)
	local level = p2 % LIQUID_LEVELS
	if level >= LIQUID_LEVELS - 1 then
		return 0.5
	end
	range = math.min(math.max(range or LIQUID_LEVELS, 1), LIQUID_LEVELS)
	local floor_levels = LIQUID_LEVELS - range
	level = level <= floor_levels and 0 or level - floor_levels
	return -0.5 + (level + 0.5) / range
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

-- Which tile goes on which face, per facedir: FACEDIR_TILES[facedir + 1][i]
-- is the tile our face i is drawn with. Taken from Luanti's own
-- dir_to_tile[24][8] in mapblock_mesh.cpp, read at the six directions our
-- faces are in (+Y, -Y, +X, -X, +Z, -Z) -- which is the order Luanti keeps
-- its tiles in too, one-based here.
M.FACEDIR_TILES = {
	{1, 2, 3, 4, 5, 6},
	{1, 2, 5, 6, 4, 3},
	{1, 2, 4, 3, 6, 5},
	{1, 2, 6, 5, 3, 4},
	{6, 5, 3, 4, 1, 2},
	{3, 4, 5, 6, 1, 2},
	{5, 6, 4, 3, 1, 2},
	{4, 3, 6, 5, 1, 2},
	{5, 6, 3, 4, 2, 1},
	{4, 3, 5, 6, 2, 1},
	{6, 5, 4, 3, 2, 1},
	{3, 4, 6, 5, 2, 1},
	{4, 3, 1, 2, 5, 6},
	{6, 5, 1, 2, 4, 3},
	{3, 4, 1, 2, 6, 5},
	{5, 6, 1, 2, 3, 4},
	{3, 4, 2, 1, 5, 6},
	{5, 6, 2, 1, 4, 3},
	{4, 3, 2, 1, 6, 5},
	{6, 5, 2, 1, 3, 4},
	{2, 1, 4, 3, 5, 6},
	{2, 1, 6, 5, 4, 3},
	{2, 1, 3, 4, 6, 5},
	{2, 1, 5, 6, 3, 4},
}

-- How far the texture is turned inside each of those faces, in quarter turns
-- anticlockwise: FACEDIR_TILE_TURNS[facedir + 1][i] goes with
-- FACEDIR_TILES[facedir + 1][i]. The other half of Luanti's dir_to_tile
-- table, read in the same order; a turned cube's top and bottom are what
-- mostly want it, and an upside-down one has every face turned half way.
M.FACEDIR_TILE_TURNS = {
	{0, 0, 0, 0, 0, 0},
	{3, 1, 0, 0, 0, 0},
	{2, 2, 0, 0, 0, 0},
	{1, 3, 0, 0, 0, 0},
	{0, 2, 3, 1, 2, 0},
	{0, 2, 3, 1, 1, 1},
	{0, 2, 3, 1, 0, 2},
	{0, 2, 3, 1, 3, 3},
	{2, 0, 1, 3, 2, 0},
	{2, 0, 1, 3, 3, 3},
	{2, 0, 1, 3, 0, 2},
	{2, 0, 1, 3, 1, 1},
	{3, 3, 3, 3, 1, 3},
	{3, 3, 2, 0, 1, 3},
	{3, 3, 1, 1, 1, 3},
	{3, 3, 0, 2, 1, 3},
	{1, 1, 1, 1, 3, 1},
	{1, 1, 2, 0, 3, 1},
	{1, 1, 3, 3, 3, 1},
	{1, 1, 0, 2, 3, 1},
	{2, 2, 2, 2, 2, 2},
	{3, 1, 2, 2, 2, 2},
	{0, 0, 2, 2, 2, 2},
	{1, 3, 2, 2, 2, 2},
}

-- A wallmounted direction is a facedir too; Luanti's own
-- wallmounted_to_facedir[], one-based. 6 and 7 are the two spare states
-- (DWM_S1 and DWM_S2), which are the ceiling and the floor turned a quarter.
M.WALLMOUNTED_FACEDIR = {20, 0, 17, 15, 8, 6, 21, 1}

-- The facedir a param2 means, 0...23, or nil for a node that does not turn.
-- kind is "facedir", "4dir" or "wallmounted"; Luanti's MapNode::getFaceDir
-- with allow_wallmounted.
function M.facedir_of(kind, p2)
	if kind == "facedir" then
		return p2 % 32 % 24
	elseif kind == "4dir" then
		return p2 % 4
	elseif kind == "wallmounted" then
		return M.WALLMOUNTED_FACEDIR[p2 % 8 + 1]
	end
	return nil
end

-- Irrlicht's rotateXZBy and friends at right angles, which is all Luanti's
-- transformNodeBox turns a node box by: ia and ib are the two coordinates the
-- rotation turns into each other and quarters is how many times 90 degrees.
local SIN = {0, 1, 0, -1}
local COS = {1, 0, -1, 0}
local function turn(v, ia, ib, quarters)
	local i = quarters % 4 + 1
	local s, c = SIN[i], COS[i]
	local a, b = v[ia], v[ib]
	v[ia] = c * a - s * b
	v[ib] = s * a + c * b
end

-- The same at any angle, in degrees, for the one thing that wants an eighth
-- of a turn: a torch leaning off the floor or the ceiling.
local function turn_deg(v, ia, ib, deg)
	local r = math.rad(deg)
	local s, c = math.sin(r), math.cos(r)
	local a, b = v[ia], v[ib]
	v[ia] = c * a - s * b
	v[ib] = s * a + c * b
end

-- One point turned the way a facedir turns a node, in place.
--
-- The rotations and their order are Luanti's transformNodeBox: the low two
-- bits turn the node about Y and the rest stand it on another face. Every one
-- of them is a proper rotation, so a quad's winding -- and therefore the
-- normal the mesher takes from it -- comes out right without further care.
local function turn_point(v, facedir)
	local axisdir = math.floor(facedir / 4)
	if facedir % 4 ~= 0 then
		turn(v, 1, 3, -(facedir % 4))
	end
	if axisdir == 1 then -- z+
		turn(v, 2, 3, 1)
	elseif axisdir == 2 then -- z-
		turn(v, 2, 3, -1)
	elseif axisdir == 3 then -- x+
		turn(v, 1, 2, -1)
	elseif axisdir == 4 then -- x-
		turn(v, 1, 2, 1)
	elseif axisdir == 5 then
		turn(v, 1, 2, 2)
	end
end

-- A box turned by a facedir, in the voxel's own -0.5...0.5 coordinates.
-- Luanti's transformNodeBox does the same: the two corners are turned and
-- then put back the right way round, which is what keeps the box
-- axis-aligned.
function M.turn_box(box, facedir)
	if not facedir or facedir == 0 then
		return box
	end
	local a = {box[1], box[2], box[3]}
	local b = {box[4], box[5], box[6]}
	turn_point(a, facedir)
	turn_point(b, facedir)
	return {
		math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3]),
		math.max(a[1], b[1]), math.max(a[2], b[2]), math.max(a[3], b[3]),
	}
end

-- Quads turned by a facedir, 0...23. The tiles and the texture coordinates
-- come along as they are, so a tile follows the face it was on to wherever
-- that face ends up -- which is what Luanti does as well, by picking the tile
-- for a face from the direction turned back into the node's own frame.
--
-- simplified: Luanti computes a rotated box's texture coordinates from the
-- box after the turn, which also rotates the texture inside the face; here it
-- turns with the face. Same ceiling as FACEDIR_TILES has, and the same
-- upgrade path.
function M.turn_quads(quads, facedir)
	if not facedir or facedir == 0 then
		return quads
	end
	local out = {}
	for i, q in ipairs(quads) do
		local p = {}
		for c = 0, 3 do
			local v = {q.p[c * 3 + 1], q.p[c * 3 + 2], q.p[c * 3 + 3]}
			turn_point(v, facedir)
			p[c * 3 + 1], p[c * 3 + 2], p[c * 3 + 3] = v[1], v[2], v[3]
		end
		out[i] = {tile = q.tile, p = p, uv = q.uv}
	end
	return out
end

-- How far around Y a wallmounted side box is turned, in quarters, per
-- wallmounted direction; Luanti's transformNodeBox does the same by hand. The
-- box it starts from lies against -X, so that direction is the one left
-- alone.
local WALL_SIDE_TURN = {[2] = 2, [3] = 0, [4] = -1, [5] = 1}

-- The same for the single quad of a sign or a torch, which starts against +X
-- instead: drawSignlikeNode and drawTorchlikeNode.
local WALL_QUAD_TURN = {[2] = 0, [3] = 2, [4] = 1, [5] = -1}

-- The quads of a wallmounted node box for a wall direction, 0...7. It picks
-- one of the three boxes the definition carries -- the one for a ceiling, a
-- floor or a wall -- and turns it to the wall it is on.
--
-- simplified: Luanti's two spare directions (DWM_S1, DWM_S2) are a ceiling
-- and a floor turned a quarter; they get the side box here, which is what
-- Luanti's own node box code ends up doing too because their direction vector
-- is zero.
function M.wall_quads(wall_boxes, wall, out)
	out = out or {}
	if wall == 0 then
		return M.box_quads(wall_boxes.top, out)
	end
	if wall == 1 then
		return M.box_quads(wall_boxes.bottom, out)
	end
	local side = M.box_quads(wall_boxes.side, {})
	local turned = M.turn_quads_y(side, WALL_SIDE_TURN[wall] or 0)
	for _, q in ipairs(turned) do
		out[#out + 1] = q
	end
	return out
end

-- Quads turned about Y by whole quarters. facedir cannot say all of these
-- turns the way round Luanti's wallmounted boxes want them, so this is its
-- own thing.
function M.turn_quads_y(quads, quarters)
	if quarters % 4 == 0 then
		return quads
	end
	local out = {}
	for i, q in ipairs(quads) do
		local p = {}
		for c = 0, 3 do
			local v = {q.p[c * 3 + 1], q.p[c * 3 + 2], q.p[c * 3 + 3]}
			turn(v, 1, 3, quarters)
			p[c * 3 + 1], p[c * 3 + 2], p[c * 3 + 3] = v[1], v[2], v[3]
		end
		out[i] = {tile = q.tile, p = p, uv = q.uv}
	end
	return out
end

-- One quad standing against the wall it is mounted on, which is what a sign,
-- a ladder or a poster is: Luanti's drawSignlikeNode. wall is 0...7.
function M.sign_quads(scale, wall, out)
	out = out or {}
	local size = 0.5 * (scale or 1)
	local off = 0.5 - 1.0 / 16
	-- Against the +X wall, seen from -X
	local p = {off, size, size, off, size, -size, off, -size, -size,
			off, -size, size}
	for c = 0, 3 do
		local v = {p[c * 3 + 1], p[c * 3 + 2], p[c * 3 + 3]}
		if wall == 0 then -- ceiling
			turn(v, 1, 2, 1)
		elseif wall == 1 then -- floor
			turn(v, 1, 2, -1)
		else
			turn(v, 1, 3, WALL_QUAD_TURN[wall] or 0)
		end
		p[c * 3 + 1], p[c * 3 + 2], p[c * 3 + 3] = v[1], v[2], v[3]
	end
	out[#out + 1] = {tile = 1, p = p, uv = {0, 0, 1, 0, 1, 1, 0, 1}}
	return out
end

-- One quad hanging off the wall at an angle, which is what a torch is:
-- Luanti's drawTorchlikeNode. The tile is the definition's second for a
-- ceiling and its third for a wall, as Luanti picks them.
function M.torch_quads(scale, wall, out)
	out = out or {}
	local size = 0.5 * (scale or 1)
	local tile = 1
	local p = {-size, size, 0, size, size, 0, size, -size, 0, -size, -size, 0}
	for c = 0, 3 do
		local v = {p[c * 3 + 1], p[c * 3 + 2], p[c * 3 + 3]}
		if wall == 0 or wall == 6 then -- ceiling
			tile = 2
			v[2] = v[2] - size + 0.5
			turn_deg(v, 1, 3, wall == 0 and -45 or 45)
		elseif wall == 1 or wall == 7 then -- floor
			v[2] = v[2] + size - 0.5
			turn_deg(v, 1, 3, wall == 1 and 45 or -45)
		else
			tile = 3
			v[1] = v[1] - size + 0.5
			turn(v, 1, 3, WALL_QUAD_TURN[wall] or 0)
		end
		p[c * 3 + 1], p[c * 3 + 2], p[c * 3 + 3] = v[1], v[2], v[3]
	end
	out[#out + 1] = {tile = tile, p = p, uv = {0, 0, 1, 0, 1, 1, 0, 1}}
	return out
end

-- The quads for a node, or nil for one that is a cube and wants none.
--
-- drawtype and node_box are what nodedef.lua read; DRAWTYPE in that file says
-- what the numbers are. facedir, 0...23, is which way the node faces and wall,
-- 0...7, is the wallmounted direction its param2 says; both may be nil for a
-- node whose param2 is not known yet or does not turn it, which comes out as
-- the shape of a node standing on the floor facing +Z.
--
-- What comes back is the quads and whether they want drawing from both sides,
-- which single quads do and boxes do not.
--
-- mesh_quads is what objmesh.lua made of the model a "mesh" drawtype names,
-- when the file was there to read; without it such a node falls back to the
-- box the game says a ray hits.
--
-- liquid_top is how high a flowing liquid's surface stands, from
-- liquid_top(); without it a flowing liquid is a cube.
function M.for_node(def, facedir, wall, mesh_quads, liquid_top)
	local drawtype = def.drawtype
	if drawtype == 12 then -- NDT_NODEBOX
		local box = def.node_box
		if not box then
			return nil
		end
		if box.wall then
			return M.wall_quads(box.wall, wall or 1), false
		end
		if #box.boxes == 0 then
			return nil
		end
		local out = {}
		for _, b in ipairs(box.boxes) do
			M.box_quads(b, out)
		end
		return M.turn_quads(out, facedir), false
	end
	if drawtype == 3 and liquid_top then -- NDT_FLOWINGLIQUID
		-- A box with a lowered top. box_quads takes the side textures from
		-- the part of the tile the box covers, which is what Luanti's own
		-- liquid sides do: the surface cuts the texture, it does not squash
		-- it. Not doubled: a blended quad drawn twice blends twice, which is
		-- what made a flowing liquid read as opaque next to a source. The
		-- alpha technique draws with culling off instead, so the surface is
		-- still there when the camera is under it.
		--
		-- A liquid at the top level has no lowered top and gets no shape at
		-- all -- see liquid_top() -- so it stays a cube whose faces against
		-- the next one are culled, which is what a waterfall or the middle of
		-- a lake is made of.
		return M.box_quads({-0.5, -0.5, -0.5, 0.5, liquid_top, 0.5}, {}), false
	end
	if drawtype == 9 or drawtype == 17 then -- PLANTLIKE, PLANTLIKE_ROOTED
		return M.plant_quads(def.visual_scale), true
	end
	if drawtype == 14 then -- FIRELIKE
		return M.plant_quads(def.visual_scale), true
	end
	if drawtype == 7 then -- TORCHLIKE
		return M.torch_quads(def.visual_scale, wall or 1), true
	end
	if drawtype == 8 then -- SIGNLIKE
		return M.sign_quads(def.visual_scale, wall or 1), true
	end
	if drawtype == 11 then -- RAILLIKE
		return M.flat_quads(), true
	end
	if drawtype == 16 then -- NDT_MESH
		-- The model itself, when it is one of the formats objmesh.lua reads.
		-- Drawn from both sides: a node mesh is often a shell -- a sign
		-- face, a flowerpot -- whose inside is meant to be seen, and Luanti
		-- draws them that way.
		if mesh_quads and #mesh_quads > 0 then
			return M.turn_quads(mesh_quads, facedir), true
		end
		-- simplified: a mesh in a format this does not read is drawn as the
		-- box the game says a ray hits, which is about the size and shape of
		-- the mesh. A torch comes out as a thin post rather than as a whole
		-- cube, and a cube is what it would be otherwise -- with the mesh's
		-- own texture on it, holes and all, so the wall behind it would show
		-- through the hole in its own face. The upgrade path is .b3d, which
		-- is what the chests and the shulkers are.
		local box = def.selection_box
		if not box then
			return nil
		end
		if box.wall then
			return M.wall_quads(box.wall, wall or 1), false
		end
		if #box.boxes == 0 then
			return nil
		end
		local out = {}
		for _, b in ipairs(box.boxes) do
			M.box_quads(b, out)
		end
		return M.turn_quads(out, facedir), false
	end
	return nil
end

return M
-- vim: set noet ts=4 sw=4:
