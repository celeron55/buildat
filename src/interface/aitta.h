// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/json.h"

namespace interface
{
	// [AITTA_MVP]: an app as a signed package. A release is two files:
	// <author>-<name>-<version>.zip, the app's directory with its manifest
	// (meta.json at its root), and the same name with .sig, which carries
	// the zip's sha256, the author's public key and the key's signature
	// over the hash.
	//
	// The key is ECDSA P-256 through Mbed TLS (decided in
	// doc/plan/aitta_plan.md), and signing is deterministic (RFC 6979).
	namespace aitta
	{
		// The engine API an app's C++ is written against. **Bumped when a
		// change in src/interface breaks modules**; an app whose manifest
		// says more than this is not installed.
		static const int ENGINE_API = 1;

		// A new key: the file's text, and its public half as hex
		void keygen(ss_ &key_file_text, ss_ &public_hex);
		// The public half of a key file's text; throws on a bad one
		ss_ public_of(const ss_ &key_file_text);
		// The key's signature over data's sha256, as hex
		ss_ sign(const ss_ &key_file_text, const ss_ &data);
		bool verify(const ss_ &public_hex, const ss_ &data,
				const ss_ &signature_hex);
		// The same, given the data's sha256 as hex: a registry checks who
		// signed a release before the archive has arrived
		bool verify_hash(const ss_ &public_hex, const ss_ &sha256_hex,
				const ss_ &signature_hex);

		// The manifest's fields checked; "" or why not
		ss_ check_manifest(const json::Value &m);

		// [PACKAGE_MEDIA] A package's image checked by its header: which
		// "icon", a square PNG of 256 px a side and 64 KB at most, or
		// "screenshot", a PNG or a JPEG (baseline or progressive, 8-bit:
		// what the client's decoder takes) of 1920 px a side and 2 MB at
		// most. "" or why not; *type "image/png" or "image/jpeg".
		// simplified: the header only; the client and the browser decode
		// the rest, as a server's icon
		ss_ media_check(const ss_ &which, const ss_ &data,
				ss_ *type = nullptr);
		// The manifest's "icon" and "screenshot" in dir checked: "" or why
		// not
		ss_ check_media(const json::Value &m, const ss_ &dir);
		// "app", or "extension" ([AITTA] step 3's second kind): a client
		// extension, run in the client's sandbox under the name
		// "<author>__<name>"
		ss_ kind_of(const json::Value &m);

		// What pack() puts in the archive: every file under dir, '/'
		// separated, the names starting with '.' left out
		sv_<ss_> package_files(const ss_ &dir);

		// Packs app_dir (meta.json at its root) into out_dir and signs it
		// with the key in key_path. Returns the zip's path; throws why not.
		ss_ pack(const ss_ &app_dir, const ss_ &key_path, const ss_ &out_dir);

		// Checks a release -- the hash, the signature, the manifest, the
		// engine API -- and unpacks it into
		// <user>/installed/<author>/<name>/<version>/. The first install of
		// an author/name keeps its key, and a later version signed by
		// another key is refused. Returns the directory; throws why not.
		// review: a reviewer's playtest ([AITTA_REVIEW]), an app only, into
		// <user>/review/<author>__<name>/<version>/, no key kept, over one
		// there was.
		ss_ install(const ss_ &zip_path, const ss_ &sig_path,
				const ss_ &user_path, bool review = false);
	}
}
// vim: set noet ts=4 sw=4:
