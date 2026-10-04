// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_2]: a model or an animation as a server hands it to the
// client (cache:GetResource("Model"/"Animation", name), any name). The
// first byte picks which: Model::BeginLoad reads UMDL/UMD2 and gives
// anything else to the glTF loader (tinygltf, external files refused);
// Animation::BeginLoad reads UANI. A model that loads is then finished as
// the resource cache finishes it (EndLoad: the buffers and geometries).
//
// fuzz.sh compiles Model.cpp, Animation.cpp, Geometry.cpp, IndexBuffer.cpp
// and GLTFLoader.cpp into this harness, so the parsers are instrumented
// and override the shared library's; the rest of Urho3D comes from
// Build/lib uninstrumented. No Graphics subsystem: the vertex and index
// buffers stay in their shadow copies, which is where a parser's bytes
// land. The cache and file system are here because Animation asks the
// cache for an XML beside the file.
//
// **What this looks for is memory corruption only.** A count from the
// file sizes an allocation or drives a loop that reads past the end
// (zeros) -- gigabytes asked for, or a parse that never ends -- is a
// server denying its client service, out of scope
// (doc/plan/security_review_plan.md). fuzz.sh runs this target in fork
// mode and steps past a timeout or an OOM; leaks are off for the same
// reason (they are the same exhaustion class). A real crash still stops.
#include <Urho3D/Core/Context.h>
#include <Urho3D/Graphics/Animation.h>
#include <Urho3D/Graphics/Model.h>
#include <Urho3D/IO/FileSystem.h>
#include <Urho3D/IO/MemoryBuffer.h>
#include <Urho3D/Resource/ResourceCache.h>
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
		SharedPtr<Animation> a(new Animation(context));
		if(a->BeginLoad(buf))
			a->EndLoad();
		return 0;
	}
	SharedPtr<Model> m(new Model(context));
	if(m->BeginLoad(buf))
		m->EndLoad();
	return 0;
}
