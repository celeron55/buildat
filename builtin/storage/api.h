// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace storage
{
	// A namespace of keys to blobs inside a save. Created on demand: an empty
	// store and a store that does not exist are the same thing.
	//
	// Every method takes the save's lock, so a Store* stays usable outside the
	// access() that produced it -- which is the point, since voxelworld keeps
	// one for the life of a world. What is not safe is closing a save while
	// another thread is using one of its stores; a save belongs to whoever
	// opened it.
	struct Store
	{
		virtual ~Store(){}
		virtual bool get(const ss_ &key, ss_ &value_out) = 0;
		virtual void set(const ss_ &key, const ss_ &value) = 0;
		virtual void remove(const ss_ &key) = 0;
		// Keys beginning with prefix, in order. "" is all of them.
		virtual sv_<ss_> list(const ss_ &prefix) = 0;
		// One transaction. The only sane way to write more than a few keys:
		// a key at a time outside a transaction is the classic slow save.
		virtual void batch(std::function<void()> writes) = 0;
	};

	struct Save
	{
		virtual ~Save(){}
		virtual Store* store(const ss_ &name) = 0;
		// The save's directory, for things that are not ours: a foreign
		// format, an importer's source, Luanti's core.get_worldpath().
		// Modules use the object store.
		virtual ss_ path() = 0;
	};

	struct SaveInfo
	{
		ss_ name;
		int64_t modified_us = 0;
	};

	struct Interface
	{
		// Split on purpose: neither call can do the other's job by accident,
		// so a typo in a save name cannot silently start a new game. open()
		// returns nullptr if it is not there; create() returns nullptr if it
		// already is. A game that wants open-or-create writes the two lines
		// itself, where they are visible.
		virtual Save* open(const ss_ &name) = 0;
		virtual Save* create(const ss_ &name) = 0;
		virtual void close(Save *save) = 0;
		virtual sv_<SaveInfo> list() = 0;
		// Deletes the save's directory and everything in it
		virtual void remove(const ss_ &name) = 0;
		// false if it has a path separator, a leading dot, or anything else
		// that would make it something other than one directory name
		virtual bool valid_name(const ss_ &name) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(storage::Interface*)> cb)
	{
		return server->access_module("storage", [&](interface::Module *module){
			auto *iface = (storage::Interface*)module->check_interface();
			cb(iface);
		});
	}
}

// vim: set noet ts=4 sw=4:
