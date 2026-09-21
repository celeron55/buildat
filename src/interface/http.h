// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <functional>

namespace interface
{
	// HTTPS through libcurl, a required dependency ([CONTENTDB]; [HTTP_API]
	// later). Both block: a caller that must not wait puts them on a
	// thread. Both throw with curl's message on any failure, a non-2xx
	// status included.
	ss_ http_get(const ss_ &url);
	// The body straight to a file. progress(got, total) is called as it
	// comes (total 0 when the server does not say); false from it aborts,
	// which throws.
	void http_download(const ss_ &url, const ss_ &path,
			std::function<bool(uint64_t got, uint64_t total)> progress = nullptr);
}
// vim: set noet ts=4 sw=4:
