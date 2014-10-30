// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/debug.h"
#include "core/log.h"
#include <c55/string_util.h>
#include <stdexcept>
#include <iostream>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <execinfo.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <unistd.h>
#define MODULE "debug"

namespace interface {
namespace debug {

// Execute a program and return whatever it writes to stdout
static ss_ exec_get_stdout(char *cmd)
{
	FILE* pipe = popen(cmd, "r");
	if(!pipe) return "ERROR";
	char buffer[50];
	ss_ result;
	try{
		while(!feof(pipe)){
			if(fgets(buffer, 50, pipe) != NULL)
				result += buffer; // Can cause std::bad_alloc
		}
		pclose(pipe);
		return result;
	}catch(std::bad_alloc){
		return ss_();
	}
}

// Execute a program and return whatever it writes to stdout, without trailing
// newline
static ss_ exec_get_stdout_without_newline(char *cmd)
{
	ss_ s = exec_get_stdout(cmd);
	if(!s.empty() && s[s.size()-1] == '\n')
		s = s.substr(0, s.size()-1);
	return s;
}

static void* get_library_executable_address(const ss_ &lib_path)
{
	char cmdbuf[500];
	snprintf(cmdbuf, sizeof cmdbuf,
			"cat /proc/%i/maps | grep %s | grep ' ..x. ' | cut -d- -f1",
			getpid(), cs(lib_path));
	ss_ address_s = exec_get_stdout_without_newline(cmdbuf);
	//log_v(MODULE, "address_s=\"%s\"", cs(address_s));
	if(address_s.empty())
		return (void*)0x0;
	void *address = (void*)strtoul(address_s.c_str(), NULL, 16);
	return address;
}

//#define __USE_GNU
#include <ucontext.h> // REG_EIP (or REG_RIP)

#if __WORDSIZE == 64 // REG_RIP replaces REG_EIP on x86_64
	#define REG_EIP REG_RIP
#endif

static void log_backtrace(void* const *trace, int trace_size, const ss_ &title);

static void debug_sighandler(int sig, siginfo_t *info, void *secret)
{
	ucontext_t *uc = (ucontext_t*)secret;
	log_i(MODULE, " ");
	if(sig == SIGSEGV)
		log_w(MODULE, "Crash: SIGSEGV: Address %p (executing %p)",
				info->si_addr, (void*)uc->uc_mcontext.gregs[REG_EIP]);
	else
		log_w(MODULE, "Crash: Signal %d", sig);

	void *trace[16];
	int trace_size = backtrace(trace, 16);
	// Overwrite sigaction with caller's address
	trace[1] = (void*) uc->uc_mcontext.gregs[REG_EIP];

	log_backtrace(trace, trace_size, "Backtrace for signal:");

	exit(1);
}

void init_signal_handlers(const SigConfig &config)
{
	struct sigaction sa;
	sa.sa_sigaction = debug_sighandler;
	sigemptyset (&sa.sa_mask);
	sa.sa_flags = SA_RESTART | SA_SIGINFO;

	if(config.catch_segfault)
		sigaction(SIGSEGV, &sa, NULL);
	if(config.catch_abort)
		sigaction(SIGABRT, &sa, NULL);
}

static std::atomic_int log_backtrace_spinlock(0);
static char backtrace_buffer[10000];
static size_t backtrace_buffer_len = 0;

static void bt_print(const char *fmt, ...)
{
	va_list va_args;
	va_start(va_args, fmt);
	backtrace_buffer_len += vsnprintf(
			backtrace_buffer + backtrace_buffer_len,
			sizeof backtrace_buffer - backtrace_buffer_len,
			fmt, va_args);
	va_end(va_args);
	backtrace_buffer_len += snprintf(
			backtrace_buffer + backtrace_buffer_len,
			sizeof backtrace_buffer - backtrace_buffer_len,
			"\n");
}

static void log_backtrace(void* const *trace, int trace_size, const ss_ &title)
{
	char **symbols = backtrace_symbols(trace, trace_size);

	// Lock spinlock
	for(;;){
		int previous_value = log_backtrace_spinlock.fetch_add(1);
		if(previous_value == 0)
			break;
		log_backtrace_spinlock--;
	}

	// The first stack frame points to this functiton
	backtrace_buffer_len = 0;
	bt_print("\n  %s", cs(title));
	for(int i = 1; i < trace_size; i++){
		char cmdbuf[500];
		// Parse symbol to get file name
		// Example: "../cache/rccpp_build/main.so(+0x14e2c) [0x7f7880d36e2c]"
		//log_v(MODULE, "symbol: %s", symbols[i]);
		c55::Strfnd f(symbols[i]);
		ss_ file_path = f.next("(");
		//log_v(MODULE, "file_path: %s", cs(file_path));

		void *address = trace[i];

		bool is_shared_lib = (file_path.find(".so") != ss_::npos);
		//log_v(MODULE, "is_shared_lib=%s", is_shared_lib?"true":"false");
		if(is_shared_lib){
			void *base_addr = get_library_executable_address(file_path);
			//log_v(MODULE, "base_addr=%p", base_addr);
			address = (void*)((char*)trace[i] - (char*)base_addr);
			//log_v(MODULE, "address=%p", address);
		}

		snprintf(cmdbuf, sizeof cmdbuf, "echo '%s' | c++filt", symbols[i]);
		ss_ cppfilt_symbol = exec_get_stdout_without_newline(cmdbuf);

		snprintf(cmdbuf, sizeof cmdbuf, "addr2line %p -e %s",
				address, cs(file_path));
		ss_ addr2line_output = exec_get_stdout_without_newline(cmdbuf);

		if(addr2line_output.size() > 4){
			bt_print("    #%i  %s", i-1, cs(addr2line_output));
			log_d(MODULE, "    = %s", cs(cppfilt_symbol));
		} else {
			bt_print("    #%i  %s", i-1, cs(cppfilt_symbol));
		}
	}

	// Print to log
	backtrace_buffer[sizeof backtrace_buffer - 1] = 0;
	log_i(MODULE, "%s", backtrace_buffer);

	// Unlock spinlock
	log_backtrace_spinlock--;
}

void log_current_backtrace(const ss_ &title)
{
	void *trace[16];
	int trace_size = backtrace(trace, 16);

	log_backtrace(trace, trace_size, title);
}

#include <cxxabi.h>
#include <dlfcn.h>

static void *last_exception_frames[16];
static int last_exception_num_frames = 0;
static ss_ last_exception_name;

// GCC-specific
static ss_ demangle(const char *name)
{
	int status;
	std::unique_ptr<char,void(*)(void*)>
			realname(abi::__cxa_demangle(name, 0, 0, &status), &std::free);
	return status ? "failed" : &*realname;
}

// GCC-specific
extern "C" {
	void __cxa_throw(void *ex, void *info, void (*dest)(void *)) {
		last_exception_name = demangle(
				reinterpret_cast<const std::type_info*>(info)->name());
		last_exception_num_frames = backtrace(last_exception_frames,
				sizeof last_exception_frames / sizeof(void*));

		static void (*const rethrow)(void*,void*,void(*)(void*))
		__attribute__((noreturn)) = (void (*)(void*,void*,void(*)(void*)))
				dlsym(RTLD_NEXT, "__cxa_throw");
		rethrow(ex,info,dest);
	}
}

void log_exception_backtrace(const ss_ &title)
{
	log_backtrace(last_exception_frames, last_exception_num_frames, title);
}

}
}
// vim: set noet ts=4 sw=4:
