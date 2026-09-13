// A shim, not Luanti's: see README.txt.
//
// Luanti keeps a settings object and a profiler as globals, and its mapgen
// reaches for both. Here the settings answer that they hold nothing -- so
// the mapgen's own C++ defaults stand -- and the profiler is nobody.
#include "settings.h"
#include "profiler.h"

static Settings s_settings;
Settings *g_settings = &s_settings;
Profiler *g_profiler = nullptr;
