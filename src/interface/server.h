#pragma once
#include "core/types.h"
#include "interface/event.h"

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

	struct Server
	{
		virtual ~Server(){}

		virtual void load_module(const ss_ &module_name, const ss_ &path) = 0;
		virtual ss_ get_modules_path() = 0;
		virtual ss_ get_builtin_modules_path() = 0;
		virtual bool has_module(const ss_ &module_name) = 0;

		virtual void sub_event(struct Module *module, const Event::Type &type) = 0;
		virtual void emit_event(const Event &event) = 0;

		virtual void add_socket_event(int fd, const Event::Type &event_type) = 0;
		virtual void remove_socket_event(int fd) = 0;
	};
}
