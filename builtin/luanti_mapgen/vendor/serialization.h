// A shim, not Luanti's: see README.txt.
//
// Luanti's map serialization versions, and the compression a schematic
// file's node data is behind. What reads a .mts here is mg_schematic, and
// the numbers below are Luanti's own so that a file written by Luanti is
// read the way Luanti reads it.
//
// simplified: compress() and decompress() are not implemented, so a .mts
// file is not read yet -- a schematic in a mod's own Lua table is, which is
// how most of them are written. buildat has zlib (interface/compress.h) and
// zstd; what is missing beside them is MapNode::serializeBulk, which lives
// in Luanti's mapnode.cpp and is a shim here. See README.txt.
#pragma once
#include "irrlichttypes_bloated.h"
#include "exceptions.h"
#include <iostream>

constexpr u8 SER_FMT_VER_INVALID = 255;
constexpr u8 SER_FMT_VER_LOWEST_READ = 0;
constexpr u8 SER_FMT_VER_LOWEST_WRITE = 24;
constexpr u8 SER_FMT_VER_HIGHEST_READ = 29;
constexpr u8 SER_FMT_VER_HIGHEST_WRITE = 29;

inline bool ser_ver_supported_read(s32 v)
{
	return v >= SER_FMT_VER_LOWEST_READ && v <= SER_FMT_VER_HIGHEST_READ;
}

inline bool ser_ver_supported_write(s32 v)
{
	return v >= SER_FMT_VER_LOWEST_WRITE && v <= SER_FMT_VER_HIGHEST_WRITE;
}

// The two a schematic file goes through
void compress(const u8 *data, size_t len, std::ostream &os, u8 version,
		int level = -1);
void compress(const std::string &data, std::ostream &os, u8 version,
		int level = -1);
void decompress(std::istream &is, std::ostream &os, u8 version);
