// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_2]: the XML and JSON a server hands the client. A server
// module publishes client_data files (builtin/voxel_shading/client_data/
// VoxelSky.xml is one); the client writes them to its resource cache and a
// module then asks for them -- cache:GetResource("XMLFile"/"Material"/
// "Technique"/"JSONFile", name). Material::BeginLoad and Technique::
// BeginLoad parse through exactly these two, so this one harness covers
// them and every other XMLFile/JSONFile a server can feed. The first byte
// picks: XMLFile::BeginLoad runs pugixml 1.7 (load_buffer) and the RFC
// 5261 patch path; JSONFile::BeginLoad runs rapidjson.
//
// fuzz.sh compiles XMLFile.cpp, JSONFile.cpp and pugixml.cpp into this
// harness so the parsers are instrumented (rapidjson is header-only, so
// JSONFile.cpp pulls it in instrumented too); the rest of Urho3D comes
// from Build/lib uninstrumented. The cache and file system are here
// because an XMLFile with an `inherit` attribute asks the cache for the
// file it patches.
//
// **What this looks for is memory corruption only.** Unlike the model
// target, the parse here is bounded -- 2.2M runs over a 4 KB input cap
// held RSS flat with no OOM and no timeout -- so this runs as a plain
// ASan+UBSan target, not in fork mode. A leak is off (__lsan) because a
// decoder that leaks is the same out-of-scope exhaustion class. The one
// DoS that could still surface is a deeply nested document overflowing
// rapidjson's recursive parse stack; that too is a server denying its
// client service (doc/plan/security_review_plan.md), not a finding.
#include <Urho3D/Core/Context.h>
#include <Urho3D/IO/FileSystem.h>
#include <Urho3D/IO/MemoryBuffer.h>
#include <Urho3D/Resource/JSONFile.h>
#include <Urho3D/Resource/ResourceCache.h>
#include <Urho3D/Resource/XMLFile.h>
#include <cstdint>

extern "C" int __lsan_is_turned_off() { return 1; }

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	using namespace Urho3D;
	static Context *context = nullptr;
	if(!context){
		context = new Context();
		context->RegisterSubsystem(new FileSystem(context));
		context->RegisterSubsystem(new ResourceCache(context));
	}
	if(size < 1)
		return 0;
	MemoryBuffer buf(data + 1, (unsigned)(size - 1));
	if(data[0] & 1){
		SharedPtr<JSONFile> j(new JSONFile(context));
		j->BeginLoad(buf);
		return 0;
	}
	SharedPtr<XMLFile> x(new XMLFile(context));
	x->BeginLoad(buf);
	return 0;
}
