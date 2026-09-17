# [PATH_TRACE_REF] Cycles render of dumps from buildat.dump_meshes().
# The .obj is Urho/Luanti Y-up world space, with
#   # camera_pos x y z
#   # camera_dir x y z
# at the top (camera already at the eyes). FOV 72 vertical, Nishita at 13:00.
# .obj.gz is accepted: Blender's importer does not read gzip, so this
# decompressed to a temp file. simplified: untextured, 32 samples.

import gzip
import math
import os
import shutil
import sys
import tempfile

import bpy

OUT = os.environ.get("BUILDAT_PATHTRACE_OUT",
		os.path.abspath("local/reference_shots/pathtrace"))
FOV = 72.0
SAMPLES = 32
RES = (1280, 720)


def parse_camera(path):
	pos, dire = None, None
	with open(path) as f:
		for i, line in enumerate(f):
			if i > 20:
				break
			if line.startswith("# camera_pos "):
				pos = tuple(float(x) for x in line.split()[2:5])
			elif line.startswith("# camera_dir "):
				dire = tuple(float(x) for x in line.split()[2:5])
	return pos, dire


def y_up_to_blender(x, y, z):
	# obj_import(forward_axis="Z", up_axis="Y"): file Y → Blender Z (up),
	# file Z → Blender -Y (forward is -Y).
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
	# GetWorldDirection is the look; if the picture is behind the world,
	# flip this sign. Tried +dir first.
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
	mat = None
	for name in picked:
		obj_path = os.path.join(OUT, name)
		work = obj_path
		tmp = None
		if name.endswith(".gz"):
			tmp = tempfile.NamedTemporaryFile(suffix=".obj", delete=False)
			tmp.close()
			with gzip.open(obj_path, "rb") as src, open(tmp.name, "wb") as dst:
				shutil.copyfileobj(src, dst)
			work = tmp.name
		pos, dire = parse_camera(work)
		if not pos or not dire:
			print("no camera header in", name, file=sys.stderr)
			sys.exit(1)
		clear_scene()
		setup_world()
		bpy.ops.wm.obj_import(filepath=work, forward_axis="Z", up_axis="Y",
				clamp_size=0, use_split_objects=False,
				use_split_groups=False)
		if tmp:
			os.unlink(tmp.name)
		mat = gray_material()
		for ob in bpy.context.scene.objects:
			if ob.type == "MESH":
				if ob.data.materials:
					ob.data.materials[0] = mat
				else:
					ob.data.materials.append(mat)
		scene.camera = add_camera(pos, dire)
		stem = name[:-7] if name.endswith(".obj.gz") else name[:-4]
		png = stem + ".png"
		scene.render.filepath = os.path.join(OUT, png)
		print("render", png)
		bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
	main()
