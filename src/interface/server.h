// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"
#include <functional>

namespace interface
{
	struct Module;

	struct TickEvent: public interface::Event::Private {
		float dtime;
		TickEvent(float dtime): dtime(dtime){}
	};

	struct SocketEvent: public interface::Event::Private {
		int fd;
		SocketEvent(int fd): fd(fd){}
	};

	struct ModuleModifiedEvent: public interface::Event::Private {
		ss_ name;
		ss_ path;
		ModuleModifiedEvent(const ss_ &name, const ss_ &path):
			name(name), path(path){}
	};

	struct ModuleLoadedEvent: public interface::Event::Private {
		ss_ name;
		ModuleLoadedEvent(const ss_ &name): name(name){}
	};

	struct ModuleUnloadedEvent: public interface::Event::Private {
		ss_ name;
		ModuleUnloadedEvent(const ss_ &name): name(name){}
	};

	struct Server
	{
		virtual ~Server(){}

		virtual void shutdown(int exit_status = 0, const ss_ &reason="") = 0;

		virtual bool load_module(const ss_ &module_name, const ss_ &path) = 0;
		virtual void unload_module(const ss_ &module_name) = 0;
		virtual void reload_module(const ss_ &module_name, const ss_ &path) = 0;
		virtual ss_ get_modules_path() = 0;
		virtual ss_ get_builtin_modules_path() = 0;
		virtual ss_ get_module_path(const ss_ &module_name) = 0;
		virtual bool has_module(const ss_ &module_name) = 0;
		virtual sv_<ss_> get_loaded_modules() = 0;
		virtual bool access_module(const ss_ &module_name,
				std::function<void(interface::Module*)> cb) = 0;

		virtual void sub_event(struct Module *module, const Event::Type &type) = 0;
		virtual void emit_event(Event event) = 0;
		template<typename PrivateT>
		void emit_event(const ss_ &name, PrivateT *p){
			emit_event(std::move(Event(name, up_<Event::Private>(p))));
		}

		virtual void add_socket_event(int fd, const Event::Type &event_type) = 0;
		virtual void remove_socket_event(int fd) = 0;

		virtual void tmp_store_data(const ss_ &name, const ss_ &data) = 0;
		virtual ss_ tmp_restore_data(const ss_ &name) = 0;
	};
}
// vim: set noet ts=4 sw=4:
