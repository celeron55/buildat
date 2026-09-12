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
	struct AtlasRegistry;

	namespace thread_pool {
		struct ThreadPool;
	}
}
extern "C" {
	struct lua_State;
	typedef struct lua_State lua_State;
}

namespace app
{
	struct AppStartupError: public Exception {
		ss_ msg;
		AppStartupError(const ss_ &msg): Exception(msg){}
	};

	struct GraphicsOptions
	{
		int window_w = 0; // 0 = pick from saved size or desktop
		int window_h = 0;
		int full_w = 0;
		int full_h = 0;
		bool fullscreen = false;
		bool maximized = false;
		bool borderless = false;
		bool resizable = true;
		bool vsync = true;
		bool triple_buffer = false;
		int multisampling = 1; // 2 looks much better but is much heavier(?)
		// 3D viewports a game asked the engine to draw are rendered at this
		// fraction of the window size; the UI stays at native resolution.
		// 1.0 is a bypass, not a scale of one.
		float render_scale = 1.0f;
		// Frame limiter. 200 is Urho3D's own desktop default, so leaving it
		// alone changes nothing; 0 is unlimited.
		int max_fps = 200;
		// Set by -w: the size came from the command line, so it is not
		// remembered across runs and the saved size is left alone
		bool size_forced = false;

		void apply(Urho3D::Graphics *magic_graphics);
	};

	struct Options
	{
		GraphicsOptions graphics;
		// Beside the graphics rather than inside it: the file is the user's
		// preferences, GraphicsOptions is a display mode
		float sound_volume = 1.0f;
		bool sound_mute = false;
		// -o k=v,...: applied on top of the saved file, and never written
		// back, the same rule -w already follows
		ss_ preference_overrides;
		// -c: the saved file is neither read nor written, so that a
		// preference someone left behind cannot change a screenshot
		bool preferences_disabled = false;
	};

	// Parses "k=v[,k=v...]" on top of whatever *opt already holds. Returns
	// false and fills *error on a malformed item, an unknown key or a value
	// out of range; *opt is then partially applied and should be discarded.
	bool parse_preference_options(const ss_ &s, Options *opt, ss_ *error);

	struct App
	{
		virtual ~App(){}
		virtual void set_state(sp_<client::State> state) = 0;
		virtual int run() = 0;
		virtual void shutdown() = 0;
		virtual void run_script(const ss_ &script) = 0;
		virtual bool run_script_no_sandbox(const ss_ &script) = 0;
		virtual void handle_packet(const ss_ &name, const ss_ &data) = 0;
		virtual void file_updated_in_cache(const ss_ &file_name,
				const ss_ &file_hash, const ss_ &cached_path) = 0;
		virtual Urho3D::Scene* get_scene() = 0;
		virtual interface::thread_pool::ThreadPool* get_thread_pool() = 0;
		virtual lua_State* get_lua() = 0;
	};

	App* createApp(Urho3D::Context *context, const Options &options = Options());
}
// vim: set noet ts=4 sw=4:
