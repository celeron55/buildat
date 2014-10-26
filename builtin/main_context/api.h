// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace Urho3D
{
	class Context;
	class Scene;
	class StringHash;
}

namespace main_context
{
	namespace magic = Urho3D;
	using interface::Event;

	struct Interface
	{
		// NOTE: Do not store Urho3D::SharedPtr<>s or any other kinds of pointers
		//       to Urho3D objects because accessing and deleting them is not
		//       thread-safe.

		virtual magic::Context* get_context() = 0;
		virtual magic::Scene* get_scene() = 0;

		virtual void sub_magic_event(
				const magic::StringHash &event_type,
				const Event::Type &buildat_event_type) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(main_context::Interface*)> cb)
	{
		return server->access_module("main_context", [&](interface::Module *module){
			cb((main_context::Interface*)module->check_interface());
		});
	}
}
// vim: set noet ts=4 sw=4:
