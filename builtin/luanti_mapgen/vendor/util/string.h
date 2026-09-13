// A shim, not Luanti's: see ../README.txt.
//
// What the mapgen uses of Luanti's string helpers, which is the flag
// descriptions and a number to a string.
#ifndef LUANTI_SHIM_UTIL_STRING_H
#define LUANTI_SHIM_UTIL_STRING_H
#include "../irrlichttypes.h"
// itos() and ftos() are buildat's own; a second pair here would be
// ambiguous with them in the one translation unit a module is
#include "core/types.h"
#include "../irr_v3d.h"
#include <string>
#include <cstdlib>
#include <cctype>
#include <optional>
#include <unordered_map>
#include <stdexcept>
#include <sstream>
#include <vector>

// A flag's name and the bit it is
struct FlagDesc {
	const char *name;
	u32 flag;
};

inline int rangelim_int(int v, int min, int max)
{
	return v < min ? min : (v > max ? max : v);
}

// A string that is a number, and one that is three of them: what a mapgen
// reads a setting with
inline bool is_number(const std::string &s)
{
	if(s.empty())
		return false;
	size_t i = (s[0] == '-' || s[0] == '+') ? 1 : 0;
	if(i >= s.size())
		return false;
	for(; i < s.size(); i++){
		if(!isdigit((unsigned char)s[i]))
			return false;
	}
	return true;
}

// Luanti's own name for a table of strings, which a mapgen's notifications
// are carried in
typedef std::unordered_map<std::string, std::string> StringMap;

// A number inside a range, or the range's end: what a mapgen does with a
// setting somebody typed
inline int stoi(const std::string &str, int min, int max)
{
	int i;
	try {
		i = std::stoi(str);
	} catch(const std::exception &){
		i = 0;
	}
	return rangelim_int(i, min, max);
}

inline std::optional<v3f> str_to_v3f(const std::string &str)
{
	// "(x, y, z)" or "x, y, z", which is what Luanti writes
	std::string s = str;
	for(char &c : s){
		if(c == '(' || c == ')' || c == ',')
			c = ' ';
	}
	std::istringstream is(s);
	float x = 0, y = 0, z = 0;
	if(!(is>>x) || !(is>>y) || !(is>>z))
		return std::nullopt;
	return v3f(x, y, z);
}

inline s64 read_seed(const std::string &str)
{
	// A number is that number, and anything else is its own hash, which is
	// how Luanti takes a seed a player typed
	if(is_number(str))
		return (s64)strtoll(str.c_str(), nullptr, 10);
	s64 seed = 0;
	for(char c : str)
		seed = seed * 6364136223846793005LL + (s64)(unsigned char)c;
	return seed;
}

inline std::string i64tos(s64 i){ std::ostringstream o; o<<i; return o.str(); }

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

#endif
