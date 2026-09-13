// A shim, not Luanti's: see README.txt.
//
// Luanti counts what its mapgen spends; buildat has its own timing and the
// mapgen's own numbers go nowhere here.
#ifndef LUANTI_SHIM_PROFILER_H
#define LUANTI_SHIM_PROFILER_H
#include <string>

enum ScopeProfilerType {
	SPT_ADD,
	SPT_AVG,
	SPT_GRAPH_ADD,
	SPT_MAX,
};

class Profiler
{
public:
	void add(const std::string &name, float value){}
	void avg(const std::string &name, float value){}
};

extern Profiler *g_profiler;

// A scope timer that adds to the profiler, which is nothing here
class ScopeProfiler
{
public:
	ScopeProfiler(Profiler *p, const std::string &name,
			ScopeProfilerType type = SPT_ADD, int prec = 0){}
};

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

#endif
