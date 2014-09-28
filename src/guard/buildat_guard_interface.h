// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>

// Remember to add / to end of base path if it is a directory
extern "C" {
	// Returns zero if succesful.
	// Returns non-zero on error.
	// Returns non-zero if not supported on platform.
	extern  int buildat_guard_init();
	// If initialized and supported, wraps to the buildat_guard library.
	// If not initialized or not supported, does nothing.
	extern void buildat_guard_add_valid_base_path(const char *path);
	extern void buildat_guard_enable(int enable);
	extern void buildat_guard_clear_paths(void);
}
// vim: set noet ts=4 sw=4:
