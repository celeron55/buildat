// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [PROCESS_SANDBOX] on Windows, the first thing to prove: can a process in
// an AppContainer reach, and be reached from, an unboxed process on the
// same machine over loopback -- the client joining its own local server --
// without admin? And if not, does a named pipe work instead?
//
// Run as a normal user from a command prompt; paste back what it prints.
// It makes an AppContainer profile, starts a copy of itself in it, runs the
// tests from both sides, prints one line a test, and deletes the profile.
//
// With --listen, the second question: can another machine reach a listener
// in the box (a public server)? The boxed copy listens on every interface
// on PORT_LISTEN and the unboxed parent on PORT_CONTROL beside it, so a
// connection that reaches the parent and not the box is the box's doing
// and not the firewall's. Both wait LISTEN_SECONDS for a connection.
//
// Built by util/build_appcontainer_probe.sh (mingw-w64, static).
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <userenv.h>
#include <sddl.h>
#include <aclapi.h>
#include <shlobj.h>
#include <cstdio>
#include <cstring>
#include <string>

static const wchar_t *PROFILE = L"buildat.appcontainer_probe";
static const int PORT_BOX = 29961;    // The boxed copy listens here
static const int PORT_PARENT = 29962; // The parent listens here
static const int PORT_LISTEN = 29963; // --listen: the box, every interface
static const int PORT_CONTROL = 29964; // --listen: the parent, beside it
static const int LISTEN_SECONDS = 600;

static std::string err(DWORD e)
{
	char buf[300] = {0};
	FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
			nullptr, e, 0, buf, sizeof buf, nullptr);
	std::string s = buf;
	while(!s.empty() && (s.back() == '\n' || s.back() == '\r'))
		s.pop_back();
	return std::to_string(e) + " " + s;
}

static void line(const char *who, const char *what, bool ok, const std::string &why)
{
	printf("%s: %-46s %s%s%s\n", who, what, ok ? "ok" : "FAILED",
			why.empty() ? "" : " -- ", why.c_str());
	fflush(stdout);
}

// What the box must not do: refused is the pass
static void refused(const char *who, const char *what, bool got_through,
		const std::string &why)
{
	printf("%s: %-46s %s%s%s\n", who, what,
			got_through ? "GOT THROUGH" : "refused",
			why.empty() ? "" : " -- ", why.c_str());
	fflush(stdout);
}

// A TCP connect with a timeout; "" or why not
static std::string tcp_connect(const char *host, int port, int timeout_ms)
{
	addrinfo hints = {}, *res = nullptr;
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	char ps[16];
	snprintf(ps, sizeof ps, "%d", port);
	if(getaddrinfo(host, ps, &hints, &res) != 0)
		return "resolving: " + err(WSAGetLastError());
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	u_long nb = 1;
	ioctlsocket(s, FIONBIO, &nb);
	connect(s, res->ai_addr, (int)res->ai_addrlen);
	freeaddrinfo(res);
	fd_set w, e;
	FD_ZERO(&w); FD_SET(s, &w);
	FD_ZERO(&e); FD_SET(s, &e);
	timeval tv = {timeout_ms / 1000, (timeout_ms % 1000) * 1000};
	int r = select(0, nullptr, &w, &e, &tv);
	std::string why;
	if(r == 0){
		why = "timed out";
	} else if(FD_ISSET(s, &e)){
		int so = 0, len = sizeof so;
		getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&so, &len);
		why = err(so);
	}
	closesocket(s);
	return why;
}

static SOCKET tcp_listen(int port, std::string *why, bool any = false)
{
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	sockaddr_in a = {};
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	a.sin_addr.s_addr = htonl(any ? INADDR_ANY : INADDR_LOOPBACK);
	if(bind(s, (sockaddr*)&a, sizeof a) != 0 || listen(s, 4) != 0){
		*why = err(WSAGetLastError());
		closesocket(s);
		return INVALID_SOCKET;
	}
	return s;
}

