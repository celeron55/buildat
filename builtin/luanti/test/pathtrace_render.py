# [PATH_TRACE_REF] Cycles render of dumps from buildat.dump_meshes().
# The .obj is Urho/Luanti Y-up world space, with
#   # camera_pos x y z
#   # camera_dir x y z
# at the top (camera already at the eyes). FOV 72 vertical, Nishita at 13:00.
# Blender's OBJ importer is not used: it places verts by forward_axis/up_axis
# while the camera is placed here, and two transforms that disagree put the
# camera outside the world. Parsed here instead, so there is one conversion.
# simplified: 32 samples; the metering is
# a plain log-average, which a sun disc in frame drags (see [PT_EXPOSURE]).

import gzip
import math
from array import array
import os
import sys

import bpy

OUT = os.environ.get("BUILDAT_PATHTRACE_OUT",
		os.path.abspath("local/reference_shots/pathtrace"))
FOV = 72.0
SAMPLES = int(os.environ.get("SAMPLES", "32"))
RES = (1280, 720)
# [PT_EXPOSURE]: Blender writes linear radiance (EXR, exposure 0, no view
# transform) and the frame is metered here by the rule the client's
# AutoExposure.xml runs -- Urho3D's, out of Reinhard 2002: the key is the
# log-average luminance, clamped to LUM_RANGE, and the frame is scaled by
# MIDDLE_GREY / key. The three constants are the same on both sides; the
# client's adaptation rate is its own, a still having no time axis.
# The constants are in radiance, Nishita's units (a noon grass top is ~5,
# a cave floor ~0.02), and are the ones the client's AutoExposure.xml is
# given -- not Urho's defaults (0.01..1.0, 0.6), which are for a
# display-referred frame. Middle grey 0.18 is the photographic one; the
# lower bound of the range is what keeps a cave dark: a frame whose key
# meters below it is exposed as if it were at it.
LUM_WEIGHTS = (0.2126, 0.7152, 0.0722)
LUM_RANGE = (0.05, 100.0)
MIDDLE_GREY = 0.18
# ONLY=vp1 renders the one dump whose stem contains it
ONLY = os.environ.get("ONLY", "")


def open_dump(path):
	if path.endswith(".gz"):
		return gzip.open(path, "rt")
	return open(path)


def load_dump(path):
	"""One conversion: file Y-up -> Blender (x, -z, y). Camera uses the same.
	Flat array buffers rather than a Python object per vertex, which is
	what took ten gigabytes at RANGE=200 ([PATH_TRACE_RAM]). Nothing is
	culled: what is behind the camera casts the shadows and bounces the
	light in front of it (user). Every `o` block is one chunk batch whose
	faces are consecutive triples of its own verts (see l_dump_meshes), so
	no face list is kept either. Verts carry the tint as an OBJ vertex
	colour and a usemtl names the albedo PNG; both come back per block."""
	pos, dire = None, None
	co = array("f")      # x y z per vert, Blender space
	tint = array("f")    # r g b a per vert
	uv = array("f")      # u v per vert
	blocks = []          # (material, first vert, vert count)
	first = 0
	mat = ""

	def flush():
		nonlocal first
		n = len(co) // 3 - first
		if n > 0:
			blocks.append((mat, first, n))
		first = len(co) // 3

	with open_dump(path) as f:
		for line in f:
			c = line[0]
			if c == "v":
				t = line.split()
				if t[0] == "v":
					x, y, z = float(t[1]), float(t[2]), float(t[3])
					co.extend(y_up_to_blender(x, y, z))
					if len(t) >= 7:
						tint.extend((float(t[4]), float(t[5]), float(t[6]), 1.0))
					else:
						tint.extend((1.0, 1.0, 1.0, 1.0))
				elif t[0] == "vt":
					# Urho's v runs down from the top; Blender's up
					uv.extend((float(t[1]), 1.0 - float(t[2])))
			elif c == "o":
				flush()
			elif c == "u":
				t = line.split(None, 1)
				mat = t[1].strip() if len(t) > 1 else ""
			elif c == "#":
				if line.startswith("# camera_pos "):
					pos = tuple(float(x) for x in line.split()[2:5])
				elif line.startswith("# camera_dir "):
					dire = tuple(float(x) for x in line.split()[2:5])
			# "f" lines are implied: consecutive triples of a block's verts
	flush()
	return pos, dire, co, tint, uv, blocks


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


