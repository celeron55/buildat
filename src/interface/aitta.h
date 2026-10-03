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

		// Packs app_dir (meta.json at its root) into out_dir and signs it
		// with the key in key_path. Returns the zip's path; throws why not.
		ss_ pack(const ss_ &app_dir, const ss_ &key_path, const ss_ &out_dir);

		// Checks a release -- the hash, the signature, the manifest, the
		// engine API -- and unpacks it into
		// <user>/installed/<author>/<name>/<version>/. The first install of
		// an author/name keeps its key, and a later version signed by
		// another key is refused. Returns the directory; throws why not.
		ss_ install(const ss_ &zip_path, const ss_ &sig_path,
				const ss_ &user_path);
	}
}
// vim: set noet ts=4 sw=4:
