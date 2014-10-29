// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/file_watch.h"
#include "core/log.h"
#include <cstring>
#include <sys/inotify.h>
#include <unistd.h>
#include <linux/limits.h> // PATH_MAX
#define MODULE "__filewatch"

#define INOTIFY_BUFSIZE (sizeof(struct inotify_event) + NAME_MAX + 1)
#define INOTIFY_STRUCTSIZE (sizeof(struct inotify_event))

namespace interface {

struct CFileWatch: FileWatch
{
	struct WatchThing {
		ss_ path;
		sv_<std::function<void(const ss_ &path)>> cbs;
		WatchThing(const ss_ &path,
				const sv_<std::function<void(const ss_ &path)>> &cbs):
			path(path), cbs(cbs){}
	};

	int m_fd = -1;
	sm_<int, sp_<WatchThing>> m_watch;

	CFileWatch()
	{
		m_fd = inotify_init1(IN_NONBLOCK);
		log_d(MODULE, "CFileWatch(): m_fd=%i", m_fd);
		if(m_fd == -1){
			throw Exception(ss_()+"inotify_init() failed: "+strerror(errno));
		}
	}

	~CFileWatch()
	{
		close(m_fd);
	}

	void add(const ss_ &path, std::function<void(const ss_ &path)> cb)
	{
		for(auto &pair : m_watch){
			sp_<WatchThing> &watch = pair.second;
			if(watch->path == path){
				log_t(MODULE, "Adding callback to path \"%s\" (inotify fd=%i)",
						cs(path), pair.first);
				watch->cbs.push_back(cb);
				return;
			}
		}
		int r = inotify_add_watch(m_fd, path.c_str(), IN_CLOSE_WRITE |
				IN_MOVED_TO | IN_CREATE | IN_MOVED_FROM | IN_DELETE |
				IN_MODIFY | IN_ATTRIB);
		if(r == -1){
			throw Exception(ss_()+"inotify_add_watch() failed: "+
					strerror(errno)+" (path="+path+")");
		}
		log_t(MODULE, "Watching path \"%s\" (inotify fd=%i)", cs(path), m_fd);
		m_watch[r] = sp_<WatchThing>(new WatchThing(path, {cb}));
	}

	// Used on Linux; no-op on Windows
	sv_<int> get_fds()
	{
		if(m_fd == -1)
			return {};
		return {m_fd};
	}
	void report_fd(int fd)
	{
		if(fd != m_fd)
			return;
		char buf[INOTIFY_BUFSIZE];
		for(;;){
			int r = read(fd, buf, INOTIFY_BUFSIZE);
			if(r == -1){
				if(errno == EAGAIN)
					break;
				log_w(MODULE, "CFileWatch::report_fd(): read() failed "
						"on fd=%i: %s", fd, strerror(errno));
				break;
			}
			if(r < (int)INOTIFY_STRUCTSIZE){
				throw Exception("CFileWatch::report_fd(): read() -> "+itos(r));
			}
			struct inotify_event *in_event = (struct inotify_event*)buf;
			ss_ name;
			if(r >= (int)INOTIFY_STRUCTSIZE)
				name = &buf[INOTIFY_STRUCTSIZE]; // Null-terminated string
			ss_ mask_s;
			if(in_event->mask & IN_ACCESS) mask_s += "IN_ACCESS | ";
			if(in_event->mask & IN_ATTRIB) mask_s += "IN_ATTRIB | ";
			if(in_event->mask & IN_CLOSE_WRITE) mask_s += "IN_CLOSE_WRITE | ";
			if(in_event->mask & IN_CLOSE_NOWRITE) mask_s += "IN_CLOSE_NOWRITE | ";
			if(in_event->mask & IN_CREATE) mask_s += "IN_CREATE | ";
			if(in_event->mask & IN_DELETE) mask_s += "IN_DELETE | ";
			if(in_event->mask & IN_DELETE_SELF) mask_s += "IN_DELETE_SELF | ";
			if(in_event->mask & IN_MODIFY) mask_s += "IN_MODIFY | ";
			if(in_event->mask & IN_MOVE_SELF) mask_s += "IN_MOVE_SELF | ";
			if(in_event->mask & IN_MOVED_FROM) mask_s += "IN_MOVED_FROM | ";
			if(in_event->mask & IN_MOVED_TO) mask_s += "IN_MOVED_TO | ";
			if(in_event->mask & IN_OPEN) mask_s += "IN_OPEN | ";
			if(in_event->mask & IN_IGNORED) mask_s += "IN_IGNORED | ";
			if(in_event->mask & IN_ISDIR) mask_s += "IN_ISDIR | ";
			if(in_event->mask & IN_Q_OVERFLOW) mask_s += "IN_Q_OVERFLOW | ";
			if(in_event->mask & IN_UNMOUNT) mask_s += "IN_UNMOUNT | ";

			mask_s = mask_s.substr(0, mask_s.size()-3);

			log_d(MODULE, "in_event->wd=%i, mask=%s, name=%s",
					in_event->wd, cs(mask_s), cs(name));

			auto it = m_watch.find(in_event->wd);
			if(it == m_watch.end())
				throw Exception("inotify returned unknown wd");
			sp_<WatchThing> thing = it->second;
			for(auto &cb : thing->cbs){
				if(!name.empty())
					cb(thing->path+"/"+name);
				else
					cb(thing->path);
			};

			if(in_event->mask & IN_IGNORED){
				// Inotify removed path from watch
				const ss_ &path = thing->path;
				m_watch.erase(in_event->wd);
				int r = inotify_add_watch(m_fd, path.c_str(), IN_CLOSE_WRITE |
						IN_MOVED_TO | IN_CREATE | IN_MOVED_FROM | IN_DELETE |
						IN_MODIFY | IN_ATTRIB);
				if(r == -1){
					log_w(MODULE, "inotify_add_watch() failed: %s (while trying "
							"to re-watch ignored path \"%s\")",
							strerror(errno), cs(path));
				} else {
					log_v(MODULE, "Re-watching auto-ignored path \"%s\" (inotify fd=%i)",
							cs(path), m_fd);
					m_watch[r] = thing;
				}
			}
		}
	}

	// Used on Windows; no-op on Linux
	void update()
	{
	}
};

FileWatch* createFileWatch()
{
	return new CFileWatch();
}

}
