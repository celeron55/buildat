// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"

namespace interface
{
	struct ModuleInfo;
	struct Module;
}

namespace Urho3D
{
	class Scene;
};

namespace server
{
	namespace magic = Urho3D;

	struct ServerShutdownRequest: public Exception {
		ss_ msg;
		ServerShutdownRequest(const ss_ &msg): Exception(msg){}
	};

	struct ModuleNotFoundException: public Exception {
		ss_ msg;
		ModuleNotFoundException(const ss_ &msg): Exception(msg){}
	};

	struct State
	{
		virtual ~State(){}
		virtual void shutdown(int exit_status = 0, const ss_ &reason = "") = 0;
		virtual bool is_shutdown_requested(int *exit_status = nullptr,
				ss_ *reason = nullptr) = 0;
		virtual bool load_module(const interface::ModuleInfo &info) = 0;
		virtual void load_modules(const ss_ &path) = 0;
		virtual interface::Module* get_module(const ss_ &module_name) = 0;
		virtual interface::Module* check_module(const ss_ &module_name) = 0;
		virtual void sub_event(struct interface::Module *module,
				const interface::Event::Type &type) = 0;
		virtual void emit_event(interface::Event event) = 0;
		virtual void access_scene(std::function<void(magic::Scene*)> cb) = 0;

		virtual void handle_events() = 0;
		virtual sv_<int> get_sockets() = 0;
		virtual void emit_socket_event(int fd) = 0;

		// Add resource file path (to make a mirror of the client)
		virtual void add_file_path(const ss_ &name, const ss_ &path) = 0;
		// Returns "" if not found
		virtual ss_ get_file_path(const ss_ &name) = 0;
	};

	State* createState();
}
// vim: set noet ts=4 sw=4:
