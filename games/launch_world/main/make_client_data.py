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

TILES = {
	# name: (r, g, b) at the top of the tile, and at the bottom, so a face
	# has some gradient in it rather than being one flat patch
	"stone": ((78, 78, 86), (58, 58, 66)),
	"dark": ((34, 34, 40), (24, 24, 30)),
	"floor_light": ((168, 170, 176), (150, 152, 158)),
	"floor_dark": ((26, 26, 32), (18, 18, 24)),
}


def png(path, rows):
	raw = b"".join(b"\0" + bytes(r) for r in rows)
	def chunk(tag, data):
		c = struct.pack(">I", len(data)) + tag + data
		return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
	head = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
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
		rows = []
		for y in range(SIZE):
			t = y / float(SIZE - 1)
			c = [int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)]
			# A little texel noise, deterministic, so a face is not a
			# perfectly flat colour under a sharp light
			row = []
			for x in range(SIZE):
				n = ((x * 7 + y * 13) % 5) - 2
				row += [max(0, min(255, v + n)) for v in c]
			rows.append(row)
		png(os.path.join(here, name + ".png"), rows)
		print("wrote", name + ".png")


main()
