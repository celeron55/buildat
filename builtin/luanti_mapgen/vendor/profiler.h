// A shim, not Luanti's: see README.txt.
//
// Luanti counts what its mapgen spends; buildat has its own timing and the
// mapgen's own numbers go nowhere here.
#pragma once
#include <string>

class Profiler
{
public:
	void add(const std::string &name, float value){}
	void avg(const std::string &name, float value){}
};

extern Profiler *g_profiler;

// Luanti's scope timers, which are nothing here
#define TimeTaker LuantiShimTimeTaker
class LuantiShimTimeTaker
{
public:
	LuantiShimTimeTaker(const std::string &name, void *p = nullptr,
			int prec = 0){}
	u32 stop(bool quiet = false){ return 0; }
	u32 getTimerTime(){ return 0; }
};
