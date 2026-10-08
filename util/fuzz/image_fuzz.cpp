// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_1] phase 4: an image as a server hands it to the client
// (a texture, any name: Urho3D's Image refuses DDS, KTX, PVR and WebP by
// their first bytes and gives the rest to stb_image), loaded and then
// walked the way a texture upload walks it -- every mip level, a
// compressed one decompressed as when the GPU lacks the format.
//
// fuzz.sh compiles Image.cpp and Decompress.cpp into this harness, so the
// decoders are instrumented and override the shared library's; the rest
// of Urho3D comes from Build/lib uninstrumented.
#include <Urho3D/Core/Context.h>
#include <Urho3D/IO/MemoryBuffer.h>
#include <Urho3D/Resource/Image.h>
#include <STB/stb_image.h>
#include <cstdint>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	using namespace Urho3D;
	static Context *context = new Context();
	// [SEC_RUN2_LEFTOVERS] simplified: a size declared over 2^24 pixels is
	// skipped, as the compressed branch skips one below -- stb_image
	// decoding what a small input declares held run 2 at 3 exec/s. The
	// large-size paths go unfuzzed; drop this for a run that wants them.
	int w, h, comp;
	if(stbi_info_from_memory(data, (int)size, &w, &h, &comp) &&
			(int64_t)w * h > (1 << 24))
		return 0;
	SharedPtr<Image> image(new Image(context));
	MemoryBuffer buf(data, (unsigned)size);
	if(!image->Load(buf))
		return 0;
	if(image->IsCompressed()){
		// A texture takes no more levels than its size has (log2)
		for(unsigned i = 0; i < image->GetNumCompressedLevels() && i < 32; i++){
			CompressedLevel level = image->GetCompressedLevel(i);
			if(!level.data_)
				break;
			// What the client would allocate; a huge one is not a bug here
			if((size_t)level.width_ * level.height_ > (1u << 24))
				break;
			// As OGLTexture2D.cpp allocates it
			std::vector<unsigned char> out((size_t)level.width_ *
					level.height_ * 4);
			level.Decompress(out.data());
		}
		return 0;
	}
	SharedPtr<Image> mip = image;
	for(int i = 0; i < 16 && mip; i++){
		if(mip->GetWidth() <= 1 && mip->GetHeight() <= 1)
			break;
		mip = mip->GetNextLevel();
	}
	return 0;
}
