// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/file_watch.h"
#include "core/log.h"
#include <cstring>
#include <sys/inotify.h>
#include <unistd.h>
#define MODULE "__filewatch"

namespace interface {

struct CFileWatch: FileWatch
{
	int m_fd = -1;
	std::function<void()> m_cb;
	sm_<int, ss_> m_watch_paths;

	CFileWatch(const sv_<ss_> &paths, std::function<void()> cb):
		m_cb(cb)
	{
		m_fd = inotify_init1(IN_NONBLOCK);
		if(m_fd == -1){
			throw Exception(ss_()+"inotify_init() failed: "+strerror(errno));
		}
		for(const ss_ &path : paths){
			int r = inotify_add_watch(m_fd, path.c_str(), IN_CLOSE_WRITE |
					IN_MOVED_TO | IN_CREATE | IN_MOVED_FROM | IN_DELETE |
					IN_MODIFY | IN_ATTRIB);
			if(r == -1){
				throw Exception(ss_()+"inotify_add_watch() failed: "+
						strerror(errno)+" (path="+path+")");
			}
			log_v(MODULE, "Watching path \"%s\" (inotify fd=%i)", cs(path), m_fd);
			m_watch_paths[r] = path;
		}
	}

	~CFileWatch()
	{
		close(m_fd);
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
		struct inotify_event in_event;
		for(;;){
			int r = read(fd, &in_event, sizeof(struct inotify_event));
			if(r != sizeof(struct inotify_event))
				break;
			sv_<char> name_buf(in_event.len);
			read(fd, &name_buf[0], in_event.len);
			ss_ name(name_buf.begin(), name_buf.end());
			ss_ mask_s;
			if(in_event.mask & IN_ACCESS) mask_s += "IN_ACCESS | ";
			if(in_event.mask & IN_ATTRIB) mask_s += "IN_ATTRIB | ";
			if(in_event.mask & IN_CLOSE_WRITE) mask_s += "IN_CLOSE_WRITE | ";
			if(in_event.mask & IN_CLOSE_NOWRITE) mask_s += "IN_CLOSE_NOWRITE | ";
			if(in_event.mask & IN_CREATE) mask_s += "IN_CREATE | ";
			if(in_event.mask & IN_DELETE) mask_s += "IN_DELETE | ";
			if(in_event.mask & IN_DELETE_SELF) mask_s += "IN_DELETE_SELF | ";
			if(in_event.mask & IN_MODIFY) mask_s += "IN_MODIFY | ";
			if(in_event.mask & IN_MOVE_SELF) mask_s += "IN_MOVE_SELF | ";
			if(in_event.mask & IN_MOVED_FROM) mask_s += "IN_MOVED_FROM | ";
			if(in_event.mask & IN_MOVED_TO) mask_s += "IN_MOVED_TO | ";
			if(in_event.mask & IN_OPEN) mask_s += "IN_OPEN | ";
			if(in_event.mask & IN_IGNORED) mask_s += "IN_IGNORED | ";
			if(in_event.mask & IN_ISDIR) mask_s += "IN_ISDIR | ";
			if(in_event.mask & IN_Q_OVERFLOW) mask_s += "IN_Q_OVERFLOW | ";
			if(in_event.mask & IN_UNMOUNT) mask_s += "IN_UNMOUNT | ";

			mask_s = mask_s.substr(0, mask_s.size()-3);

			log_d(MODULE, "in_event.wd=%i, mask=%s, name=%s",
					in_event.wd, cs(mask_s), cs(name));

			if(in_event.mask & IN_IGNORED){
				// Inotify removed path from watch
				ss_ path = m_watch_paths[in_event.wd];
				m_watch_paths.erase(in_event.wd);
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
					m_watch_paths[r] = path;
				}
			}
		}
		m_cb();
	}

	// Used on Windows; no-op on Linux
	void update()
	{
	}
};

FileWatch* createFileWatch(const sv_<ss_> &paths, std::function<void()> cb)
{
	return new CFileWatch(paths, cb);
}

struct CMultiFileWatch: MultiFileWatch
{
	struct WatchThing {
		ss_ path;
		std::function<void(const ss_ &path)> cb;
		WatchThing(const ss_ &path, std::function<void(const ss_ &path)> cb):
			path(path), cb(cb){}
	};

	int m_fd = -1;
	sm_<int, sp_<WatchThing>> m_watch;

	CMultiFileWatch()
	{
		m_fd = inotify_init1(IN_NONBLOCK);
		if(m_fd == -1){
			throw Exception(ss_()+"inotify_init() failed: "+strerror(errno));
		}
	}

	~CMultiFileWatch()
	{
		close(m_fd);
	}

	void add(const ss_ &path, std::function<void(const ss_ &path)> cb)
	{
		int r = inotify_add_watch(m_fd, path.c_str(), IN_CLOSE_WRITE |
				IN_MOVED_TO | IN_CREATE | IN_MOVED_FROM | IN_DELETE |
				IN_MODIFY | IN_ATTRIB);
		if(r == -1){
			throw Exception(ss_()+"inotify_add_watch() failed: "+
					strerror(errno)+" (path="+path+")");
		}
		log_v(MODULE, "Watching path \"%s\" (inotify fd=%i)", cs(path), m_fd);
		m_watch[r] = sp_<WatchThing>(new WatchThing(path, cb));
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
		struct inotify_event in_event;
		for(;;){
			int r = read(fd, &in_event, sizeof(struct inotify_event));
			if(r != sizeof(struct inotify_event))
				break;
			sv_<char> name_buf(in_event.len);
			read(fd, &name_buf[0], in_event.len);
			ss_ name(name_buf.begin(), name_buf.end());
			ss_ mask_s;
			if(in_event.mask & IN_ACCESS) mask_s += "IN_ACCESS | ";
			if(in_event.mask & IN_ATTRIB) mask_s += "IN_ATTRIB | ";
			if(in_event.mask & IN_CLOSE_WRITE) mask_s += "IN_CLOSE_WRITE | ";
			if(in_event.mask & IN_CLOSE_NOWRITE) mask_s += "IN_CLOSE_NOWRITE | ";
			if(in_event.mask & IN_CREATE) mask_s += "IN_CREATE | ";
			if(in_event.mask & IN_DELETE) mask_s += "IN_DELETE | ";
			if(in_event.mask & IN_DELETE_SELF) mask_s += "IN_DELETE_SELF | ";
			if(in_event.mask & IN_MODIFY) mask_s += "IN_MODIFY | ";
			if(in_event.mask & IN_MOVE_SELF) mask_s += "IN_MOVE_SELF | ";
			if(in_event.mask & IN_MOVED_FROM) mask_s += "IN_MOVED_FROM | ";
			if(in_event.mask & IN_MOVED_TO) mask_s += "IN_MOVED_TO | ";
			if(in_event.mask & IN_OPEN) mask_s += "IN_OPEN | ";
			if(in_event.mask & IN_IGNORED) mask_s += "IN_IGNORED | ";
			if(in_event.mask & IN_ISDIR) mask_s += "IN_ISDIR | ";
			if(in_event.mask & IN_Q_OVERFLOW) mask_s += "IN_Q_OVERFLOW | ";
			if(in_event.mask & IN_UNMOUNT) mask_s += "IN_UNMOUNT | ";

			mask_s = mask_s.substr(0, mask_s.size()-3);

			log_d(MODULE, "in_event.wd=%i, mask=%s, name=%s",
					in_event.wd, cs(mask_s), cs(name));

			auto it = m_watch.find(in_event.wd);
			if(it == m_watch.end())
				throw Exception("inotify returned unknown wd");
			sp_<WatchThing> thing = it->second;
			thing->cb(thing->path);

			if(in_event.mask & IN_IGNORED){
				// Inotify removed path from watch
				const ss_ &path = thing->path;
				m_watch.erase(in_event.wd);
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

MultiFileWatch* createMultiFileWatch()
{
	return new CMultiFileWatch();
}

}
