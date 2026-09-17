# [PATH_TRACE_REF] Cycles render of dumps from buildat.dump_meshes().
# The .obj is Urho/Luanti Y-up world space, with
#   # camera_pos x y z
#   # camera_dir x y z
# at the top (camera already at the eyes). FOV 72 vertical, Nishita at 13:00.
# Blender's OBJ importer is not used: it places verts by forward_axis/up_axis
# while the camera is placed here, and two transforms that disagree put the
# camera outside the world. Parsed here instead, so there is one conversion.
# simplified: 32 samples, sun elevation fixed at 13:00's, exposure a
# constant rather than metered.

import gzip
import math
import os
import sys

import bpy

OUT = os.environ.get("BUILDAT_PATHTRACE_OUT",
		os.path.abspath("local/reference_shots/pathtrace"))
FOV = 72.0
SAMPLES = int(os.environ.get("SAMPLES", "32"))
RES = (1280, 720)
# The Nishita sky is in physical units and a noon sun blows an 8-bit frame
# to white at exposure 0; -7 puts a sunlit grey top face near 0.8 and its
# shadow near 0.15. BUILDAT_PATHTRACE_EXPOSURE moves it; the set is
# read as ratios, so the number only has to keep both ends of a picture
# off the clip.
EXPOSURE = float(os.environ.get("BUILDAT_PATHTRACE_EXPOSURE", "-7"))
# ONLY=vp1 renders the one dump whose stem contains it
ONLY = os.environ.get("ONLY", "")


def open_dump(path):
	if path.endswith(".gz"):
		return gzip.open(path, "rt")
	return open(path)


def load_dump(path):
	"""One conversion: file Y-up → Blender (x, -z, y). Camera uses the same.
	Verts carry the tint as an OBJ vertex colour, faces carry a usemtl that
	names the albedo PNG beside the dump; both come back per face."""
	pos, dire = None, None
	verts = []
	tints = []
	uvs = []
	faces = []
	mats = []
	mat = ""
	with open_dump(path) as f:
		for line in f:
			if line.startswith("v "):
				t = line.split()
				verts.append(y_up_to_blender(float(t[1]), float(t[2]),
						float(t[3])))
				tints.append((float(t[4]), float(t[5]), float(t[6]), 1.0)
						if len(t) >= 7 else (1.0, 1.0, 1.0, 1.0))
			elif line.startswith("vt "):
				t = line.split()
				# Urho's v runs down from the top; Blender's up from the bottom
				uvs.append((float(t[1]), 1.0 - float(t[2])))
			elif line.startswith("f "):
				idx = []
				for tok in line.split()[1:]:
					idx.append(int(tok.split("/", 1)[0]) - 1)
				if len(idx) >= 3:
					faces.append(idx[:3])
					mats.append(mat)
			elif line.startswith("usemtl "):
				t = line.split(None, 1)
				mat = t[1].strip() if len(t) > 1 else ""
			elif line.startswith("# camera_pos "):
				pos = tuple(float(x) for x in line.split()[2:5])
			elif line.startswith("# camera_dir "):
				dire = tuple(float(x) for x in line.split()[2:5])
	return pos, dire, verts, tints, uvs, faces, mats


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


def textured_material(name, png):
	"""The atlas on a Principled BSDF, nearest-filtered as the client draws
	it, multiplied by the tint the mesher packed; the atlas's alpha cuts the
	leaf and plant cards out."""
	mat = bpy.data.materials.new(name)
	mat.use_nodes = True
	nt = mat.node_tree
	bsdf = nt.nodes.get("Principled BSDF")
	bsdf.inputs["Roughness"].default_value = 0.9
	bsdf.inputs["Specular IOR Level"].default_value = 0.0
	if png and os.path.isfile(png):
		tex = nt.nodes.new("ShaderNodeTexImage")
		tex.image = bpy.data.images.load(png)
		tex.image.colorspace_settings.name = "sRGB"
		tex.interpolation = "Closest"
		tint = nt.nodes.new("ShaderNodeVertexColor")
		tint.layer_name = "tint"
		mul = nt.nodes.new("ShaderNodeMix")
		mul.data_type = "RGBA"
		mul.blend_type = "MULTIPLY"
		mul.inputs["Factor"].default_value = 1.0
		nt.links.new(tex.outputs["Color"], mul.inputs[6])
		nt.links.new(tint.outputs["Color"], mul.inputs[7])
		nt.links.new(mul.outputs[2], bsdf.inputs["Base Color"])
		nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
	else:
		bsdf.inputs["Base Color"].default_value = (0.55, 0.55, 0.55, 1)
	mat.use_backface_culling = False
	return mat


def build_world(scene, verts, tints, uvs, faces, mats, tex_dir):
	mesh = bpy.data.meshes.new("world")
	mesh.from_pydata(verts, [], faces)
	uv = mesh.uv_layers.new(name="atlas")
	col = mesh.color_attributes.new(name="tint", type="FLOAT_COLOR",
			domain="POINT")
	# One material slot per texture the dump named, in the order met
	slot_of = {}
	for i, poly in enumerate(mesh.polygons):
		m = mats[i]
		if m not in slot_of:
			slot_of[m] = len(mesh.materials)
			mesh.materials.append(textured_material(m or "untextured",
					os.path.join(tex_dir, m) if m else None))
		poly.material_index = slot_of[m]
		for li in poly.loop_indices:
			vi = mesh.loops[li].vertex_index
			uv.data[li].uv = uvs[vi] if vi < len(uvs) else (0.0, 0.0)
	for vi in range(len(verts)):
		col.data[vi].color = tints[vi]
	mesh.update()
	ob = bpy.data.objects.new("world", mesh)
	scene.collection.objects.link(ob)
	return ob


def main():
	scene = bpy.context.scene
	scene.render.engine = "CYCLES"
	scene.cycles.samples = SAMPLES
	scene.cycles.device = "CPU"
	scene.render.resolution_x, scene.render.resolution_y = RES
	scene.view_settings.exposure = EXPOSURE
	# Standard, not Blender 5's AgX: a tone curve moves every ratio the
	# probes read, and under Standard two albedos in the same light come
	# out in the ratio of the albedos. See [PATH_TRACE_TEX].
	scene.view_settings.view_transform = "Standard"
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
		if ONLY and ONLY not in name:
			continue
		obj_path = os.path.join(OUT, name)
		print("load", name)
		pos, dire, verts, tints, uvs, faces, mats = load_dump(obj_path)
		if not pos or not dire:
			print("no camera header in", name, file=sys.stderr)
			sys.exit(1)
		clear_scene()
		setup_world()
		stem = name[:-7] if name.endswith(".obj.gz") else name[:-4]
		# The shooter renamed the textures after the dump's stem
		# (<stem>_texN.png); the usemtl lines still carry the dump's own name
		mats = [stem + m[m.rfind("_tex"):] if m else "" for m in mats]
		build_world(scene, verts, tints, uvs, faces, mats, OUT)
		scene.camera = add_camera(pos, dire)
		# cycles_vp6_1300_none.png: the dump's stem without the seed, so the
		# render sits beside its .obj.gz without sharing a name with it.
		png = "cycles_" + stem.split("_", 1)[1] + ".png"
		scene.render.filepath = os.path.join(OUT, png)
		print("render", png)
		bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
	main()