// "" or why not; *from gets the peer's address, and the peer a line
static std::string tcp_accept(SOCKET l, int timeout_ms, std::string *from = nullptr)
{
	fd_set r;
	FD_ZERO(&r); FD_SET(l, &r);
	timeval tv = {timeout_ms / 1000, (timeout_ms % 1000) * 1000};
	if(select(0, &r, nullptr, nullptr, &tv) <= 0)
		return "nothing came in " + std::to_string(timeout_ms / 1000) + " s";
	sockaddr_in peer = {};
	int plen = sizeof peer;
	SOCKET c = accept(l, (sockaddr*)&peer, &plen);
	if(c == INVALID_SOCKET)
		return err(WSAGetLastError());
	if(from){
		char ip[INET_ADDRSTRLEN] = {0};
		inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof ip);
		*from = std::string(ip) + ":" + std::to_string(ntohs(peer.sin_port));
		const char *hello = "appcontainer_probe: you got through\n";
		send(c, hello, (int)strlen(hello), 0);
	}
	closesocket(c);
	return "";
}

// --listen in the box: one connection from anywhere, or the time is up
static int child_listen()
{
	const char *who = "boxed";
	std::string why;
	SOCKET l = tcp_listen(PORT_LISTEN, &why, true);
	line(who, ("listen on every interface, port " +
			std::to_string(PORT_LISTEN)).c_str(), l != INVALID_SOCKET, why);
	if(l != INVALID_SOCKET){
		std::string from;
		why = tcp_accept(l, LISTEN_SECONDS * 1000, &from);
		line(who, "a connection from outside came in", why.empty(),
				why.empty() ? "from " + from : why);
		closesocket(l);
	}
	printf("DONE\n");
	fflush(stdout);
	return 0;
}

// --listen's control, in the parent, on its own thread
static DWORD WINAPI control_listen(void *)
{
	const char *who = "unboxed";
	std::string why;
	SOCKET l = tcp_listen(PORT_CONTROL, &why, true);
	line(who, ("control: listen on every interface, port " +
			std::to_string(PORT_CONTROL)).c_str(), l != INVALID_SOCKET, why);
	if(l != INVALID_SOCKET){
		std::string from;
		why = tcp_accept(l, LISTEN_SECONDS * 1000, &from);
		line(who, "control: a connection from outside came in", why.empty(),
				why.empty() ? "from " + from : why);
		closesocket(l);
	}
	return 0;
}

// The real version: GetVersionEx says 6.2 to a program with no manifest
static std::string windows_version()
{
	typedef LONG (WINAPI *RtlGetVersion_t)(OSVERSIONINFOW*);
	RtlGetVersion_t f = (RtlGetVersion_t)(void*)GetProcAddress(
			GetModuleHandleA("ntdll.dll"), "RtlGetVersion");
	OSVERSIONINFOW v = {sizeof v};
	if(!f || f(&v) != 0)
		return "unknown";
	return std::to_string(v.dwMajorVersion) + "." +
			std::to_string(v.dwMinorVersion) + " build " +
			std::to_string(v.dwBuildNumber);
}

// The Documents folder where it really is (it may be in OneDrive)
static std::wstring documents_path()
{
	PWSTR p = nullptr;
	std::wstring s;
	if(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &p)))
		s = p;
	CoTaskMemFree(p);
	return s;
}

static std::string narrow(const std::wstring &w)
{
	std::string s;
	for(wchar_t c : w)
		s += c < 128 ? (char)c : '?';
	return s;
}

static std::string list_dir(const std::wstring &dir, bool *listed)
{
	WIN32_FIND_DATAW fd;
	HANDLE fh = FindFirstFileW((dir + L"\\*").c_str(), &fd);
	*listed = fh != INVALID_HANDLE_VALUE;
	if(!*listed)
		return err(GetLastError());
	FindClose(fh);
	return "";
}

// The boxed copy. Its stdout is a pipe the parent reads, line by line.
static int child(const std::wstring &docs)
{
	const char *who = "boxed";
	std::string why;
	// 1. Listen; the parent connects when it reads READY
	SOCKET l = tcp_listen(PORT_BOX, &why);
	line(who, "listen on 127.0.0.1", l != INVALID_SOCKET, why);
	printf("READY\n");
	fflush(stdout);
	if(l != INVALID_SOCKET){
		why = tcp_accept(l, 10000);
		line(who, "accept the unboxed parent's connection", why.empty(), why);
		closesocket(l);
	}
	// 2. Connect to the parent's listener
	why = tcp_connect("127.0.0.1", PORT_PARENT, 5000);
	line(who, "connect to the unboxed parent", why.empty(), why);
	// 3. Named pipes, made here with a DACL for everyone and every app
	// container; the parent opens them when it reads PIPE
	for(const char *name : {"\\\\.\\pipe\\buildat_probe",
			"\\\\.\\pipe\\LOCAL\\buildat_probe"}){
		SECURITY_ATTRIBUTES sa = {sizeof sa, nullptr, FALSE};
		ConvertStringSecurityDescriptorToSecurityDescriptorA(
				"D:(A;;GA;;;WD)(A;;GA;;;AC)S:(ML;;NW;;;LW)", SDDL_REVISION_1,
				&sa.lpSecurityDescriptor, nullptr);
		HANDLE p = CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX |
				FILE_FLAG_OVERLAPPED, PIPE_TYPE_BYTE, 1, 512, 512, 0, &sa);
		line(who, (std::string("make pipe ") + name).c_str(),
				p != INVALID_HANDLE_VALUE,
				p == INVALID_HANDLE_VALUE ? err(GetLastError()) : "");
		if(p == INVALID_HANDLE_VALUE)
			continue;
		printf("PIPE %s\n", name);
		fflush(stdout);
		OVERLAPPED ov = {};
		ov.hEvent = CreateEventA(nullptr, TRUE, FALSE, nullptr);
		BOOL c = ConnectNamedPipe(p, &ov);
		DWORD e = GetLastError();
		bool ok = c || e == ERROR_PIPE_CONNECTED ||
				(e == ERROR_IO_PENDING &&
					WaitForSingleObject(ov.hEvent, 10000) == WAIT_OBJECT_0);
		line(who, "the parent opened that pipe", ok, ok ? "" : "nothing in 10 s");
		CloseHandle(p);
	}
	// 4. The world: the capabilities at work
	why = tcp_connect("example.com", 80, 5000);
	line(who, "connect to example.com:80", why.empty(), why);
	// 5. What the box must refuse
	wchar_t prof[MAX_PATH] = {0};
	SHGetFolderPathW(nullptr, CSIDL_PROFILE, nullptr, 0, prof);
	std::wstring f = std::wstring(prof) + L"\\buildat_probe_was_here.txt";
	HANDLE h = CreateFileW(f.c_str(), GENERIC_WRITE, 0, nullptr,
			CREATE_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE, nullptr);
	refused(who, "write a file in your profile",
			h != INVALID_HANDLE_VALUE, h == INVALID_HANDLE_VALUE ?
				err(GetLastError()) : "it wrote one (removed again)");
	if(h != INVALID_HANDLE_VALUE)
		CloseHandle(h);
	// The parent's path, which the parent listed first as the control
	bool listed = false;
	std::string lwhy = docs.empty() ? "no path given" : list_dir(docs, &listed);
	refused(who, "list your Documents", listed,
			listed ? "it listed it" : lwhy);
	bool clip = false;
	std::string clip_why;
	if(OpenClipboard(nullptr)){
		clip = GetClipboardData(CF_UNICODETEXT) != nullptr;
		clip_why = clip ? "it read the clipboard" : err(GetLastError());
		CloseClipboard();
	} else {
		clip_why = err(GetLastError());
	}
	refused(who, "read the clipboard", clip, clip_why);
	printf("DONE\n");
	fflush(stdout);
	return 0;
}

static bool read_line(HANDLE h, std::string *out)
{
	out->clear();
	char c;
	DWORD n;
	while(ReadFile(h, &c, 1, &n, nullptr) && n == 1){
		if(c == '\n')
			return true;
		if(c != '\r')
			*out += c;
	}
	return !out->empty();
}

// --run <container> <command line>: the command in that AppContainer
// (made if missing), with the three network capabilities and the
// caller's directory, its output here -- for reading what a boxed
// server's tools see ([PROCESS_SANDBOX] B)
static int run_in(const char *container, const char *cmdline)
{
	std::wstring name(container, container + strlen(container));
	PSID sid = nullptr;
	HRESULT hr = CreateAppContainerProfile(name.c_str(), name.c_str(),
			name.c_str(), nullptr, 0, &sid);
	if(hr == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS))
		hr = DeriveAppContainerSidFromAppContainerName(name.c_str(), &sid);
	if(FAILED(hr)){
		printf("run: no container (HRESULT %u)\n", (unsigned)hr);
		return 1;
	}
	SID_AND_ATTRIBUTES caps[3];
	BYTE cap_sid[3][SECURITY_MAX_SID_SIZE];
	WELL_KNOWN_SID_TYPE kinds[3] = {WinCapabilityInternetClientSid,
			WinCapabilityInternetClientServerSid,
			WinCapabilityPrivateNetworkClientServerSid};
	for(int i = 0; i < 3; i++){
		DWORD size = SECURITY_MAX_SID_SIZE;
		CreateWellKnownSid(kinds[i], nullptr, cap_sid[i], &size);
		caps[i].Sid = cap_sid[i];
		caps[i].Attributes = SE_GROUP_ENABLED;
	}
	SECURITY_CAPABILITIES sc = {};
	sc.AppContainerSid = sid;
	sc.Capabilities = caps;
	sc.CapabilityCount = 3;
	STARTUPINFOEXA si = {};
	si.StartupInfo.cb = sizeof si;
	SIZE_T attr_size = 0;
	InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
	si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
			GetProcessHeap(), 0, attr_size);
	InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size);
	UpdateProcThreadAttribute(si.lpAttributeList, 0,
			PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &sc, sizeof sc,
			nullptr, nullptr);
	std::string cmd = cmdline;
	PROCESS_INFORMATION pi = {};
	if(!CreateProcessA(nullptr, &cmd[0], nullptr, nullptr, TRUE,
			EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr, &si.StartupInfo, &pi)){
		printf("run: CreateProcess: %s\n", err(GetLastError()).c_str());
		return 1;
	}
	WaitForSingleObject(pi.hProcess, INFINITE);
	DWORD code = 1;
	GetExitCodeProcess(pi.hProcess, &code);
	printf("run: exit 0x%08lx\n", (unsigned long)code);
	return 0;
}

int main(int argc, char **argv)
{
	if(argc > 3 && strcmp(argv[1], "--run") == 0)
		return run_in(argv[2], argv[3]);
	WSADATA wsa;
	WSAStartup(MAKEWORD(2, 2), &wsa);
	if(argc > 1 && strcmp(argv[1], "--boxed-listen") == 0)
		return child_listen();
	if(argc > 1 && strcmp(argv[1], "--boxed") == 0){
		// The Documents path, from the parent
		int n = 0;
		LPWSTR *wargv = CommandLineToArgvW(GetCommandLineW(), &n);
		return child(n > 2 ? std::wstring(wargv[2]) : std::wstring());
	}
	const bool listen_mode = argc > 1 && strcmp(argv[1], "--listen") == 0;

	const char *who = "unboxed";
	printf("appcontainer_probe: buildat [PROCESS_SANDBOX]%s; paste all of this back\n",
			listen_mode ? " --listen" : "");
	printf("Windows %s\n", windows_version().c_str());
	DeleteAppContainerProfile(PROFILE);
	PSID sid = nullptr;
	HRESULT hr = CreateAppContainerProfile(PROFILE, PROFILE, PROFILE,
			nullptr, 0, &sid);
	line(who, "make the AppContainer profile", SUCCEEDED(hr),
			SUCCEEDED(hr) ? "" : "HRESULT " + std::to_string((unsigned)hr));
	if(FAILED(hr))
		return 1;
	char *sid_s = nullptr;
	ConvertSidToStringSidA(sid, &sid_s);
	printf("unboxed: the container is %s\n", sid_s);

	// The box has to be able to read and run this file
	wchar_t exe[MAX_PATH];
	GetModuleFileNameW(nullptr, exe, MAX_PATH);
	PACL old_acl = nullptr, new_acl = nullptr;
	PSECURITY_DESCRIPTOR sd = nullptr;
	GetNamedSecurityInfoW(exe, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
			nullptr, nullptr, &old_acl, nullptr, &sd);
	EXPLICIT_ACCESSW ea = {};
	ea.grfAccessPermissions = GENERIC_READ | GENERIC_EXECUTE;
	ea.grfAccessMode = GRANT_ACCESS;
	ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
	ea.Trustee.ptstrName = (LPWSTR)sid;
	SetEntriesInAclW(1, &ea, old_acl, &new_acl);
	DWORD r = SetNamedSecurityInfoW(exe, SE_FILE_OBJECT,
			DACL_SECURITY_INFORMATION, nullptr, nullptr, new_acl, nullptr);
	line(who, "let the box read this .exe", r == ERROR_SUCCESS,
			r == ERROR_SUCCESS ? "" : err(r));

	// The capabilities a server would be given
	SID_AND_ATTRIBUTES caps[3];
	BYTE cap_sid[3][SECURITY_MAX_SID_SIZE];
	WELL_KNOWN_SID_TYPE kinds[3] = {WinCapabilityInternetClientSid,
			WinCapabilityInternetClientServerSid,
			WinCapabilityPrivateNetworkClientServerSid};
	for(int i = 0; i < 3; i++){
		DWORD size = SECURITY_MAX_SID_SIZE;
		CreateWellKnownSid(kinds[i], nullptr, cap_sid[i], &size);
		caps[i].Sid = cap_sid[i];
		caps[i].Attributes = SE_GROUP_ENABLED;
	}
	SECURITY_CAPABILITIES sc = {};
	sc.AppContainerSid = sid;
	sc.Capabilities = caps;
	sc.CapabilityCount = 3;

	std::string why;
	SOCKET pl = INVALID_SOCKET;
	std::wstring docs;
	HANDLE control = nullptr;
	if(listen_mode){
		// Where to connect from the other machine
		char host[256] = {0};
		gethostname(host, sizeof host);
		addrinfo hints = {}, *res = nullptr;
		hints.ai_family = AF_INET;
		if(getaddrinfo(host, nullptr, &hints, &res) == 0){
			for(addrinfo *a = res; a; a = a->ai_next){
				char ip[INET_ADDRSTRLEN] = {0};
				inet_ntop(AF_INET, &((sockaddr_in*)a->ai_addr)->sin_addr,
						ip, sizeof ip);
				printf("unboxed: this machine is %s; connect to %s:%d (the box)"
						" and %s:%d (the control)\n", ip, ip, PORT_LISTEN, ip,
						PORT_CONTROL);
			}
			freeaddrinfo(res);
		}
		printf("unboxed: waiting %d s for both; if the firewall asks, say "
				"what it asked\n", LISTEN_SECONDS);
		fflush(stdout);
		control = CreateThread(nullptr, 0, control_listen, nullptr, 0, nullptr);
	} else {
		pl = tcp_listen(PORT_PARENT, &why);
		line(who, "listen on 127.0.0.1", pl != INVALID_SOCKET, why);
		// The control for the box's Documents test
		docs = documents_path();
		bool listed = false;
		std::string lwhy = docs.empty() ? "no Documents folder" :
				list_dir(docs, &listed);
		line(who, ("control: list " + narrow(docs)).c_str(), listed, lwhy);
	}

	// The box's stdout, to read its lines
	SECURITY_ATTRIBUTES sa = {sizeof sa, nullptr, TRUE};
	HANDLE rd, wr;
	CreatePipe(&rd, &wr, &sa, 0);
	SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
	STARTUPINFOEXW si = {};
	si.StartupInfo.cb = sizeof si;
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdOutput = wr;
	si.StartupInfo.hStdError = wr;
	SIZE_T attr_size = 0;
	InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
	si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
			GetProcessHeap(), 0, attr_size);
	InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size);
	UpdateProcThreadAttribute(si.lpAttributeList, 0,
			PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &sc, sizeof sc,
			nullptr, nullptr);
	std::wstring cmd = std::wstring(L"\"") + exe + L"\"" +
			(listen_mode ? L" --boxed-listen" : L" --boxed \"" + docs + L"\"");
	PROCESS_INFORMATION pi = {};
	BOOL ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, TRUE,
			EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr,
			&si.StartupInfo, &pi);
	line(who, "start a copy of this in the AppContainer", ok,
			ok ? "" : err(GetLastError()));
	CloseHandle(wr);
	if(ok){
		std::string l;
		while(read_line(rd, &l)){
			if(l == "READY"){
				why = tcp_connect("127.0.0.1", PORT_BOX, 5000);
				line(who, "connect to the boxed copy's listener",
						why.empty(), why);
				if(pl != INVALID_SOCKET){
					// The box connects to us next
					why = tcp_accept(pl, 8000);
					line(who, "accept the boxed copy's connection",
							why.empty(), why);
				}
			} else if(l.compare(0, 5, "PIPE ") == 0){
				const std::string name = l.substr(5);
				std::string ns = name;
				// A pipe made in a box is in its own namespace
				if(name.find("\\LOCAL\\") != std::string::npos){
					DWORD session = 0;
					ProcessIdToSessionId(GetCurrentProcessId(), &session);
					ns = "\\\\.\\pipe\\Sessions\\" + std::to_string(session) +
							"\\AppContainerNamedObjects\\" + sid_s + "\\" +
							name.substr(name.find("\\LOCAL\\") + 7);
				}
				for(const std::string &try_name : {name, ns}){
					HANDLE p = CreateFileA(try_name.c_str(),
							GENERIC_READ | GENERIC_WRITE, 0, nullptr,
							OPEN_EXISTING, 0, nullptr);
					line(who, ("open pipe " + try_name).c_str(),
							p != INVALID_HANDLE_VALUE,
							p == INVALID_HANDLE_VALUE ? err(GetLastError()) : "");
					if(p != INVALID_HANDLE_VALUE){
						CloseHandle(p);
						break;
					}
					if(try_name == ns)
						break;
				}
			} else if(l == "DONE"){
				break;
			} else {
				printf("%s\n", l.c_str());
				fflush(stdout);
			}
		}
		// --listen: the control may still be waiting; a minute more for it
		if(control)
			WaitForSingleObject(control, 60000);
		WaitForSingleObject(pi.hProcess, 5000);
		CloseHandle(pi.hProcess);
		CloseHandle(pi.hThread);
	}
	// The profile gone; the .exe keeps the box's read grant, which names a
	// container that no longer exists
	hr = DeleteAppContainerProfile(PROFILE);
	line(who, "delete the AppContainer profile", SUCCEEDED(hr), "");
	return 0;
}
// vim: set noet ts=4 sw=4:
