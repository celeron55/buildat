// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_2]: a font as a server hands it to the client. A script's
// GetResource("Font", "x.ttf") and Text:SetFont() give the file to
// FreeType the way FontFaceFreeType::Load() does: any format FreeType
// knows (the extension picks FreeType, not the format), every character
// the face maps, rendered.
//
// fuzz.sh compiles Urho3D's bundled FreeType into this harness,
// instrumented.
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include <cstdint>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static FT_Library library = nullptr;
	if(!library && FT_Init_FreeType(&library))
		return 0;
	// Its first byte picks Urho3D's load mode, as a font's .xml would
	const FT_Int32 modes[4] = {FT_LOAD_DEFAULT, FT_LOAD_FORCE_AUTOHINT,
			FT_LOAD_NO_HINTING, FT_LOAD_TARGET_LIGHT};
	if(size < 1)
		return 0;
	const FT_Int32 mode = modes[data[0] & 3];
	// Urho3D keeps the bytes for the face's life
	std::vector<uint8_t> bytes(data + 1, data + size);
	FT_Face face;
	if(FT_New_Memory_Face(library, bytes.data(), (FT_Long)bytes.size(), 0,
			&face))
		return 0;
	// FontFaceFreeType: a point size times oversampling, at 96 DPI
	if(FT_Set_Char_Size(face, 0, 12 * 64, 96, 96) == 0){
		FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
		if(FT_HAS_KERNING(face)){
			FT_ULong n = 0;
			if(FT_Load_Sfnt_Table(face, FT_MAKE_TAG('k','e','r','n'), 0,
					nullptr, &n) == 0 && n < (1u << 20)){
				std::vector<FT_Byte> kern(n);
				FT_Load_Sfnt_Table(face, FT_MAKE_TAG('k','e','r','n'), 0,
						kern.data(), &n);
			}
		}
		// simplified: the first 256 mapped characters; Urho3D renders the
		// ones a text asks for, which a hostile game can make all of them
		FT_UInt glyph;
		FT_ULong c = FT_Get_First_Char(face, &glyph);
		for(int i = 0; glyph && i < 256; i++){
			FT_Load_Char(face, c, mode | FT_LOAD_RENDER);
			c = FT_Get_Next_Char(face, c, &glyph);
		}
	}
	FT_Done_Face(face);
	return 0;
}
