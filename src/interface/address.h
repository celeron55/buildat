// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [REWORK_FIXES] Host, port and URL parsing in one place: "host",
// "host:port", "[v6]", "[v6]:port" and a bare v6 ("::1", no port), and
// "scheme://hostport/path". Checked by util/address_check.sh.
#pragma once
#include "core/types.h"
#include <cctype>
#include <cstdlib>

namespace interface
{
	// `a` into a host (v6 without its brackets) and a port, `def` when it
	// has none. False for an empty host, an unclosed bracket, or a port
	// that is not 1 to 65535 in digits.
	inline bool split_host_port(const ss_ &a, ss_ *host, ss_ *port,
			const ss_ &def)
	{
		ss_ h, p;
		if(!a.empty() && a[0] == '['){
			const size_t close = a.find(']');
			if(close == ss_::npos)
				return false;
			h = a.substr(1, close - 1);
			if(close + 1 < a.size()){
				if(a[close + 1] != ':')
					return false;
				p = a.substr(close + 2);
			}
		} else {
			const size_t colon = a.find(':');
			// More than one colon without brackets is a bare v6 address
			if(colon != ss_::npos && a.find(':', colon + 1) == ss_::npos){
				h = a.substr(0, colon);
				p = a.substr(colon + 1);
			} else {
				h = a;
			}
		}
		if(p.empty())
			p = def;
		if(h.empty())
			return false;
		if(!p.empty()){
			if(p.size() > 5)
				return false;
			for(char c : p)
				if(!isdigit((unsigned char)c))
					return false;
			const long n = atol(p.c_str());
			if(n < 1 || n > 65535)
				return false;
		}
		*host = h;
		*port = p;
		return true;
	}

	// The host and port as an address is written: a v6 host in brackets
	inline ss_ join_host_port(const ss_ &host, const ss_ &port)
	{
		const ss_ h = host.find(':') != ss_::npos ? "["+host+"]" : host;
		return port.empty() ? h : h+":"+port;
	}

	struct Url
	{
		ss_ scheme; // lower case, without "://"
		ss_ host;   // v6 without its brackets
		ss_ port;   // the scheme's default when the URL has none
		ss_ path;   // from the first '/', or ""
		bool port_given = false;
	};

	// "scheme://hostport[/path]"; http and ws default to 80, https and wss
	// to 443, any other scheme to `def_port`
	inline bool parse_url(const ss_ &u, Url *out, const ss_ &def_port = "")
	{
		const size_t at = u.find("://");
		if(at == ss_::npos || at == 0)
			return false;
		Url r;
		r.scheme = u.substr(0, at);
		for(char &c : r.scheme)
			c = tolower((unsigned char)c);
		const ss_ rest = u.substr(at + 3);
		const size_t slash = rest.find('/');
		const ss_ hostport = rest.substr(0, slash);
		r.path = slash == ss_::npos ? "" : rest.substr(slash);
		const ss_ def = r.scheme == "http" || r.scheme == "ws" ? "80" :
				r.scheme == "https" || r.scheme == "wss" ? "443" : def_port;
		ss_ given;
		if(!split_host_port(hostport, &r.host, &given, ""))
			return false;
		r.port_given = !given.empty();
		r.port = r.port_given ? given : def;
		*out = r;
		return true;
	}
}
