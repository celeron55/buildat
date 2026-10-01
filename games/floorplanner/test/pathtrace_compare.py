#!/usr/bin/env python3
# Buildat: games/floorplanner/test/pathtrace_compare.py
# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#
# The client's frame of a viewport against Cycles' (pathtrace_render.py),
# in linear light: the client's screenshot taken back through its gamma
# and its Uncharted2 (daylight.lua's M.pbr_render_path), Cycles' radiance
# as rendered. Neither's exposure is known to the other, so what is
# compared is free of it: each region's luminance over the first region's,
# and its chromaticity (r/g, b/g). Writes <npy stem>.png, Cycles' frame
# through the client's pipeline, to look at side by side.
#
#   pathtrace_compare.py client.png cycles.npy name:x0,y0,x1,y1 ...
#
# simplified: a channel the client clipped at white does not invert;
# regions are to be picked off the sun's patches
import sys

import numpy as np
from PIL import Image

LUM = np.array([0.2126, 0.7152, 0.0722])
LUM_RANGE = (0.003, 7.0)
MIDDLE_GREY = 0.18
MAX_WHITE = 2.0


def u2(v):
	A, B, C, D, E, F = 0.15, 0.50, 0.10, 0.20, 0.02, 0.30
	return ((v * (A * v + C * B) + D * E) / (v * (A * v + B) + D * F)) - E / F


# Uncharted2 is monotonic: inverted by a table
XS = np.linspace(0, 64, 200001)
YS = u2(XS) / u2(MAX_WHITE)


def client_linear(path):
	c = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255
	return np.interp(c ** 2.2, YS, XS)


def client_frame(rgb):
	key = float(np.exp(np.mean(np.log(rgb @ LUM + 1e-5))))
	key = min(max(key, LUM_RANGE[0]), LUM_RANGE[1])
	return np.clip(u2(rgb * MIDDLE_GREY / key) / u2(MAX_WHITE), 0, 1) ** (1 / 2.2)


def main():
	client = client_linear(sys.argv[1])
	cyc = np.load(sys.argv[2]).astype(np.float64)
	out = sys.argv[2][:-4] + ".png"
	Image.fromarray((client_frame(cyc) * 255 + 0.5).astype(np.uint8)).save(out)
	print("wrote", out)
	regions = []
	for a in sys.argv[3:]:
		name, box = a.split(":")
		x0, y0, x1, y1 = (int(v) for v in box.split(","))
		regions.append((name, (x0, y0, x1, y1)))
	print("%-10s %22s %22s" % ("", "client", "cycles"))
	print("%-10s %22s %22s" % ("region", "lum   r/g   b/g", "lum   r/g   b/g"))
	base = {}
	for name, (x0, y0, x1, y1) in regions:
		row = []
		for k, img in (("client", client), ("cycles", cyc)):
			m = img[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)
			lum = m @ LUM
			base.setdefault(k, lum)
			row.append("%6.3f %5.2f %5.2f" % (lum / base[k], m[0] / m[1],
					m[2] / m[1]))
		print("%-10s %22s %22s" % (name, row[0], row[1]))


main()
