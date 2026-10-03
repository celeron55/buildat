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
	//
	// With `redirect`, a redirect is not followed: its target goes there
	// and the body answered is "" -- for a caller that asks the user about
	// every host it fetches from, which a redirect would step around
	// ([SECURITY_RUN_1]). Without it up to 8 are followed.
	ss_ http_get(const ss_ &url, ss_ *redirect = nullptr);
	// The body of a POST of `body` as `content_type` ([STARPORT]: a server
	// announcing itself, a client's report); throws as http_get does
	ss_ http_post(const ss_ &url, const ss_ &body,
			const ss_ &content_type = "application/json",
			ss_ *redirect = nullptr);
	// A mail through an SMTP server (smtp:// or smtps://; STARTTLS when the
	// server offers it): `message` is the whole of it, headers and all,
	// lines ending in CRLF. user empty: no login. Throws as http_get does.
	void send_mail(const ss_ &url, const ss_ &user, const ss_ &password,
			const ss_ &from, const ss_ &to, const ss_ &message);
	// Whether the libcurl in use speaks SMTP: a minimal build (Fedora's
	// libcurl-minimal) does not
	bool mail_supported();
	// The body straight to a file. progress(got, total) is called as it
	// comes (total 0 when the server does not say); false from it aborts,
	// which throws.
	void http_download(const ss_ &url, const ss_ &path,
			std::function<bool(uint64_t got, uint64_t total)> progress = nullptr);
}
// vim: set noet ts=4 sw=4:
