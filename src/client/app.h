// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace Urho3D {
	class Context;
	class Graphics;
	class Scene;
}
namespace client {
	struct State;
}
namespace interface {
	struct VoxelRegistry;
	struct TextureAtlasRegistry;

	namespace worker_thread {
		struct ThreadPool;
	}
}

namespace app
{
	struct AppStartupError: public Exception {
		ss_ msg;
		AppStartupError(const ss_ &msg): Exception(msg){}
	};

	struct GraphicsOptions
	{
		static const int UNDEFINED_INT = 2147483647;

		int window_w = 1024;
		int window_h = 768;
		int full_w = 0;
		int full_h = 0;
		bool fullscreen = false;
		bool borderless = false;
		bool resizable = true;
		bool vsync = true;
		bool triple_buffer = false;
		int multisampling = 1; // 2 looks much better but is much heavier(?)
		int window_x = UNDEFINED_INT;
		int window_y = UNDEFINED_INT;

		void apply(Urho3D::Graphics *magic_graphics);
	};

	struct Options
	{
		GraphicsOptions graphics;
	};

	struct App
	{
		virtual ~App(){}
		virtual void set_state(sp_<client::State> state) = 0;
		virtual int run() = 0;
		virtual void shutdown() = 0;
		virtual bool reboot_requested() = 0;
		virtual Options get_current_options() = 0;
		virtual void run_script(const ss_ &script) = 0;
		virtual bool run_script_no_sandbox(const ss_ &script) = 0;
		virtual void handle_packet(const ss_ &name, const ss_ &data) = 0;
		virtual void file_updated_in_cache(const ss_ &file_name,
				const ss_ &file_hash, const ss_ &cached_path) = 0;
		virtual Urho3D::Scene* get_scene() = 0;
		virtual interface::worker_thread::ThreadPool* get_thread_pool() = 0;
	};

	App* createApp(Urho3D::Context *context, const Options &options = Options());
}
// vim: set noet ts=4 sw=4:
