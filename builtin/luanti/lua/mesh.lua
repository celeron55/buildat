-- Buildat: builtin/luanti/lua/mesh.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A node whose drawtype is "mesh" names a model file, and what the voxel
-- mesher wants of one is the quads it is made of -- the same thing a nodebox
-- is turned into, in the same -0.5...0.5 cube. So a mesh node is read here,
-- once, while the registry is built, and from there it is a shape like any
-- other: a chunk of lanterns costs what a chunk of cubes costs.
--
-- The readers beside this file are objmesh.lua and b3dmesh.lua, copied out
-- of extensions/luanti_client where they were written for this same mesher.
-- Between them they cover twenty of devtest's thirty mesh references; the
-- rest are .x, .gltf and .glb, and a node that names one of those keeps the
-- cube it had.

-- core.__mesh_quads(name, data, scale) -> a flat array of numbers, and how
-- many faces were neither triangles nor quads. Each quad is 21 numbers: the
-- tile it wears, then its four corners and their four texture coordinates,
-- which is what interface::VoxelQuad holds.
function core.__mesh_quads(name, data, scale)
	local lower = tostring(name):lower()
	local read = nil
	if lower:match("%.obj$") then
		read = core.__objmesh.parse
	elseif lower:match("%.b3d$") then
		read = core.__b3dmesh.parse
	end
	if read == nil then
		return nil, 0
	end
	local ok, quads, groups, skipped = pcall(read, data)
	if not ok then
		core.log("warning", "mesh " .. tostring(name) .. ": " ..
				tostring(quads))
		return nil, 0
	end
	if type(quads) ~= "table" or #quads == 0 then
		return nil, 0
	end
	core.__objmesh.scale(quads, scale)
	local out = {}
	local n = 0
	for i = 1, #quads do
		local q = quads[i]
		-- A material of the mesh wears the tile of the same number, which is
		-- how Luanti puts a node's tiles on one. Tiles are counted from zero
		-- here and from one there.
		n = n + 1
		out[n] = math.min(q.group or 1, 6) - 1
		for j = 1, 12 do
			n = n + 1
			out[n] = q.p[j]
		end
		for j = 1, 8 do
			n = n + 1
			out[n] = q.uv[j]
		end
	end
	return out, skipped or 0
end

-- vim: set noet ts=4 sw=4:
