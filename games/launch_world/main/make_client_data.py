#!/usr/bin/env python3
# The voxel tiles for games/launch_world, written by hand into PNGs. The
# output is committed, so this only needs running when a tile changes.
#
# **They are flat on purpose, and it is the one thing the room still
# wants**: the ornament generator (client_lua/ornament.lua) makes the
# meander and the socket field at run time, but a voxel's texture is
# loaded by resource name out of Urho3D's ResourceCache and there is no
# way for a script to put a generated Image in there -- ResourceCache's
# AddManualResource is not in Urho3D's Lua bindings at all. Until that is
# bound, the generated ornament reaches the room's primitives and not its
# voxels, so these carry the colour and nothing else.
#
# No PIL: this writes the PNG itself, as games/voxel_lighting's own
# generator does, so the build depends on nothing.
import os
import struct
import zlib

SIZE = 16

# The reference frame's stone is pale and cool and its checkerboard is
# black against near-white; the first pass at these was warm, dark and
# noisy, and at a room's distance the noise read as static rather than as
# surface (2026-09-23).
TILES = {
	# name: (r, g, b) at the top of the tile, and at the bottom, so a face
	# has some gradient in it rather than being one flat patch
	"stone": ((132, 137, 148), (112, 117, 128)),
	"dark": ((44, 46, 52), (32, 34, 39)),
	"floor_light": ((226, 228, 232), (206, 208, 214)),
	"floor_dark": ((14, 14, 18), (9, 9, 12)),
}


def png(path, rows):
	raw = b"".join(b"\0" + bytes(r) for r in rows)
	def chunk(tag, data):
		c = struct.pack(">I", len(data)) + tag + data
		return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
	# Colour type 6, RGBA: an RGB tile leaves the atlas's alpha to
	# whatever it was, and a masked voxel technique then discards pixels
	# at random -- which is what the wall's speckle turned out to be
	# (2026-09-23)
	head = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
	with open(path, "wb") as f:
		f.write(b"\x89PNG\r\n\x1a\n")
		f.write(chunk(b"IHDR", head))
		f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
		f.write(chunk(b"IEND", b""))


def main():
	here = os.path.join(os.path.dirname(os.path.abspath(__file__)),
			"client_data")
	os.makedirs(here, exist_ok=True)
	for name, (top, bottom) in TILES.items():
		# **Flat, with no gradient either.** A 16x16 tile on a 45 cm face
		# seen from fifteen metres is well under a pixel across, so any
		# variation inside it aliases into speckle -- the wall read as
		# static until both the noise and the top-to-bottom gradient came
		# out (2026-09-23). What gives a face its shading is the mesher's
		# own AO and the lights, which is where it belongs.
		rows = []
		for y in range(SIZE):
			c = [int((top[i] + bottom[i]) / 2) for i in range(3)]
			# Flat, on purpose: a per-texel wobble reads as surface up
			# close and as static across a room, and this room is looked
			# at across a room
			row = []
			for x in range(SIZE):
				row += c + [255]
			rows.append(row)
		png(os.path.join(here, name + ".png"), rows)
		print("wrote", name + ".png")


main()
