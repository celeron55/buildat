// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "rccpp_util.h"
#include "core/log.h"
#include "interface/sha1.h"
#include <c55/string_util.h>
#include <c55/filesys.h>
#include <fstream>
#define MODULE "rccpp_util"

namespace server {

sv_<ss_> list_includes(const ss_ &path, const sv_<ss_> &include_dirs)
{
	ss_ base_dir = c55fs::stripFilename(path);
	std::ifstream ifs(path);
	sv_<ss_> result;
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
		for(const ss_ &dir : include_dirs){
			ss_ include_path = dir+"/"+include;
			//log_v(MODULE, "Trying %s", cs(include_path));
			std::ifstream ifs2(include_path);
			if(ifs2.good()){
				result.push_back(include_path);
				found = true;
				break;
			}
		}
		if(!found){
			// Not a huge problem, just log at debug
			log_d(MODULE, "Include file not found for watching: %s", cs(include));
		}
	}
	return result;
}

ss_ hash_files(const sv_<ss_> &paths)
{
	std::ostringstream os(std::ios::binary);
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
