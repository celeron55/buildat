#!/usr/bin/env python3
# Buildat: apps/floorplanner/test/pathtrace_compare.py
# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#
# The client's frame of a viewport against Cycles' (pathtrace_render.py)
# as they are seen: Cycles' radiance put through the client's frame
# pipeline -- the meter (daylight.lua's M.pbr_render_path), the eye's
# adaptation to the white a grey card sees where the client takes its
# white, and PBR Neutral
# (FpFrame.glsl), gamma -- and written as <npy stem>.png to look at beside
# the client's screenshot; and each region's mean in both, as the screen
# shows it, and as linear luminance over the first region's and
# chromaticity (r/g, b/g).
#
#   pathtrace_compare.py client.png cycles.npy name:x0,y0,x1,y1 ...
#
# simplified: no bloom
import math
import sys

import numpy as np
from PIL import Image

LUM = np.array([0.2126, 0.7152, 0.0722])
LUM_RANGE = (0.003, 7.0)
MIDDLE_GREY = 0.18
CD_PER_UNIT = 1000.0
# Linear sRGB to Bradford's cone responses
RGB2LMS = np.array([[0.422725, 0.491345, 0.027358],
		[0.055700, 0.961534, 0.023184], [0.021383, 0.087642, 0.980508]])


def pbr_neutral(c):
	start, desat = 0.8 - 0.04, 0.15
	x = c.min(axis=-1, keepdims=True)
	c = c - np.where(x < 0.08, x - 6.25 * x * x, 0.04)
	peak = c.max(axis=-1, keepdims=True)
	d = 1 - start
	new = 1 - d * d / (peak + d - start)
	g = 1 - 1 / (desat * (peak - new) + 1)
	comp = c * new / np.maximum(peak, 1e-9)
	comp = comp + (new - comp) * g
	return np.where(peak < start, c, comp)


def frame(rgb, white):
	key = float(np.exp(np.mean(np.log(rgb @ LUM + 1e-5))))
	key = min(max(key, LUM_RANGE[0]), LUM_RANGE[1])
	rgb = rgb * MIDDLE_GREY / key
	la = key * CD_PER_UNIT
	D = min(max(1 - math.exp((-la - 42) / 92) / 3.6, 0), 1)
	w = white / (white @ LUM)
	gain = 1 + (RGB2LMS @ np.ones(3) / (RGB2LMS @ w) - 1) * D
	m = np.linalg.inv(RGB2LMS) @ np.diag(gain) @ RGB2LMS
	rgb = np.maximum(rgb @ m.T, 0)
	print("key %.4f, D %.3f, white r/g %.2f b/g %.2f" % (key, D,
			white[0] / white[1], white[2] / white[1]))
	return np.clip(pbr_neutral(rgb), 0, 1) ** (1 / 2.2)


def main():
	client = np.asarray(Image.open(sys.argv[1]).convert("RGB"),
			dtype=np.float64) / 255
	stem = sys.argv[2][:-4]
	cyc = frame(np.load(sys.argv[2]).astype(np.float64),
			np.load(stem + "_white.npy").astype(np.float64))
	Image.fromarray((cyc * 255 + 0.5).astype(np.uint8)).save(stem + ".png")
	print("wrote", stem + ".png")
	print("%-10s %34s %34s" % ("", "client", "cycles"))
	print("%-10s %34s %34s" % ("region", "screen         lum   r/g   b/g",
			"screen         lum   r/g   b/g"))
	base = {}
	for a in sys.argv[3:]:
		name, box = a.split(":")
		x0, y0, x1, y1 = (int(v) for v in box.split(","))
		row = []
		for k, img in (("client", client), ("cycles", cyc)):
			m = img[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)
			lin = (img[y0:y1, x0:x1] ** 2.2).reshape(-1, 3).mean(axis=0)
			lum = lin @ LUM
			base.setdefault(k, lum)
			row.append("%3d,%3d,%3d  %6.3f %5.2f %5.2f" % (*(m * 255 + 0.5),
					lum / base[k], lin[0] / lin[1], lin[2] / lin[1]))
		print("%-10s %34s %34s" % (name, row[0], row[1]))


main()