# Luanti's own sun path, out of luanti_sky.sun_direction() in the launcher
# (untilted, which is what a reference set is taken with): the sun rises
# at -X, crosses the zenith and sets at +X, in the world's XY... plane of
# file-space X and Y, which is Blender's XZ. The hour is the fixture's
# HOURS table -- "1300" is time_of_day 0.5417 -- so the reference's sun is
# where the client's is at the same picture.
HOURS = {"0545": 0.2396, "1000": 0.4167, "1300": 0.5417, "1500": 0.6250,
		"1830": 0.7708, "2030": 0.8542, "0200": 0.0833}


def sun_from_hour(hour):
	"""(elevation, rotation) for the Nishita sky, radians."""
	t = HOURS.get(hour, 0.5417)
	wn = 0.415 / 2
	if wn < t < 1 - wn:
		w = (t - wn) / (1 - wn * 2) * 0.5 + 0.25
	elif t < 0.5:
		w = t / wn * 0.25
	else:
		w = 1 - (1 - t) / wn * 0.25
	a = math.radians(w * 360 - 90)
	# File space: x = cos a, y = sin a (up), z = 0. Blender: (x, 0, y).
	x, up = math.cos(a), math.sin(a)
	el = math.asin(max(-1.0, min(1.0, up)))
	# Cycles: sun = (sin rot * cos el, cos rot * cos el, sin el), so a sun
	# along +X is rotation +90 degrees and along -X is -90
	rot = math.atan2(x, 0.0)
	return el, rot


def setup_world(hour):
	world = bpy.data.worlds["World"]
	world.use_nodes = True
	nt = world.node_tree
	nt.nodes.clear()
	out = nt.nodes.new("ShaderNodeOutputWorld")
	bg = nt.nodes.new("ShaderNodeBackground")
	sky = nt.nodes.new("ShaderNodeTexSky")
	sky.sky_type = "MULTIPLE_SCATTERING"
	el, rot = sun_from_hour(hour)
	sky.sun_elevation = el
	sky.sun_rotation = rot
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


