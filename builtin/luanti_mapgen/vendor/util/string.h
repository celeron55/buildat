// A shim, not Luanti's: see ../README.txt.
//
// What the mapgen uses of Luanti's string helpers, which is the flag
// descriptions and a number to a string.
#pragma once
#include "../irrlichttypes.h"
#include <string>
#include <sstream>
#include <vector>

// A flag's name and the bit it is
struct FlagDesc {
	const char *name;
	u32 flag;
};

inline std::string itos(s32 i){ std::ostringstream o; o<<i; return o.str(); }
inline std::string i64tos(s64 i){ std::ostringstream o; o<<i; return o.str(); }
inline std::string ftos(float f){ std::ostringstream o; o<<f; return o.str(); }

// The flags a string names, out of a table of them. Luanti takes
// "a,b,noc"; a name with "no" in front turns one off.
inline u32 readFlagString(std::string str, const FlagDesc *flagdesc,
		u32 *flagmask)
{
	u32 result = 0, mask = 0;
	size_t pos = 0;
	while(pos <= str.size()){
		size_t comma = str.find(',', pos);
		std::string part = str.substr(pos,
				(comma == std::string::npos) ? std::string::npos :
				comma - pos);
		pos = (comma == std::string::npos) ? str.size() + 1 : comma + 1;
		while(!part.empty() && part[0] == ' ')
			part.erase(0, 1);
		while(!part.empty() && part[part.size() - 1] == ' ')
			part.erase(part.size() - 1);
		if(part.empty())
			continue;
		bool off = (part.compare(0, 2, "no") == 0);
		const std::string name = off ? part.substr(2) : part;
		for(size_t i = 0; flagdesc[i].name; i++){
			if(name == flagdesc[i].name){
				mask |= flagdesc[i].flag;
				if(!off)
					result |= flagdesc[i].flag;
				break;
			}
		}
	}
	if(flagmask)
		*flagmask = mask;
	return result;
}

inline std::string writeFlagString(u32 flags, const FlagDesc *flagdesc,
		u32 flagmask)
{
	std::string result;
	for(size_t i = 0; flagdesc[i].name; i++){
		if(!(flagmask & flagdesc[i].flag))
			continue;
		if(!result.empty())
			result += ", ";
		if(!(flags & flagdesc[i].flag))
			result += "no";
		result += flagdesc[i].name;
	}
	return result;
}
