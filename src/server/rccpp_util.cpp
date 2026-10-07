// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "rccpp_util.h"
#include "core/log.h"
#include "interface/sha1.h"
#include <c55/string_util.h>
#include <c55/filesys.h>
#include <fstream>
#include <set>
#include <map>
#include <mutex>
#include <sstream>
#include <sys/stat.h>
#define MODULE "rccpp_util"

namespace server {

// What was read of a file, kept while its time and size stay the same: a
// start reads every module's headers twice (compile_modules() plans, and
// load_module() plans again), and most modules include the same Urho3D
// headers -- 105 MB read and hashed twice per vanilla start, of 40 MB of
// files. simplified: a file rewritten within the same second at the same
// size is not seen as changed (only -R can hit it); the nanoseconds of
// the time if it does.
struct FileMemo {
	int64_t mtime = -1;
	int64_t size = -1;
	ss_ dirs;               // The include directories includes was made for
	bool has_includes = false;
	sv_<ss_> includes;      // Resolved, as list_includes_of() finds them
	ss_ hash;               // sha1 of the content, or "" not yet
};
static std::mutex g_memo_mutex;
static std::map<ss_, FileMemo> g_memo;

// The memo of a file that is current; reset if the file changed
static FileMemo& memo_of(const ss_ &path)
{
	struct stat st;
	int64_t mtime = -2, size = -2;
	if(stat(path.c_str(), &st) == 0){
		mtime = (int64_t)st.st_mtime;
		size = (int64_t)st.st_size;
	}
	FileMemo &m = g_memo[path];
	if(m.mtime != mtime || m.size != size){
		m = FileMemo();
		m.mtime = mtime;
		m.size = size;
	}
	return m;
}

// Every file a module's source includes, and what those include in turn:
// the build cache is keyed on all of them, and a header two steps away --
// interface/compress.h through luanti_mapgen's vendor/serialization.cpp --
// changed a function's signature and left a cached module that no longer
// linked (2026-10-03). Each file once, in the order first reached.
// The files path includes directly, resolved against the directories
static sv_<ss_> direct_includes_of(const ss_ &path,
		const sv_<ss_> &include_dirs)
{
	sv_<ss_> result;
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
				result.push_back(include_path);
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

// Every file a module's source includes, and what those include in turn:
// the build cache is keyed on all of them, and a header two steps away --
// interface/compress.h through luanti_mapgen's vendor/serialization.cpp --
// changed a function's signature and left a cached module that no longer
// linked (2026-10-03). Each file once, in the order first reached.
static void list_includes_of(const ss_ &path, const sv_<ss_> &include_dirs,
		const ss_ &dirs_key, std::set<ss_> &seen, sv_<ss_> &result)
{
	sv_<ss_> direct;
	{
		std::lock_guard<std::mutex> lock(g_memo_mutex);
		FileMemo &m = memo_of(path);
		if(!m.has_includes || m.dirs != dirs_key){
			m.includes = direct_includes_of(path, include_dirs);
			m.dirs = dirs_key;
			m.has_includes = true;
		}
		direct = m.includes;
	}
	for(const ss_ &include_path : direct){
		if(seen.insert(include_path).second){
			result.push_back(include_path);
			list_includes_of(include_path, include_dirs, dirs_key, seen,
					result);
		}
	}
}

sv_<ss_> list_includes(const ss_ &path, const sv_<ss_> &include_dirs)
{
	std::set<ss_> seen;
	sv_<ss_> result;
	ss_ dirs_key;
	for(const ss_ &dir : include_dirs)
		dirs_key += dir+"\n";
	list_includes_of(path, include_dirs, dirs_key, seen, result);
	return result;
}

// Each file's own hash, then those: a file shared by many modules is read
// once per start
ss_ hash_files(const sv_<ss_> &paths, const ss_ &extra)
{
	std::ostringstream os(std::ios::binary);
	os<<extra;
	std::lock_guard<std::mutex> lock(g_memo_mutex);
	for(const ss_ &path : paths){
		FileMemo &m = memo_of(path);
		if(m.hash.empty()){
			std::ifstream f(path, std::ios::binary);
			std::ostringstream content(std::ios::binary);
			// An unreadable file hashes as empty, as it always did
			if(f.good())
				content<<f.rdbuf();
			m.hash = interface::sha1::calculate(content.str());
		}
		os<<m.hash;
	}
	return interface::sha1::calculate(os.str());
}

}
// vim: set noet ts=4 sw=4:
