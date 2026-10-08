// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "server/config.h"

#include <cctype>

namespace interface
{
	typedef server::Config ServerConfig;

	// One key of what an untrusted launcher asked for through the server's
	// -u ([LAUNCH_GRID]), u being those key=value lines: read as a packet
	// would be -- a value of a directory name's shape, 1 to 64 letters,
	// digits, '_' and '-' -- or "", and *refused set when the key was
	// there and its value was not. A key found inside another
	// ("xsave=" for "save=") is passed over, not taken as absent.
	inline ss_ launch_param(const ss_ &u, const ss_ &key_name,
			bool *refused = nullptr)
	{
		if(refused)
			*refused = false;
		const ss_ key = key_name + "=";
		for(size_t at = u.find(key); at != ss_::npos; at = u.find(key, at + 1)){
			if(at != 0 && u[at - 1] != '\n')
				continue;
			ss_ v = u.substr(at + key.size());
			v = v.substr(0, v.find('\n'));
			bool ok = !v.empty() && v.size() <= 64;
			for(char c : v)
				if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
					ok = false;
			if(!ok && refused)
				*refused = true;
			return ok ? v : "";
		}
		return "";
	}
	inline void launch_param_self_check()
	{
		if(launch_param("xsave=a\nsave=b", "save") != "b" ||
				launch_param("save=a/b", "save") != "" ||
				launch_param("a=1\nb=2", "b") != "2" ||
				launch_param("b=", "b") != "" ||
				launch_param("menu=worlds", "save") != "")
			throw Exception("launch_param self-check");
	}
}
// vim: set noet ts=4 sw=4:
