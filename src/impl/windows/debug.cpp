// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/debug.h"
#include "core/log.h"
#include "ports/windows_minimal.h"
#include <dbghelp.h>
#include <cstring>
#include <cstdint>
#define MODULE "debug"

namespace interface {
namespace debug {

void log_current_backtrace(const ss_ &title)
{
	log_i(MODULE, "Backtrace logging not implemented on Windows");
}

void log_exception_backtrace(const ss_ &title)
{
	log_i(MODULE, "Backtrace logging not implemented on Windows");
}

void get_current_backtrace(StoredBacktrace &result)
{
}

void get_exception_backtrace(StoredBacktrace &result)
{
}

void log_backtrace(const StoredBacktrace &result, const ss_ &title)
{
}

void log_backtrace_chain(const std::list<ThreadBacktrace> &chain,
		const char *reason, bool cut_at_api)
{
}

// A crash writes to the log ([WIN8_START] 8): the exception's code, its
// address and the module that address is in, then a walk of the stack
// through dbghelp when it loads (it ships with Windows; symbols are what
// the exe has, which is names when it was linked with them). The Linux
// signal handler does the same to stderr; here the log is written
// directly, since a default log is teed and stderr may be no console.
static const char *exception_name(DWORD code)
{
	switch(code){
	case EXCEPTION_ACCESS_VIOLATION: return "access violation";
	case EXCEPTION_STACK_OVERFLOW: return "stack overflow";
	case EXCEPTION_ILLEGAL_INSTRUCTION: return "illegal instruction";
	case EXCEPTION_INT_DIVIDE_BY_ZERO: return "integer divide by zero";
	case EXCEPTION_ARRAY_BOUNDS_EXCEEDED: return "array bounds exceeded";
	case EXCEPTION_IN_PAGE_ERROR: return "in-page error";
	case 0xE06D7363: return "C++ exception";
	default: return "exception";
	}
}

static ss_ module_of_address(void *address)
{
	HMODULE mod = NULL;
	if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
			GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			(LPCSTR)address, &mod) || !mod)
		return "?";
	char name[MAX_PATH];
	DWORD n = GetModuleFileNameA(mod, name, sizeof name);
	ss_ path(name, n);
	size_t slash = path.find_last_of("\\/");
	return slash == ss_::npos ? path : path.substr(slash + 1);
}

typedef BOOL (WINAPI *SymInitialize_t)(HANDLE, PCSTR, BOOL);
typedef BOOL (WINAPI *StackWalk64_t)(DWORD, HANDLE, HANDLE, LPSTACKFRAME64,
		PVOID, PREAD_PROCESS_MEMORY_ROUTINE64, PFUNCTION_TABLE_ACCESS_ROUTINE64,
		PGET_MODULE_BASE_ROUTINE64, PTRANSLATE_ADDRESS_ROUTINE64);
typedef BOOL (WINAPI *SymFromAddr_t)(HANDLE, DWORD64, PDWORD64, PSYMBOL_INFO);

static void log_stack(CONTEXT *ctx)
{
	HMODULE dbghelp = LoadLibraryA("dbghelp.dll");
	if(!dbghelp){
		log_e(MODULE, "  (no dbghelp.dll; no backtrace)");
		return;
	}
	SymInitialize_t sym_init = (SymInitialize_t)GetProcAddress(dbghelp, "SymInitialize");
	StackWalk64_t walk = (StackWalk64_t)GetProcAddress(dbghelp, "StackWalk64");
	SymFromAddr_t from_addr = (SymFromAddr_t)GetProcAddress(dbghelp, "SymFromAddr");
	PFUNCTION_TABLE_ACCESS_ROUTINE64 table_access =
			(PFUNCTION_TABLE_ACCESS_ROUTINE64)GetProcAddress(dbghelp, "SymFunctionTableAccess64");
	PGET_MODULE_BASE_ROUTINE64 module_base =
			(PGET_MODULE_BASE_ROUTINE64)GetProcAddress(dbghelp, "SymGetModuleBase64");
	if(!sym_init || !walk || !table_access || !module_base){
		log_e(MODULE, "  (dbghelp without StackWalk64; no backtrace)");
		return;
	}
	HANDLE process = GetCurrentProcess();
	sym_init(process, NULL, TRUE);
	CONTEXT c = *ctx;
	STACKFRAME64 frame;
	memset(&frame, 0, sizeof frame);
#ifdef _M_X64
	DWORD machine = IMAGE_FILE_MACHINE_AMD64;
	// A call through a null pointer faults with the PC at 0 and the
	// return address the call pushed untouched at [RSP]: the walk starts
	// from that caller instead, with the stack popped past it, since a
	// PC of 0 ends a walk before its first frame ([WIN8_START] 13). The
	// raw [RSP] is logged regardless, as the one number that names the
	// caller when the walk itself gives nothing.
	{
		uint64_t ret = 0;
		if(c.Rsp && !IsBadReadPtr((const void*)(uintptr_t)c.Rsp, sizeof ret))
			ret = *(const uint64_t*)(uintptr_t)c.Rsp;
		log_e(MODULE, "  [rsp] = %p (%s)", (void*)(uintptr_t)ret,
				cs(module_of_address((void*)(uintptr_t)ret)));
		if(c.Rip == 0 && ret != 0){
			log_e(MODULE, "  the PC is 0: a call through a null pointer; "
					"the walk starts from the caller");
			c.Rip = ret;
			c.Rsp += sizeof ret;
		}
	}
	frame.AddrPC.Offset = c.Rip;
	frame.AddrFrame.Offset = c.Rbp;
	frame.AddrStack.Offset = c.Rsp;
#else
	DWORD machine = IMAGE_FILE_MACHINE_I386;
	frame.AddrPC.Offset = c.Eip;
	frame.AddrFrame.Offset = c.Ebp;
	frame.AddrStack.Offset = c.Esp;
#endif
	frame.AddrPC.Mode = AddrModeFlat;
	frame.AddrFrame.Mode = AddrModeFlat;
	frame.AddrStack.Mode = AddrModeFlat;
	char symbol_buf[sizeof(SYMBOL_INFO) + 256];
	for(int i = 0; i < 40; i++){
		if(!walk(machine, process, GetCurrentThread(), &frame, &c, NULL,
				table_access, module_base, NULL))
			break;
		if(frame.AddrPC.Offset == 0)
			break;
		void *address = (void*)(uintptr_t)frame.AddrPC.Offset;
		const char *name = "?";
		if(from_addr){
			SYMBOL_INFO *symbol = (SYMBOL_INFO*)symbol_buf;
			memset(symbol_buf, 0, sizeof symbol_buf);
			symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
			symbol->MaxNameLen = 255;
			DWORD64 displacement = 0;
			if(from_addr(process, frame.AddrPC.Offset, &displacement, symbol))
				name = symbol->Name;
		}
		log_e(MODULE, "  #%d %p %s (%s)", i, address, name,
				cs(module_of_address(address)));
	}
}

