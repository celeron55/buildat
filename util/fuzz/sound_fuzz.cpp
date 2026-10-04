// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_2]: a sound as a server hands it to the client. A
// script's GetResource("Sound", name) loads it by its extension -- .ogg
// through stb_vorbis, .wav through Sound::LoadWav, anything else raw --
// and playing an .ogg decodes it as it goes; both done here, the decode
// to its end. The first byte picks the loader, as the name's extension
// would.
//
// fuzz.sh compiles Sound.cpp and OggVorbisSoundStream.cpp (which holds
// stb_vorbis) into this harness, instrumented; the rest of Urho3D comes
// from Build/lib uninstrumented.
//
// **What this looks for is memory corruption only.** It is the guard on
// the stb_vorbis fixes of 2026-10-04 (a 4-byte stack write in
// compute_codewords, v1.09 -> v1.22; then the comment header's wrapped
// count and the uninitialized pointers freed after a failed allocation,
// patched over v1.22; Urho3D_version.txt). An allocation the file sizes
// is a server exhausting its client, out of scope
// (doc/plan/security_review_plan.md) -- **but look at what follows its
// failure**: the second fix was found by replaying with
// ASAN_OPTIONS=allocator_may_return_null=1, as a release build's malloc
// returns NULL. So fuzz.sh runs this with ASan returning NULL for a
// request over 256 MiB (the same, and a huge setup allocation fails at
// once instead of an OOM), and leaks are off here.
#include <Urho3D/Core/Context.h>
#include <Urho3D/IO/MemoryBuffer.h>
#include <Urho3D/Audio/Sound.h>
#include <Urho3D/Audio/SoundStream.h>
#include <cstdint>

extern "C" int __lsan_is_turned_off() { return 1; }

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	using namespace Urho3D;
	static Context *context = new Context();
	if(size < 1)
		return 0;
	SharedPtr<Sound> sound(new Sound(context));
	MemoryBuffer buf(data + 1, (unsigned)size - 1);
	if(data[0] & 1){
		if(!sound->LoadWav(buf))
			return 0;
	} else {
		if(!sound->LoadOggVorbis(buf))
			return 0;
		SharedPtr<SoundStream> stream = sound->GetDecoderStream();
		if(!stream)
			return 0;
		// The mixer's request; a few seconds is enough to reach every
		// packet type, and keeps a long valid stream from timing out
		signed char out[4096];
		for(int i = 0; i < 256 && stream->GetData(out, sizeof out); i++)
			;
	}
	return 0;
}
