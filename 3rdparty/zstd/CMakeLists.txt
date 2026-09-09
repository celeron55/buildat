cmake_minimum_required(VERSION 2.6)
project(zstd C)

# zstd 1.5.7's lib/, without dictBuilder, legacy and deprecated, and without
# lib/decompress/huf_decompress_amd64.S (ZSTD_DISABLE_ASM below). Upstream
# sources are unmodified; this file replaces upstream's build.
set(SRCS
	lib/common/debug.c
	lib/common/entropy_common.c
	lib/common/error_private.c
	lib/common/fse_decompress.c
	lib/common/pool.c
	lib/common/threading.c
	lib/common/xxhash.c
	lib/common/zstd_common.c
	lib/compress/fse_compress.c
	lib/compress/hist.c
	lib/compress/huf_compress.c
	lib/compress/zstd_compress.c
	lib/compress/zstd_compress_literals.c
	lib/compress/zstd_compress_sequences.c
	lib/compress/zstd_compress_superblock.c
	lib/compress/zstd_double_fast.c
	lib/compress/zstd_fast.c
	lib/compress/zstd_lazy.c
	lib/compress/zstd_ldm.c
	lib/compress/zstdmt_compress.c
	lib/compress/zstd_opt.c
	lib/compress/zstd_preSplit.c
	lib/decompress/huf_decompress.c
	lib/decompress/zstd_ddict.c
	lib/decompress/zstd_decompress_block.c
	lib/decompress/zstd_decompress.c
)
add_library(zstd STATIC ${SRCS})
target_include_directories(zstd PUBLIC lib)
target_include_directories(zstd PRIVATE lib/common)
# ZSTD_DISABLE_ASM: the assembly path is one huffman decoding loop and comes
# with the toolchain questions of assembling anything. Turn it on if profiling
# says decoding is worth it.
# ZSTD_MULTITHREAD is off, so pool.c, threading.c and zstdmt_compress.c compile
# to nothing.
target_compile_definitions(zstd PRIVATE
	ZSTD_DISABLE_ASM
	XXH_NAMESPACE=ZSTD_
)
set_target_properties(zstd PROPERTIES POSITION_INDEPENDENT_CODE ON)