def build_world(scene, co, tint, uv, blocks, tex_dir):
	"""The mesh out of the flat buffers, through foreach_set: no Python
	object per vertex or per loop."""
	nvert = len(co) // 3
	ntri = nvert // 3
	mesh = bpy.data.meshes.new("world")
	mesh.vertices.add(nvert)
	mesh.vertices.foreach_set("co", co)
	mesh.loops.add(nvert)
	mesh.loops.foreach_set("vertex_index", array("i", range(nvert)))
	mesh.polygons.add(ntri)
	mesh.polygons.foreach_set("loop_start", array("i", range(0, nvert, 3)))
	mesh.polygons.foreach_set("loop_total", array("i", [3]) * ntri)
	uvl = mesh.uv_layers.new(name="atlas")
	uvl.data.foreach_set("uv", uv)   # loop i is vert i
	col = mesh.color_attributes.new(name="tint", type="FLOAT_COLOR",
			domain="POINT")
	col.data.foreach_set("color", tint)
	# One material slot per texture the dump named, in the order met
	slot_of = {}
	midx = array("i", [0]) * ntri
	for m, first, n in blocks:
		if m not in slot_of:
			slot_of[m] = len(mesh.materials)
			mesh.materials.append(textured_material(m or "untextured",
					os.path.join(tex_dir, m) if m else None))
		s = slot_of[m]
		for i in range(first // 3, (first + n) // 3):
			midx[i] = s
	mesh.polygons.foreach_set("material_index", midx)
	mesh.update()
	mesh.validate()
	ob = bpy.data.objects.new("world", mesh)
	scene.collection.objects.link(ob)
	return ob


def expose(exr, png):
	"""The metered 16-bit PNG out of the linear EXR: log-average luminance
	as the key, clamped, MIDDLE_GREY / key as the scale. Written through
	Blender's own image writer, sRGB, so the PNG is display-referred the
	way the client's frame is after its exposure pass."""
	import numpy as np
	img = bpy.data.images.load(exr)
	w, h = img.size
	px = np.empty(w * h * 4, dtype=np.float32)
	img.pixels.foreach_get(px)
	rgb = px.reshape(-1, 4)[:, :3]
	lum = rgb @ np.array(LUM_WEIGHTS, dtype=np.float32)
	key = float(np.exp(np.mean(np.log(lum + 1e-5))))
	key = min(max(key, LUM_RANGE[0]), LUM_RANGE[1])
	scale = MIDDLE_GREY / key
	print("expose %s: key %.4f scale %.3f" % (os.path.basename(png), key, scale))
	px.reshape(-1, 4)[:, :3] *= scale
	# The alpha the leaf cards' cutout left behind composites the PNG over
	# black; the picture is opaque
	px.reshape(-1, 4)[:, 3] = 1.0
	img.pixels.foreach_set(px)
	img.filepath_raw = png
	img.file_format = "PNG"
	# 16-bit: a shaded face is a few counts of 255 and a hue ratio out of
	# those is noise
	scene = bpy.context.scene
	scene.render.image_settings.file_format = "PNG"
	scene.render.image_settings.color_depth = "16"
	img.save_render(png, scene=scene)
	scene.render.image_settings.file_format = "OPEN_EXR"
	scene.render.image_settings.color_depth = "32"
	bpy.data.images.remove(img)


def main():
	# Cycles and a buildat server do not fit in memory together; a render
	# waits for a shooter rather than running beside one.
	import subprocess
	if subprocess.run(["pgrep", "-x", "buildat_server"],
			capture_output=True).returncode == 0:
		print("a buildat_server is running; not rendering beside it",
				file=sys.stderr)
		sys.exit(1)
	scene = bpy.context.scene
	scene.render.engine = "CYCLES"
	scene.cycles.samples = SAMPLES
	scene.cycles.device = "CPU"
	# A shaded face at noon is lit by bounce alone, and at 32 samples its
	# colour is Monte Carlo noise (stone in shade read B/R 0.69); the
	# denoiser is what makes a ratio out of it.
	scene.cycles.use_denoising = True
	# A VoxeLibre canopy is drawn allfaces, six leaf cards a node with
	# interior faces, and a ray through the alpha-0 texels spends a
	# transparent bounce per card: at Cycles' default of eight it is
	# terminated black two nodes in, shadow rays the same, which was the
	# black inside every tree. Transparent hits are cheap. Diffuse bounces
	# up too, for a canopy lit from within. See [PATH_TRACE_TEX].
	scene.cycles.transparent_max_bounces = 128
	scene.cycles.max_bounces = 16
	scene.cycles.diffuse_bounces = 8
	scene.render.resolution_x, scene.render.resolution_y = RES
	scene.view_settings.exposure = 0.0
	# Standard, not Blender 5's AgX: a tone curve moves every ratio the
	# probes read; the EXR is written before either applies anyway.
	scene.view_settings.view_transform = "Standard"
	scene.render.image_settings.file_format = "OPEN_EXR"
	scene.render.image_settings.color_depth = "32"
	scene.render.image_settings.exr_codec = "ZIP"

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
		pos, dire, co, tint, uv, blocks = load_dump(obj_path)
		if not pos or not dire:
			print("no camera header in", name, file=sys.stderr)
			sys.exit(1)
		clear_scene()
		stem = name[:-7] if name.endswith(".obj.gz") else name[:-4]
		setup_world(stem.split("_")[2])
		# The shooter renamed the textures after the dump's stem
		# (<stem>_texN.png); the usemtl lines still carry the dump's own name
		blocks = [(stem + m[m.rfind("_tex"):] if m else "", a, n)
				for m, a, n in blocks]
		build_world(scene, co, tint, uv, blocks, OUT)
		del co, tint, uv
		scene.camera = add_camera(pos, dire)
		# cycles_vp6_1300_none.png: the dump's stem without the seed, so the
		# render sits beside its .obj.gz without sharing a name with it.
		base = "cycles_" + stem.split("_", 1)[1]
		exr = os.path.join(OUT, base + ".exr")
		scene.render.filepath = exr
		print("render", base)
		bpy.ops.render.render(write_still=True)
		expose(exr, os.path.join(OUT, base + ".png"))


if __name__ == "__main__":
	main()
