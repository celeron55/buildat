// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_1] phase 4: a zip as ContentDB and an app archive hand it
// over (interface/zip.h): listed, then extracted into a scratch directory
// that is emptied after every input. A file landing outside it is a crash.
#include "interface/zip.h"
#include "interface/fs.h"
#include <fstream>
#include <stdexcept>
#include <unistd.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static const ss_ base = "/tmp/buildat_zip_fuzz." + std::to_string(getpid());
	static const ss_ path = base + ".zip";
	static const ss_ dir = base + ".d/inner";
	{
		std::ofstream f(path, std::ios::binary);
		f.write((const char*)data, size);
	}
	try {
		interface::zip_list(path);
	} catch(std::exception &e){
	}
	try {
		interface::fs::create_directories(dir);
		interface::zip_extract(path, dir);
	} catch(std::exception &e){
	}
	// Nothing beside the directory it was told to write in
	for(const auto &n : interface::fs::list_directory(base + ".d")){
		if(n.name != "inner")
			__builtin_trap();
	}
	interface::fs::remove_all(base + ".d");
	return 0;
}
