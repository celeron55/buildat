// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "rccpp_util.h"
#include "core/log.h"
#include "interface/sha1.h"
#include <c55/string_util.h>
#include <c55/filesys.h>
#include <fstream>
#include <set>
#define MODULE "rccpp_util"

namespace server {

// Every file a module's source includes, and what those include in turn:
// the build cache is keyed on all of them, and a header two steps away --
// interface/compress.h through luanti_mapgen's vendor/serialization.cpp --
// changed a function's signature and left a cached module that no longer
// linked (2026-10-03). Each file once, in the order first reached.
static void list_includes_of(const ss_ &path, const sv_<ss_> &include_dirs,
		std::set<ss_> &seen, sv_<ss_> &result)
{
	ss_ base_dir = c55fs::stripFilename(path);
	std::ifstream ifs(path);
	ss_ line;
	while(std::getline(ifs, line)){
		c55::Strfnd f(line);
		f.next("#");
		if(f.atend())
			continue;
		f.next("include");
		f.while_any(" ");
		ss_ quote = f.while_any("<\"");
		ss_ include = f.next(quote == "<" ? ">" : "\"");
		if(include == "")
			continue;
		bool found = false;
		sv_<ss_> include_dirs_now = include_dirs;
		if(quote == "\"")
			include_dirs_now.insert(include_dirs_now.begin(), base_dir);
		else
			include_dirs_now.push_back(base_dir);
		for(const ss_ &dir : include_dirs_now){
			ss_ include_path = dir+"/"+include;
			//log_v(MODULE, "Trying %s", cs(include_path));
			std::ifstream ifs2(include_path);
			if(ifs2.good()){
				found = true;
				if(seen.insert(include_path).second){
					result.push_back(include_path);
					list_includes_of(include_path, include_dirs, seen,
							result);
				}
				break;
			}
		}
		if(!found){
			// Not a huge problem, just log at debug
			log_d(MODULE, "Include file not found for watching: %s", cs(include));
		}
	}
}

sv_<ss_> list_includes(const ss_ &path, const sv_<ss_> &include_dirs)
{
	std::set<ss_> seen;
	sv_<ss_> result;
	list_includes_of(path, include_dirs, seen, result);
	return result;
}

ss_ hash_files(const sv_<ss_> &paths, const ss_ &extra)
{
	std::ostringstream os(std::ios::binary);
	os<<extra;
	for(const ss_ &path : paths){
		std::ifstream f(path);
		try {
			std::string content((std::istreambuf_iterator<char>(f)),
					std::istreambuf_iterator<char>());
			os<<content;
		} catch(std::ios_base::failure &e){
			// Just ignore errors
			log_w(MODULE, "hash_files: failed to read file %s: %s",
					cs(path), e.what());
		}
	}
	return interface::sha1::calculate(os.str());
}

}
// vim: set noet ts=4 sw=4:
