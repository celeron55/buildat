// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_1] phase 4: the decompressors a server, a save, an imported
// world and a ContentDB zip feed (interface/compress.h). The first byte picks
// one; the rest is the input. max_out is smaller than DECOMPRESS_MAX so a
// bomb is found as "it stopped" and not as an out-of-memory.
#include "interface/compress.h"
#include <sstream>
#include <stdexcept>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if(size < 1)
		return 0;
	const ss_ in((const char*)data + 1, size - 1);
	static const size_t MAX = 1 << 20;
	try {
		std::ostringstream os(std::ios::binary);
		switch(data[0] % 4){
		case 0: {
			std::istringstream is(in, std::ios::binary);
			interface::decompress_zlib(is, os, MAX);
			break;
		}
		case 1: {
			std::istringstream is(in, std::ios::binary);
			interface::decompress_deflate_raw(is, os, MAX);
			break;
		}
		case 2:
			interface::decompress_zstd(in, os, MAX);
			break;
		case 3: {
			uint8_t buf[4096];
			interface::decompress_zstd(in, buf, sizeof buf);
			break;
		}
		}
		if(os.str().size() > MAX)
			__builtin_trap();
	} catch(std::exception &e){
		// Refusing an input is the decoder working
	}
	return 0;
}
