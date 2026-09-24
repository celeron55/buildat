// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/http.h"
#include "core/log.h"
#include "core/version.h"
#include <curl/curl.h>
#ifdef _WIN32
	// curl.h brings windows.h in, and windows.h #defines interface, which
	// is the namespace below
	#undef interface
#endif
#include <fstream>
#include <mutex>
#define MODULE "http"

namespace interface {

static void global_init_once()
{
	static std::once_flag once;
	std::call_once(once, [](){ curl_global_init(CURL_GLOBAL_DEFAULT); });
}

static size_t to_string(char *p, size_t size, size_t n, void *user)
{
	((ss_*)user)->append(p, size * n);
	return size * n;
}
static size_t to_file(char *p, size_t size, size_t n, void *user)
{
	std::ofstream &f = *(std::ofstream*)user;
	f.write(p, size * n);
	return f.good() ? size * n : 0;
}

struct Progress {
	std::function<bool(uint64_t, uint64_t)> f;
};
static int on_progress(void *user, curl_off_t total, curl_off_t got,
		curl_off_t, curl_off_t)
{
	Progress &p = *(Progress*)user;
	if(p.f && !p.f((uint64_t)got, total > 0 ? (uint64_t)total : 0))
		return 1;
	return 0;
}

static CURL *easy(const ss_ &url, char *errbuf)
{
	global_init_once();
	CURL *c = curl_easy_init();
	if(!c)
		throw Exception("http: curl_easy_init failed");
	curl_easy_setopt(c, CURLOPT_URL, url.c_str());
	curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
	curl_easy_setopt(c, CURLOPT_MAXREDIRS, 8L);
	curl_easy_setopt(c, CURLOPT_FAILONERROR, 1L);
	// **Who is calling** ([LICENSE_DUAL]'s second courtesy): ContentDB's
	// and the serverlist's bandwidth is donated, and an operator reading
	// a log should see a name and a version rather than libcurl's
	// default. A project URL belongs here the day there is a public one.
	static const ss_ user_agent = ss_("buildat/")+BUILDAT_VERSION;
	curl_easy_setopt(c, CURLOPT_USERAGENT, user_agent.c_str());
	curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 20L);
	curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L);
	curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 60L);
	curl_easy_setopt(c, CURLOPT_ERRORBUFFER, errbuf);
	return c;
}

static void perform(CURL *c, const ss_ &url, const char *errbuf)
{
	const CURLcode r = curl_easy_perform(c);
	long status = 0;
	curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
	curl_easy_cleanup(c);
	if(r != CURLE_OK){
		throw Exception("http: "+url+": "+
				(errbuf[0] ? ss_(errbuf) : ss_(curl_easy_strerror(r)))+
				(status ? " (status "+itos(status)+")" : ss_()));
	}
}

ss_ http_get(const ss_ &url)
{
	char errbuf[CURL_ERROR_SIZE] = {0};
	CURL *c = easy(url, errbuf);
	ss_ body;
	curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, to_string);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, &body);
	perform(c, url, errbuf);
	return body;
}

void http_download(const ss_ &url, const ss_ &path,
		std::function<bool(uint64_t, uint64_t)> progress)
{
	char errbuf[CURL_ERROR_SIZE] = {0};
	std::ofstream f(path, std::ios::binary | std::ios::trunc);
	if(!f.good())
		throw Exception("http: cannot write "+path);
	CURL *c = easy(url, errbuf);
	Progress p{progress};
	curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, to_file);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, &f);
	curl_easy_setopt(c, CURLOPT_NOPROGRESS, 0L);
	curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, on_progress);
	curl_easy_setopt(c, CURLOPT_XFERINFODATA, &p);
	perform(c, url, errbuf);
	f.close();
	if(!f.good())
		throw Exception("http: could not finish writing "+path);
}

} // namespace interface
// vim: set noet ts=4 sw=4:
