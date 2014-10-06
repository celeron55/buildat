// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#ifndef WIN32_LEAN_AND_MEAN
	#define WIN32_LEAN_AND_MEAN
#endif
// Without this some of the network functions are not found on mingw
#ifndef _WIN32_WINNT
	#define _WIN32_WINNT 0x0501
#endif
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#ifdef _MSC_VER
	#pragma comment(lib, "ws2_32.lib")
#endif
// What the fuck, windows.h does #define interface struct
#undef interface
//typedef SOCKET socket_t;
typedef int socklen_t;
// vim: set noet ts=4 sw=4:
