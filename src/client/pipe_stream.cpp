// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [PROCESS_SANDBOX] B 2: the client reaches a local server boxed in an
// AppContainer by a named pipe, since loopback to the box is blocked. The
// pipe carries the byte stream a TCP socket would; this is the stream
// behind client::State's Wss interface, as TLS is.
#ifdef _WIN32
#include "client/wss.h"
#include "core/log.h"
#ifndef _WIN32_WINNT
	#define _WIN32_WINNT 0x0A00
#endif
#include "ports/windows_minimal.h"
#include <userenv.h>
#include <sddl.h>
#undef interface
#include <algorithm>
#define MODULE "pipe"

namespace client {

struct CPipeStream: public Wss
{
	HANDLE m_pipe = INVALID_HANDLE_VALUE;

	~CPipeStream()
	{
		if(m_pipe != INVALID_HANDLE_VALUE)
			CloseHandle(m_pipe);
	}

	// host is the pipe's full path
	ss_ start(const ss_ &path, const ss_ &, const ss_ &)
	{
		m_pipe = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
				nullptr, OPEN_EXISTING, 0, nullptr);
		if(m_pipe == INVALID_HANDLE_VALUE)
			return "the server's pipe "+path+" did not open ("+
					itos((int)GetLastError())+")";
		// Reads answer at once, as a non-blocking socket's do
		DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
		SetNamedPipeHandleState(m_pipe, &mode, nullptr, nullptr);
		return "";
	}

	bool send(const ss_ &data)
	{
		size_t at = 0;
		while(at < data.size()){
			// A piece that fits the pipe's buffer, as the server's side
			const DWORD piece = (DWORD)std::min<size_t>(data.size() - at, 16384);
			DWORD n = 0;
			if(!WriteFile(m_pipe, &data[at], piece, &n, nullptr))
				return false;
			at += n;
			if(n == 0)
				Sleep(1);
		}
		return true;
	}

	int read(ss_ &out, ss_ *why)
	{
		char buf[100000];
		DWORD n = 0;
		if(ReadFile(m_pipe, buf, sizeof buf, &n, nullptr)){
			out.append(buf, n);
			return (int)n;
		}
		const DWORD e = GetLastError();
		if(e == ERROR_NO_DATA)
			return 0;
		*why = "the server closed the pipe ("+itos((int)e)+")";
		return -1;
	}

	// Polled: a pipe has no socket for the select
	bool pending()
	{
		return true;
	}
};

Wss* create_pipe_stream()
{
	return new CPipeStream();
}

ss_ local_server_pipe(const ss_ &app, const ss_ &port)
{
	// Wine's way: an unboxed server asked for a pipe makes it outside any
	// container's namespace
	const char *plain = getenv("BUILDAT_PIPE");
	if(plain && ss_(plain) == "1")
		return "\\\\.\\pipe\\buildat-"+port;
	// A server started unboxed listens on loopback as before: by
	// --unconfined, or while the Windows box is opt-in
	// (src/server/confine_windows.cpp)
	const char *unconfined = getenv("BUILDAT_UNCONFINED");
	const char *box = getenv("BUILDAT_WINDOWS_BOX");
	if((unconfined && ss_(unconfined) == "1") || !box || ss_(box) != "1")
		return "";
	const ss_ name_a = "buildat."+app;
	std::wstring name(name_a.begin(), name_a.end());
	PSID sid = nullptr;
	if(FAILED(DeriveAppContainerSidFromAppContainerName(name.c_str(), &sid)))
		return "";
	char *sid_s = nullptr;
	ConvertSidToStringSidA(sid, &sid_s);
	FreeSid(sid);
	DWORD session = 0;
	ProcessIdToSessionId(GetCurrentProcessId(), &session);
	const ss_ path = "\\\\.\\pipe\\Sessions\\"+itos((int)session)+
			"\\AppContainerNamedObjects\\"+(sid_s ? sid_s : "")+
			"\\buildat-"+port;
	LocalFree(sid_s);
	return path;
}

bool pipe_ready(const ss_ &path)
{
	// An instance waiting, without connecting to it: a probe connect is a
	// peer to the server ([WIN8_START] 11)
	return WaitNamedPipeA(path.c_str(), 1) != 0;
}

}
#else
#include "client/wss.h"
namespace client {
ss_ local_server_pipe(const ss_ &, const ss_ &){ return ""; }
bool pipe_ready(const ss_ &){ return false; }
}
#endif
// vim: set noet ts=4 sw=4:
