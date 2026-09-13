// A shim, not Luanti's: see README.txt.
//
// Luanti logs into streams; buildat logs with a level and a module name.
// These are ostreams that end a line into buildat's log.
#pragma once
#include "core/log.h"
#include <sstream>
#include <ostream>
#include <string>

namespace luanti_shim_log {

class LogBuf: public std::stringbuf
{
public:
	LogBuf(int level): m_level(level){}
	int sync(){
		std::string s = str();
		str("");
		while(!s.empty() && (s.back() == '\n' || s.back() == '\r'))
			s.pop_back();
		if(s.empty())
			return 0;
		switch(m_level){
		case 0: log_e("mapgen", "%s", s.c_str()); break;
		case 1: log_w("mapgen", "%s", s.c_str()); break;
		case 2: log_i("mapgen", "%s", s.c_str()); break;
		default: log_v("mapgen", "%s", s.c_str()); break;
		}
		return 0;
	}
private:
	int m_level;
};

class LogStream: public std::ostream
{
public:
	LogStream(int level): std::ostream(&m_buf), m_buf(level){}
private:
	LogBuf m_buf;
};

extern LogStream errorstream_;
extern LogStream warningstream_;
extern LogStream actionstream_;
extern LogStream infostream_;
extern LogStream verbosestream_;
extern LogStream dstream_;

} // namespace luanti_shim_log

#define errorstream luanti_shim_log::errorstream_
#define warningstream luanti_shim_log::warningstream_
#define actionstream luanti_shim_log::actionstream_
#define infostream luanti_shim_log::infostream_
#define verbosestream luanti_shim_log::verbosestream_
#define dstream luanti_shim_log::dstream_
#define tracestream luanti_shim_log::verbosestream_
