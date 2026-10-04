// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_1] phase 4: JSON as ContentDB, Starport and a server's
// files feed it (core/json.h load_string, over sajson).
#include "core/types.h"
#include "core/json.h"
#include <stdexcept>

// What load_string has to keep doing whatever sajson is under it: a bare
// value at the root (Starport stores a string), and a refusal of two values
// and of nesting past the cap. Run once, before the fuzzing.
extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	if(json::load_string("\"grown\"").as_string() != "grown" ||
			json::load_string("5").as_integer() != 5 ||
			!json::load_string("{\"a\":[1,2]}").is_object() ||
			!json::load_string("1,2").is_undefined() ||
			!json::load_string("").is_undefined())
		__builtin_trap();
	const std::string deep = std::string(1000, '[') + std::string(1000, ']');
	if(!json::load_string(deep.c_str()).is_undefined())
		__builtin_trap();
	return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const ss_ in((const char*)data, size);
	try {
		json::Value v = json::load_string(in.c_str());
		(void)v.desc_type();
	} catch(std::exception &e){
	}
	return 0;
}
