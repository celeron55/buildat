# [PATH_TRACE_REF] Cycles render of dumps from buildat.dump_meshes().
# The .obj is Urho/Luanti Y-up world space, with
#   # camera_pos x y z
#   # camera_dir x y z
# at the top (camera already at the eyes). FOV 72 vertical, Nishita at 13:00.
# Blender's OBJ importer is not used: it places verts by forward_axis/up_axis
# while the camera is placed here, and two transforms that disagree put the
# camera outside the world. Parsed here instead, so there is one conversion.
# simplified: untextured, 32 samples, sun elevation fixed at 13:00's.

import gzip
import math
import os
import sys

import bpy

OUT = os.environ.get("BUILDAT_PATHTRACE_OUT",
		os.path.abspath("local/reference_shots/pathtrace"))
FOV = 72.0
SAMPLES = 32
RES = (1280, 720)


def open_dump(path):
	if path.endswith(".gz"):
		return gzip.open(path, "rt")
	return open(path)


def load_dump(path):
	"""One conversion: file Y-up → Blender (x, -z, y). Camera uses the same."""
	pos, dire = None, None
	verts = []
	faces = []
	with open_dump(path) as f:
		for line in f:
			if line.startswith("# camera_pos "):
				pos = tuple(float(x) for x in line.split()[2:5])
			elif line.startswith("# camera_dir "):
				dire = tuple(float(x) for x in line.split()[2:5])
			elif line.startswith("v "):
				x, y, z = (float(x) for x in line.split()[1:4])
				verts.append(y_up_to_blender(x, y, z))
			elif line.startswith("f "):
				idx = []
				for tok in line.split()[1:]:
					idx.append(int(tok.split("/", 1)[0]) - 1)
				if len(idx) >= 3:
					faces.append(idx[:3])
	return pos, dire, verts, faces


def y_up_to_blender(x, y, z):
	# File Y → Blender Z (up), file Z → Blender -Y (forward is -Y).
	# The only place either verts or the camera change hands.
	return (x, -z, y)


def clear_scene():
	bpy.ops.object.select_all(action="SELECT")
	bpy.ops.object.delete()
	for block in list(bpy.data.meshes):
		bpy.data.meshes.remove(block)
	bpy.ops.outliner.orphans_purge(do_local_ids=True, do_linked_ids=True,
			do_recursive=True)


def setup_world():
	world = bpy.data.worlds["World"]
	world.use_nodes = True
	nt = world.node_tree
	nt.nodes.clear()
	out = nt.nodes.new("ShaderNodeOutputWorld")
	bg = nt.nodes.new("ShaderNodeBackground")
	sky = nt.nodes.new("ShaderNodeTexSky")
	sky.sky_type = "MULTIPLE_SCATTERING"
	sky.sun_elevation = math.radians(75)
	sky.sun_rotation = math.radians(15)
	nt.links.new(sky.outputs["Color"], bg.inputs["Color"])
	nt.links.new(bg.outputs["Background"], out.inputs["Surface"])
	bg.inputs["Strength"].default_value = 1.0


def add_camera(pos, dire):
	from mathutils import Vector, Matrix
	loc = Vector(y_up_to_blender(*pos))
	# GetWorldDirection is the look, unflipped: checked against viewpoint 1
	# and the cave trio, which match the module's own screenshots.
	forward = Vector(y_up_to_blender(*dire))
	if forward.length < 1e-8:
		forward = Vector((0, 1, 0))
	else:
		forward.normalize()
	world_up = Vector((0, 0, 1))
	right = world_up.cross(forward)
	if right.length < 1e-6:
		right = Vector((1, 0, 0))
	else:
		right.normalize()
	up = forward.cross(right)
	# Camera looks along local -Z, local Y is up, local X is right.
	rot = Matrix((right, up, -forward)).transposed().to_4x4()
	rot.translation = loc
	c = bpy.data.cameras.new("cam")
	c.lens_unit = "FOV"
	c.sensor_fit = "VERTICAL"
	c.angle = math.radians(FOV)
	c.clip_start = 0.05
	c.clip_end = 5000.0
	ob = bpy.data.objects.new("cam", c)
	ob.matrix_world = rot
	bpy.context.scene.collection.objects.link(ob)
	return ob


def gray_material():
	mat = bpy.data.materials.new("voxel")
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	if bsdf:
		bsdf.inputs["Base Color"].default_value = (0.55, 0.55, 0.55, 1)
		bsdf.inputs["Roughness"].default_value = 0.7
	mat.use_backface_culling = False
	return mat


def main():
	scene = bpy.context.scene
	scene.render.engine = "CYCLES"
	scene.cycles.samples = SAMPLES
	scene.cycles.device = "CPU"
	scene.render.resolution_x, scene.render.resolution_y = RES
	scene.render.image_settings.file_format = "PNG"

	objs = sorted(n for n in os.listdir(OUT)
			if "_vp" in n and (n.endswith(".obj") or n.endswith(".obj.gz")))
	# Prefer .gz when both exist
	seen = set()
	picked = []
	for n in objs:
		stem = n[:-7] if n.endswith(".obj.gz") else n[:-4]
		if stem in seen:
			continue
		gz = stem + ".obj.gz"
		raw = stem + ".obj"
		if gz in objs:
			picked.append(gz)
		else:
			picked.append(raw)
		seen.add(stem)
	if not picked:
		print("no dumps in", OUT, file=sys.stderr)
		sys.exit(1)
	for name in picked:
		obj_path = os.path.join(OUT, name)
		print("load", name)
		pos, dire, verts, faces = load_dump(obj_path)
		if not pos or not dire:
			print("no camera header in", name, file=sys.stderr)
			sys.exit(1)
		clear_scene()
		setup_world()
		mesh = bpy.data.meshes.new("world")
		mesh.from_pydata(verts, [], faces)
		mesh.update()
		ob = bpy.data.objects.new("world", mesh)
		scene.collection.objects.link(ob)
		mat = gray_material()
		ob.data.materials.append(mat)
		scene.camera = add_camera(pos, dire)
		stem = name[:-7] if name.endswith(".obj.gz") else name[:-4]
		# cycles_vp6_1300_none.png: the dump's stem without the seed, so the
		# render sits beside its .obj.gz without sharing a name with it.
		png = "cycles_" + stem.split("_", 1)[1] + ".png"
		scene.render.filepath = os.path.join(OUT, png)
		print("render", png)
		bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
	main()