// The watched thread's handle and the time it last said so; the watcher
// suspends it, walks its stack from its context, and lets it go on
static HANDLE g_watched_thread = NULL;
static volatile LONG64 g_watched_alive_us = 0;
static int g_watchdog_stall_s = 10;

static DWORD WINAPI watchdog_main(LPVOID)
{
	int64_t stalled_since = 0;
	int64_t next_report = 0;
	for(;;){
		Sleep(1000);
		const int64_t now = (int64_t)GetTickCount64() * 1000;
		const int64_t alive = g_watched_alive_us;
		if(now - alive < (int64_t)g_watchdog_stall_s * 1000000){
			stalled_since = 0;
			continue;
		}
		if(stalled_since == 0){
			stalled_since = alive;
			next_report = now;
		}
		if(now < next_report)
			continue;
		next_report = now + 60000000;
		log_e(MODULE, "Watchdog: no frame for %d s; the main thread's stack:",
				(int)((now - alive) / 1000000));
		if(SuspendThread(g_watched_thread) == (DWORD)-1){
			log_e(MODULE, "  (SuspendThread failed)");
			continue;
		}
		CONTEXT ctx;
		memset(&ctx, 0, sizeof ctx);
		ctx.ContextFlags = CONTEXT_FULL;
		if(GetThreadContext(g_watched_thread, &ctx))
			log_stack(&ctx);
		else
			log_e(MODULE, "  (GetThreadContext failed)");
		ResumeThread(g_watched_thread);
	}
	return 0;
}

static LONG WINAPI unhandled_exception(EXCEPTION_POINTERS *e)
{
	static volatile LONG active = 0;
	if(InterlockedIncrement(&active) != 1)
		ExitProcess(1);
	log_disable_bloat();
	EXCEPTION_RECORD *r = e->ExceptionRecord;
	void *address = r->ExceptionAddress;
	log_e(MODULE, "Crash: %s (0x%08lx) at %p in %s",
			exception_name(r->ExceptionCode), (unsigned long)r->ExceptionCode,
			address, cs(module_of_address(address)));
	if(r->ExceptionCode == EXCEPTION_ACCESS_VIOLATION &&
			r->NumberParameters >= 2)
		log_e(MODULE, "  %s address %p",
				r->ExceptionInformation[0] == 0 ? "reading" :
				r->ExceptionInformation[0] == 1 ? "writing" : "executing",
				(void*)(uintptr_t)r->ExceptionInformation[1]);
	log_stack(e->ContextRecord);
	log_close();
	ExitProcess(1);
	return EXCEPTION_EXECUTE_HANDLER;
}

void init_signal_handlers(const SigConfig &config)
{
	if(config.catch_segfault)
		SetUnhandledExceptionFilter(unhandled_exception);
}

// simplified: the Linux watchdog's interrupt is not here; a frozen
// thread is logged and left alone
void watchdog_on_freeze(void (*f)()){}

void watchdog_alive(int stall_seconds)
{
	g_watched_alive_us = (LONG64)GetTickCount64() * 1000;
	// Every call, so a screen may lower it for its own stay
	g_watchdog_stall_s = stall_seconds;
	if(g_watched_thread)
		return;
	DuplicateHandle(GetCurrentProcess(), GetCurrentThread(),
			GetCurrentProcess(), &g_watched_thread, 0, FALSE,
			DUPLICATE_SAME_ACCESS);
	HANDLE t = CreateThread(NULL, 0, watchdog_main, NULL, 0, NULL);
	if(t)
		CloseHandle(t);
	log_i(MODULE, "Watchdog: the main thread's stack is logged after %d s "
			"without a frame", stall_seconds);
}

}
}
// vim: set noet ts=4 sw=4:
