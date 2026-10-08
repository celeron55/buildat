-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- **A node's picture in an inventory, by its shape** ([VL_INV_PARITY]):
-- a stair, a slab or a hollow log as Luanti's inventory draws it, not as
-- its flat tile. Luanti renders the node with a camera; this projects the
-- faces a viewer off the +X +Z corner, above, sees onto the inventory
-- cube's canvas (nine units; createInventoryCubeImage()'s geometry), each
-- face a shear of the part of its tile it covers, back to front. A
-- projection like that keeps a parallelogram a parallelogram, so a face
-- whose texture is a rectangle of its tile is exact.
--
-- Shared by luanti_client and the module's client (serve_shared_lua).
--
-- simplified: painter's order by each face's centre, not a depth buffer,
-- and a mesh face whose texture is not a rectangle of the tile is left out:
-- right for boxes and the box-like meshes games use for items; a curved
-- mesh comes out with holes. A render of the node into a texture is the
-- upgrade.
local M = {}

-- The faces of boxes {x0, y0, z0, x1, y1, z1} (nodes; a full node is
-- -0.5..0.5) that the viewer sees, as quads {p = {12}, uv = {8}, tile}: the
-- top (tile 1), +X (3) and +Z (5), the texture the part of the tile the
-- face's extent covers, as Luanti maps a node box's faces
function M.box_quads(boxes)
	local quads = {}
	for _, b in ipairs(boxes) do
		local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]
		quads[#quads + 1] = {tile = 1,
			p = {x0, y1, z0, x1, y1, z0, x1, y1, z1, x0, y1, z1},
			uv = {x0 + .5, z0 + .5, x1 + .5, z0 + .5, x1 + .5, z1 + .5,
				x0 + .5, z1 + .5}}
		quads[#quads + 1] = {tile = 5,
			p = {x0, y1, z1, x1, y1, z1, x1, y0, z1, x0, y0, z1},
			uv = {x0 + .5, .5 - y1, x1 + .5, .5 - y1, x1 + .5, .5 - y0,
				x0 + .5, .5 - y0}}
		quads[#quads + 1] = {tile = 3,
			p = {x1, y1, z1, x1, y1, z0, x1, y0, z0, x1, y0, z1},
			uv = {.5 - z1, .5 - y1, .5 - z0, .5 - y1, .5 - z0, .5 - y0,
				.5 - z1, .5 - y0}}
	end
	return quads
end

-- The compose ops for quads on a canvas of nine `unit`s, or nil when a
-- face's texture is not there: resource(tile, shade) -> a resource name,
-- shade nil for a face up, "#d5d5d5" for one along Z and "#aaaaaa" along X
-- (Luanti's 214/256 and 171/256)
function M.ops(quads, unit, resource)
	local k = unit
	local function at(x, y, z)
		return 4.5 * k + (x + .5) * 4 * k - (z + .5) * 4 * k,
				(x + .5) * 2 * k + (z + .5) * 2 * k + (.5 - y) * 5 * k
	end
	local faces = {}
	for _, q in ipairs(quads) do
		local p, uv = q.p, q.uv
		local u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge
		for c = 0, 3 do
			u0 = math.min(u0, uv[c * 2 + 1])
			u1 = math.max(u1, uv[c * 2 + 1])
			v0 = math.min(v0, uv[c * 2 + 2])
			v1 = math.max(v1, uv[c * 2 + 2])
		end
		-- The corners the texture's top left, top right and bottom left are
		-- at
		local function corner(u, v)
			for c = 0, 3 do
				if math.abs(uv[c * 2 + 1] - u) < 1e-4 and
						math.abs(uv[c * 2 + 2] - v) < 1e-4 then
					return c
				end
			end
		end
		local a, cu, cv = corner(u0, v0), corner(u1, v0), corner(u0, v1)
		if a and cu and cv and u1 - u0 > 1e-4 and v1 - v0 > 1e-4 then
			local function pt(c)
				return p[c * 3 + 1], p[c * 3 + 2], p[c * 3 + 3]
			end
			local ax, ay, az = pt(a)
			local ux, uy, uz = pt(cu)
			local vx, vy, vz = pt(cv)
			-- The axis the face is across decides its shade
			local e1 = {ux - ax, uy - ay, uz - az}
			local e2 = {vx - ax, vy - ay, vz - az}
			local n = {math.abs(e1[2] * e2[3] - e1[3] * e2[2]),
				math.abs(e1[3] * e2[1] - e1[1] * e2[3]),
				math.abs(e1[1] * e2[2] - e1[2] * e2[1])}
			local shade = n[1] >= n[2] and n[1] >= n[3] and "#aaaaaa" or
					n[3] >= n[2] and "#d5d5d5" or nil
			local cx = (p[1] + p[4] + p[7] + p[10]) / 4
			local cy = (p[2] + p[5] + p[8] + p[11]) / 4
			local cz = (p[3] + p[6] + p[9] + p[12]) / 4
			faces[#faces + 1] = {depth = cx + cy + cz, q = q, shade = shade,
				a = {at(ax, ay, az)}, u = {at(ux, uy, uz)},
				v = {at(vx, vy, vz)}, part = {u0, v0, u1, v1}}
		end
	end
	table.sort(faces, function(f, g) return f.depth < g.depth end)
	local ops = {}
	for _, f in ipairs(faces) do
		local src = resource(f.q.tile or 1, f.shade)
		if not src then
			return nil
		end
		local ax, ay = math.floor(f.a[1] + .5), math.floor(f.a[2] + .5)
		ops[#ops + 1] = {op = "shear", src = src, at = {ax, ay},
			u = {math.floor(f.u[1] + .5) - ax, math.floor(f.u[2] + .5) - ay},
			v = {math.floor(f.v[1] + .5) - ax, math.floor(f.v[2] + .5) - ay},
			part = f.part}
	end
	return ops
end

-- The check: a full box is the three faces of the inventory cube, at the
-- places createInventoryCubeImage() puts them
do
	local ops = M.ops(M.box_quads({{-.5, -.5, -.5, .5, .5, .5}}), 8,
			function(tile, shade) return tile .. (shade or "") end)
	local want = {
		["1"] = {36, 0, 32, 16, -32, 16},
		["5#d5d5d5"] = {4, 16, 32, 16, 0, 40},
		["3#aaaaaa"] = {36, 32, 32, -16, 0, 40},
	}
	assert(#ops == 3, "item_shape: a cube is three faces")
	for _, o in ipairs(ops) do
		local w = want[o.src]
		assert(w and o.at[1] == w[1] and o.at[2] == w[2] and o.u[1] == w[3]
				and o.u[2] == w[4] and o.v[1] == w[5] and o.v[2] == w[6],
				"item_shape: the cube's face " .. o.src)
	end
end

return M
