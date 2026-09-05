// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Exec buildat_client -m launch_menu. Extra argv is forwarded.

#ifdef _WIN32
	#include <windows.h>
	#include <process.h>
	#include <stdio.h>
	#include <string.h>
	#include <vector>
#else
	#include <unistd.h>
	#include <stdio.h>
	#include <string.h>
	#include <limits.h>
	#include <vector>
#endif

static void client_path(char *out, size_t out_size)
{
#ifdef _WIN32
	char path[MAX_PATH];
	DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
	if(n == 0 || n >= MAX_PATH){
		snprintf(out, out_size, "buildat_client.exe");
		return;
	}
	char *slash = strrchr(path, '\\');
	if(!slash)
		slash = strrchr(path, '/');
	if(slash)
		*(slash + 1) = 0;
	else
		path[0] = 0;
	snprintf(out, out_size, "%sbuildat_client.exe", path);
#else
	char path[PATH_MAX];
	memset(path, 0, sizeof(path));
	if(readlink("/proc/self/exe", path, sizeof(path) - 1) < 0){
		snprintf(out, out_size, "buildat_client");
		return;
	}
	char *slash = strrchr(path, '/');
	if(slash)
		*(slash + 1) = 0;
	else
		path[0] = 0;
	snprintf(out, out_size, "%sbuildat_client", path);
#endif
}

int main(int argc, char *argv[])
{
	char path[8192];
	client_path(path, sizeof(path));

	std::vector<char*> nargv;
	nargv.push_back(path);
	nargv.push_back((char*)"-m");
	nargv.push_back((char*)"launch_menu");
	for(int i = 1; i < argc; i++)
		nargv.push_back(argv[i]);
	nargv.push_back(nullptr);

#ifdef _WIN32
	_execv(path, nargv.data());
#else
	execv(path, nargv.data());
#endif
	fprintf(stderr, "Failed to exec %s -m launch_menu\n", path);
	return 1;
}
// vim: set noet ts=4 sw=4:
