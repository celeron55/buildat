/* Buildat: util/loadprobe.c -- which DLL beside this exe fails to load,
 * and why ([WIN_DLL_INIT]). Windows' own box for 0xc0000142 names no
 * DLL, and a rename test is masked: the loader resolves every import
 * before any DllMain runs. This loads each .dll in its own directory
 * one by one through LoadLibrary and prints the first error with the
 * name -- 1114 (ERROR_DLL_INIT_FAILED) is the box's cause, 126 a DLL
 * that one imports and is not there. Built in the cross image with
 * msvcrt as its only import and shipped in bin\; run it from there, or
 * double-click: it waits for a key and writes loadprobe.txt beside
 * itself as well. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
	char dir[MAX_PATH];
	GetModuleFileNameA(NULL, dir, sizeof(dir));
	char *slash = strrchr(dir, '\\');
	if(slash)
		*slash = '\0';
	SetCurrentDirectoryA(dir);
	FILE *out = fopen("loadprobe.txt", "w");
	WIN32_FIND_DATAA fd;
	HANDLE h = FindFirstFileA("*.dll", &fd);
	int failed = 0;
	if(h != INVALID_HANDLE_VALUE){
		do {
			HMODULE m = LoadLibraryA(fd.cFileName);
			DWORD err = m ? 0 : GetLastError();
			printf("%-28s %s%lu\n", fd.cFileName, m ? "ok " : "FAILED ",
					(unsigned long)err);
			if(out)
				fprintf(out, "%-28s %s%lu\n", fd.cFileName,
						m ? "ok " : "FAILED ", (unsigned long)err);
			if(!m)
				failed++;
			if(m)
				FreeLibrary(m);
		} while(FindNextFileA(h, &fd));
		FindClose(h);
	}
	printf("%d failed (1114: its DllMain failed; 126: a DLL it wants is missing)\n",
			failed);
	if(out){
		fprintf(out, "%d failed\n", failed);
		fclose(out);
	}
	printf("press enter\n");
	getchar();
	return failed;
}
