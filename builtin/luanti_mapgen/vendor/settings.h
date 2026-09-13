// A shim, not Luanti's: see README.txt.
//
// Luanti's settings, as much as a mapgen reads: it asks for its own noise
// parameters and flags, and what answers is nothing -- the C++ defaults in
// the mapgen's own constructor are what this build generates with. The
// world's own overrides are a later refinement; see "Mapgen stage 3" in
// doc/plan/luanti_module_plan.md.
#pragma once
#include "irrlichttypes_bloated.h"
#include "util/string.h"
#include "exceptions.h"
#include "noise.h"
#include <string>
#include <map>

class Settings
{
public:
	bool getNoiseParams(const std::string &name, NoiseParams &np) const {
		return false;
	}
	void setNoiseParams(const std::string &name, const NoiseParams &np){}

	std::string get(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	bool getNoEx(const std::string &name, std::string &val) const {
		return false;
	}
	bool getFlagStrNoEx(const std::string &name, u32 &val,
			const FlagDesc *flagdesc) const { return false; }
	s16 getS16(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	u16 getU16(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	s32 getS32(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	float getFloat(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	u64 getU64(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	bool getBool(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	bool getS16NoEx(const std::string &name, s16 &val) const { return false; }
	bool getU16NoEx(const std::string &name, u16 &val) const { return false; }
	bool getS32NoEx(const std::string &name, s32 &val) const { return false; }
	bool getFloatNoEx(const std::string &name, float &val) const {
		return false;
	}
	bool getU64NoEx(const std::string &name, u64 &val) const { return false; }
	bool getBoolNoEx(const std::string &name, bool &val) const {
		return false;
	}
	bool exists(const std::string &name) const { return false; }

	bool set(const std::string &name, const std::string &value){ return true; }
	bool setDefault(const std::string &name, const std::string &value){
		return true;
	}
	bool setS16(const std::string &name, s16 value){ return true; }
	bool setU16(const std::string &name, u16 value){ return true; }
	bool setS32(const std::string &name, s32 value){ return true; }
	bool setFloat(const std::string &name, float value){ return true; }
	bool setU64(const std::string &name, u64 value){ return true; }
	bool setBool(const std::string &name, bool value){ return true; }
	bool setFlagStr(const std::string &name, u32 flags,
			const FlagDesc *flagdesc, u32 flagmask){ return true; }
	bool remove(const std::string &name){ return false; }
};

extern Settings *g_settings;
