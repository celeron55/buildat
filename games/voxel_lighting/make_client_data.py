#!/usr/bin/env python3
# Generates the environment cube map the voxel shader reflects and the water
# texture. The output is committed, so this only needs running when one of them
# is being changed.
#
# The cube map goes into the client's own data directory, next to the technique
# that reflects it, rather than into this game's: it is the sky that goes with
# PBRVoxel's lighting model, and both games that use skylight share it. The
# water texture is this game's alone and goes into main/client_data.
#
# The other voxel textures are hand drawn and predate this; there is no normal
# or roughness map for any of them, because the atlas derives both from the
# texture itself (see src/impl/atlas.cpp).
#
# The sun disc is deliberately not drawn. The scene's directional light already
# provides the sun's specular highlight, and putting it in the cube map as well
# would give every surface two suns.
#
# Values are in the same scale as the zone's ambient color, which is what a
# surface with full skylight receives: this map is the same sky seen in a
# mirror rather than a separate, brighter one.
import os
import struct
import zlib

SIZE = 64
ZENITH = (0.16, 0.26, 0.52)
HORIZON = (0.60, 0.68, 0.80)
GROUND = (0.14, 0.13, 0.11)
# The scene's light points this way, so the sun is in the opposite direction
LIGHT_DIR = (-0.6, -1.0, 0.8)
GLOW = (0.34, 0.28, 0.18)
GLOW_EXPONENT = 4.0

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
GAME_DIR = os.path.join(ROOT, "games", "voxel_lighting", "main", "client_data")
SKY_DIR = os.path.join(ROOT, "client", "data", "Textures")


def normalized(v):
    l = sum(c * c for c in v) ** 0.5
    return tuple(c / l for c in v)


SUN = normalized(tuple(-c for c in LIGHT_DIR))


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def sky_color(d):
    d = normalized(d)
    if d[1] >= 0.0:
        c = mix(HORIZON, ZENITH, d[1] ** 0.5)
    else:
        c = mix(mix(HORIZON, GROUND, 0.5), GROUND, min(1.0, -d[1] * 3.0))
    # A broad glow around the sun, cut off at the horizon along with the sky
    cos_sun = max(0.0, sum(d[i] * SUN[i] for i in range(3)))
    glow = cos_sun ** GLOW_EXPONENT * max(0.0, min(1.0, d[1] * 4.0 + 0.5))
    return tuple(min(1.0, c[i] + GLOW[i] * glow) for i in range(3))


# The standard cube map face parametrization: u and v run 0..1 from the top
# left of the face, and sc, tc are those in -1..1.
FACES = {
    "posx": lambda sc, tc: (1.0, -tc, -sc),
    "negx": lambda sc, tc: (-1.0, -tc, sc),
    "posy": lambda sc, tc: (sc, 1.0, tc),
    "negy": lambda sc, tc: (sc, -1.0, -tc),
    "posz": lambda sc, tc: (sc, -tc, 1.0),
    "negz": lambda sc, tc: (-sc, -tc, -1.0),
}


def write_png_size(path, rows, size):
    def chunk(tag, data):
        c = tag + data
        return (struct.pack(">I", len(data)) + c +
                struct.pack(">I", zlib.crc32(c) & 0xffffffff))
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    png = (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) +
            chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


WATER_SIZE = 16
# Water reflects nearly everything and absorbs the rest, so its albedo is dark
# and slightly green-blue. What makes it read as water is the reflection, not
# this.
WATER_COLOR = (0.045, 0.115, 0.135)
# Small enough that the roughness the atlas derives from it stays near the
# material's own, big enough that the normals get a visible ripple once
# bumpiness scales them up
WATER_RIPPLE = 0.022


def make_water():
    import math
    rows = []
    for y in range(WATER_SIZE):
        row = []
        for x in range(WATER_SIZE):
            u = x / WATER_SIZE * 2.0 * math.pi
            v = y / WATER_SIZE * 2.0 * math.pi
            # Two waves at different angles and periods, both whole numbers of
            # cycles across the texture so that it tiles
            h = (math.sin(u + v * 2.0) * 0.6 +
                    math.sin(u * 2.0 - v) * 0.4)
            for c in WATER_COLOR:
                row.append(max(0, min(255,
                        int((c + h * WATER_RIPPLE) * 255.0 + 0.5))))
        rows.append(row)
    write_png_size(os.path.join(GAME_DIR, "water.png"), rows, WATER_SIZE)
    print("water.png")


def main():
    make_water()
    for name, to_dir in FACES.items():
        rows = []
        for y in range(SIZE):
            tc = (y + 0.5) / SIZE * 2.0 - 1.0
            row = []
            for x in range(SIZE):
                sc = (x + 0.5) / SIZE * 2.0 - 1.0
                for c in sky_color(to_dir(sc, tc)):
                    row.append(max(0, min(255, int(c * 255.0 + 0.5))))
            rows.append(row)
        write_png_size(os.path.join(SKY_DIR, "VoxelSky_" + name + ".png"),
                rows, SIZE)
        print("VoxelSky_" + name + ".png")


main()
