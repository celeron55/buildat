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
#include <Urho3D/Graphics/VertexBuffer.h>
#include <Urho3D/IO/FileSystem.h>
#include <Urho3D/IO/MemoryBuffer.h>
#include <Urho3D/Resource/ResourceCache.h>
#include <cstdint>
#include <cstring>

extern "C" int __lsan_is_turned_off() { return 1; }

// [SEC_RUN3_LEFTOVERS] simplified: the counts a UMDL/UMD2/UANI file
// declares are walked here as BeginLoad reads them, and a file is skipped
// when one would size an allocation past 16 MiB (the 32-bit product
// BeginLoad itself computes, so a wrapped one still runs), drive a loop
// past what the bytes left can hold, or be read past the end (BeginLoad's
// ReadUInt then returns uninitialised stack bytes: neither reproducible
// nor cappable). Run 3's restarts were these. The large-count paths go
// unfuzzed; drop this for a run that wants them.
namespace {
struct Walk {
	const uint8_t *p; size_t n, pos = 0;
	bool past = false;
	size_t left() const { return n - pos; }
	uint32_t u32(){
		if(left() < 4){ past = true; pos = n; return 0; }
		uint32_t v; memcpy(&v, p + pos, 4); pos += 4; return v;
	}
	uint8_t u8(){ if(!left()){ past = true; return 0; } return p[pos++]; }
	void skip(uint64_t k){ pos = k > left() ? n : pos + (size_t)k; }
	void str(){ while(pos < n && p[pos++]); }
	// A loop of `count` iterations of at least `each` bytes
	bool fits(uint32_t count, size_t each){ return !past && count <= left() / each; }
};
const uint32_t max_alloc = 1u << 24;

// true: hand the file to BeginLoad
bool model_ok(const uint8_t *data, size_t size)
{
	using namespace Urho3D;
	Walk w{data, size};
	if(size < 4 || (memcmp(data, "UMDL", 4) && memcmp(data, "UMD2", 4)))
		return true; // glTF, or rejected
	bool decl = data[3] == '2';
	w.pos = 4;
	uint32_t nvb = w.u32();
	if(!w.fits(nvb, 16)) return false;
	for(uint32_t i = 0; i < nvb; i++){
		uint32_t count = w.u32();
		PODVector<VertexElement> el;
		if(!decl){
			el = VertexBuffer::GetElements(w.u32());
		} else {
			uint32_t ne = w.u32();
			if(!w.fits(ne, 4)) return false;
			for(uint32_t j = 0; j < ne; j++){
				uint32_t d = w.u32();
				if((d & 0xff) >= MAX_VERTEX_ELEMENT_TYPES ||
						((d >> 8) & 0xff) >= MAX_VERTEX_ELEMENT_SEMANTICS)
					return !w.past; // BeginLoad refuses it here
				el.Push(VertexElement((VertexElementType)(d & 0xff),
						(VertexElementSemantic)((d >> 8) & 0xff),
						(unsigned char)((d >> 16) & 0xff)));
			}
		}
		w.u32(); w.u32(); // morph range
		if(w.past) return false;
		uint32_t bytes = count * VertexBuffer::GetVertexSize(el);
		if(bytes > max_alloc) return false;
		w.skip(bytes);
	}
	uint32_t nib = w.u32();
	if(!w.fits(nib, 8)) return false;
	for(uint32_t i = 0; i < nib; i++){
		uint32_t count = w.u32(), isz = w.u32();
		if(w.past) return false;
		// As SetSize allocates it, and as BeginLoad reads into it
		if(count * (isz > 2 ? 4u : 2u) > max_alloc) return false;
		w.skip((uint32_t)(count * isz));
	}
	uint32_t ngeo = w.u32();
	if(!w.fits(ngeo, 8)) return false;
	for(uint32_t i = 0; i < ngeo; i++){
		uint32_t bones = w.u32();
		if(!w.fits(bones, 4)) return false;
		w.skip((uint64_t)bones * 4);
		uint32_t lods = w.u32();
		if(!w.fits(lods, 24)) return false;
		for(uint32_t j = 0; j < lods; j++){
			w.u32(); uint32_t type = w.u32(), vb = w.u32(), ib = w.u32();
			w.u32(); w.u32();
			if(w.past) return false;
			if(type > TRIANGLE_FAN || vb >= nvb || ib >= nib)
				return true; // BeginLoad refuses it here
		}
	}
	uint32_t nmorph = w.u32();
	if(!w.fits(nmorph, 5)) return false;
	for(uint32_t i = 0; i < nmorph; i++){
		w.str();
		uint32_t nbuf = w.u32();
		if(!w.fits(nbuf, 12)) return false;
		for(uint32_t j = 0; j < nbuf; j++){
			w.u32(); uint32_t mask = w.u32(), count = w.u32();
			if(w.past) return false;
			uint32_t vsize = 4 + 12 * (!!(mask & MASK_POSITION) +
					!!(mask & MASK_NORMAL) + !!(mask & MASK_TANGENT));
			uint32_t bytes = count * vsize;
			if(bytes > max_alloc) return false;
			w.skip(bytes);
		}
	}
	if(!w.left()) return true; // Skeleton::Load stops at the end
	uint32_t nbone = w.u32();
	if(!w.fits(nbone, 94)) return false;
	for(uint32_t i = 0; i < nbone; i++){
		w.str(); w.skip(4 + 12 + 16 + 12 + 48);
		uint8_t m = w.u8();
		w.skip(((m & 1) ? 4 : 0) + ((m & 2) ? 24 : 0));
	}
	return true;
}

bool animation_ok(const uint8_t *data, size_t size)
{
	using namespace Urho3D;
	Walk w{data, size};
	if(size < 4 || memcmp(data, "UANI", 4))
		return true; // glTF, or rejected
	w.pos = 4;
	w.str(); w.u32(); // name, length
	uint32_t tracks = w.u32();
	if(!w.fits(tracks, 6)) return false;
	for(uint32_t i = 0; i < tracks; i++){
		w.str();
		uint8_t m = w.u8();
		uint32_t keys = w.u32();
		if(!w.fits(keys, 4)) return false;
		size_t each = 4 + ((m & CHANNEL_POSITION) ? 12 : 0) +
				((m & CHANNEL_ROTATION) ? 16 : 0) + ((m & CHANNEL_SCALE) ? 12 : 0);
		w.skip((uint64_t)keys * each);
	}
	return true;
}
}

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
		if(!animation_ok(data + 1, size - 1))
			return 0;
		SharedPtr<Animation> a(new Animation(context));
		if(a->BeginLoad(buf))
			a->EndLoad();
		return 0;
	}
	if(!model_ok(data + 1, size - 1))
		return 0;
	SharedPtr<Model> m(new Model(context));
	if(m->BeginLoad(buf))
		m->EndLoad();
	return 0;
}
