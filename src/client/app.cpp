// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "app.h"
#include "core/log.h"
#include "core/json.h"
#include "client/config.h"
#include "client/state.h"
#include "client/command_seq.h"
#include "lua_bindings/init.h"
#include "lua_bindings/util.h"
#include "lua_bindings/replicate.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/process.h"
#include "interface/tcpsocket.h"
#include "interface/voxel.h"
#include "interface/thread_pool.h"
#include <cctype>
#include <algorithm>
#include <c55/getopt.h>
#include <c55/os.h>
#include <Application.h>
#include <Engine.h>
#include <LuaScript.h>
#include <CoreEvents.h>
#include <Input.h>
#include <InputEvents.h> // E_EXITREQUESTED
#include <ResourceCache.h>
#include <Graphics.h>
#include <GraphicsEvents.h> // E_SCREENMODE
#include <IOEvents.h> // E_LOGMESSAGE
#include <Log.h>
#include <DebugHud.h>
#include <XMLFile.h>
#include <Scene.h>
#include <LuaFunction.h>
#include <Viewport.h>
#include <Camera.h>
#include <Renderer.h>
#include <Audio.h>
#include <RenderSurface.h>
#include <Texture2D.h>
#include <BorderImage.h>
#include <Octree.h>
#include <FileSystem.h>
#include <PhysicsWorld.h>
#include <DebugRenderer.h>
#include <Profiler.h>
#include <UI.h>
#include <SDL/SDL.h>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include <signal.h>
#include <random>
#include <cstdio>
#include <cstring>
#ifndef _WIN32
#include <unistd.h>
#include <limits.h>
#endif
#define MODULE "__app"
namespace magic = Urho3D;

// Auto UI scale: min(window w,h) / this. Lua/config/CLI overrides replace it.
static const float UI_REF_SHORT = 1080.f;
// Snap to 1x, 2x, ... when close, so 1px lines stay on-pixel.
// Under: maximized window chrome (taskbar, title). Over: 16:10 like 1200p.
static const float UI_SNAP_UNDER = 0.08f;
static const float UI_SNAP_OVER = 0.12f;
static const int MIN_WINDOW_W = 640;
static const int MIN_WINDOW_H = 360;

// The look command. How far off the camera may be left, how far it is allowed
// to be asked to turn in one frame, how much of a turn counts as having moved
// at all, how many frames of not moving mean the game does not do mouse look,
// and how many frames of trying mean it is not going to arrive. The first
// guess is only what the first step is taken with; the second step onwards
// uses what the first one actually did.
static const float LOOK_TOLERANCE_DEG = 0.4f;
static const float LOOK_MAX_STEP_DEG = 60.0f;
static const float LOOK_MOVED_DEG = 0.002f;
static const float LOOK_FIRST_GUESS_DEG_PER_PX = 0.15f;
static const int LOOK_FLIP_FRAMES = 4;
static const int LOOK_STILL_FRAMES = 30;
static const int LOOK_MAX_FRAMES = 300;

// One axis of the aiming loop: what it has learned about how a pixel of mouse
// movement turns this game's camera, and whether the camera has stopped
// answering it. Learning the sign from what a push actually did is what lets
// this work on a game whose mouse look runs the other way; a push that changes
// nothing, tried in both directions, is an axis against a limit of its own.
struct LookAxis
{
	float deg_per_px = LOOK_FIRST_GUESS_DEG_PER_PX;
	int pushed = 0;
	int stall = 0;
	int flips = 0;
	bool stuck = false;
	bool moved_ever = false;

	// A new look command on the same client: what the axis has learned about
	// the game is still true, so only what is about this one command is
	// cleared. The second aim of a run then costs no frames finding the sign
	// again.
	void restart()
	{
		pushed = 0;
		stall = 0;
		flips = 0;
		stuck = false;
	}

	void observe(float delta)
	{
		if(pushed == 0)
			return;
		if(fabsf(delta) > LOOK_MOVED_DEG){
			deg_per_px = delta / (float)pushed;
			stall = 0;
			flips = 0;
			stuck = false;
			moved_ever = true;
			return;
		}
		// Not at once: a push takes a frame or two to come back around
		// through SDL and the game's own update
		if(++stall < LOOK_FLIP_FRAMES)
			return;
		stall = 0;
		deg_per_px = -deg_per_px;
		if(++flips >= 2)
			stuck = true;
	}
};

extern client::Config g_client_config;
extern volatile sig_atomic_t g_shutdown_signal;

static ss_ preferences_path()
{
	return g_client_config.get<ss_>("user_path")+"/preferences.json";
}

namespace app {

// Every preference -o and preferences.json can carry is listed here once, so
// that the flag and the file cannot drift apart.
bool parse_preference_options(const ss_ &s, Options *opt, ss_ *error)
{
	size_t i = 0;
	while(i < s.size()){
		size_t comma = s.find(',', i);
		if(comma == ss_::npos)
			comma = s.size();
		ss_ item = s.substr(i, comma - i);
		i = comma + 1;
		if(item.empty())
			continue;
		size_t eq = item.find('=');
		if(eq == ss_::npos){
			*error = "\""+item+"\": expected key=value";
			return false;
		}
		ss_ key = item.substr(0, eq);
		ss_ value = item.substr(eq + 1);
		char *end = nullptr;
		double v = strtod(value.c_str(), &end);
		if(value.empty() || *end != '\0'){
			*error = key+": \""+value+"\" is not a number";
			return false;
		}
		bool in_range = true;
		if(key == "render_scale"){
			// Below 2 is undersampling, which is the point; above it is
			// supersampling, which the same code path gives away for free
			in_range = (v >= 0.1 && v <= 2.0);
			opt->graphics.render_scale = (float)v;
		} else if(key == "vsync"){
			opt->graphics.vsync = (v != 0);
		} else if(key == "max_fps"){
			in_range = (v >= 0 && v <= 1000);
			opt->graphics.max_fps = (int)v;
		} else if(key == "multisampling"){
			in_range = (v == 1 || v == 2 || v == 4 || v == 8 || v == 16);
			opt->graphics.multisampling = (int)v;
		} else if(key == "sound_volume"){
			in_range = (v >= 0.0 && v <= 1.0);
			opt->sound_volume = (float)v;
		} else if(key == "sound_mute"){
			opt->sound_mute = (v != 0);
		} else {
			*error = "unknown preference \""+key+"\"";
			return false;
		}
		if(!in_range){
			*error = key+": "+value+" is out of range";
			return false;
		}
	}
	return true;
}

}

static void check_parse_preference_options()
{
	app::Options o;
	ss_ err;
	if(!app::parse_preference_options(
			"render_scale=0.5,vsync=0,sound_mute=1", &o, &err))
		throw Exception("parse_preference_options: "+err);
	if(o.graphics.render_scale != 0.5f || o.graphics.vsync || !o.sound_mute)
		throw Exception("parse_preference_options: wrong values");
	// What an item does not name is left alone
	if(o.graphics.max_fps != app::Options().graphics.max_fps)
		throw Exception("parse_preference_options: clobbered max_fps");
	if(app::parse_preference_options("render_scale", &o, &err))
		throw Exception("parse_preference_options: took a bare key");
	if(app::parse_preference_options("render_scale=0.5x", &o, &err))
		throw Exception("parse_preference_options: took a non-number");
	if(app::parse_preference_options("render_scale=9", &o, &err))
		throw Exception("parse_preference_options: took an out-of-range value");
	if(app::parse_preference_options("multisampling=3", &o, &err))
		throw Exception("parse_preference_options: took a bad sample count");
	if(app::parse_preference_options("nonesuch=1", &o, &err))
		throw Exception("parse_preference_options: took an unknown key");
}

// Rounded, and never zero: a window can be dragged small enough that a low
// scale would otherwise ask for a zero-pixel texture.
static int scaled_length(int px, float scale)
{
	int v = (int)(px * scale + 0.5f);
	return v < 1 ? 1 : v;
}

// A viewport rect stays in window pixels from the game's point of view, so
// this is the only place the scale is applied to one. IntRect::ZERO means the
// whole target and has to stay that way.
static magic::IntRect scaled_rect(const magic::IntRect &r, float scale)
{
	if(r == magic::IntRect::ZERO)
		return r;
	return magic::IntRect(
			(int)(r.left_ * scale + 0.5f),
			(int)(r.top_ * scale + 0.5f),
			(int)(r.right_ * scale + 0.5f),
			(int)(r.bottom_ * scale + 0.5f));
}

static void check_scaled_viewport_size()
{
	if(scaled_length(1280, 0.5f) != 640 || scaled_length(720, 0.5f) != 360)
		throw Exception("scaled_length: even");
	if(scaled_length(721, 0.5f) != 361)
		throw Exception("scaled_length: rounding");
	if(scaled_length(4, 0.1f) != 1)
		throw Exception("scaled_length: minimum of one pixel");
	if(scaled_length(1280, 1.5f) != 1920)
		throw Exception("scaled_length: above one");
	// games/bomber_drone's second viewport: the same factor, so the two
	// halves still meet
	magic::IntRect r = scaled_rect(magic::IntRect(0, 360, 1280, 720), 0.5f);
	if(r.left_ != 0 || r.top_ != 180 || r.right_ != 640 || r.bottom_ != 360)
		throw Exception("scaled_rect: rect");
	if(scaled_rect(magic::IntRect::ZERO, 0.5f) != magic::IntRect::ZERO)
		throw Exception("scaled_rect: whole target");
}

static bool desktop_size(int *w, int *h)
{
	if(!SDL_WasInit(SDL_INIT_VIDEO)){
		if(SDL_InitSubSystem(SDL_INIT_VIDEO) != 0)
			return false;
	}
	SDL_DisplayMode mode;
	if(SDL_GetDesktopDisplayMode(0, &mode) != 0)
		return false;
	if(mode.w < 1 || mode.h < 1)
		return false;
	*w = mode.w;
	*h = mode.h;
	return true;
}

// Half the desktop height, at least 720p, at most 75%. 16:9. If the short
// side is already in the UI integer-scale band, nudge to n*1080 x 16:9 when
// that still leaves ~15% desktop margin. 1080p -> 1280x720; 4K -> 1920x1080.
static void pick_default_window_size(int desk_w, int desk_h, int *out_w, int *out_h)
{
	if(desk_w < MIN_WINDOW_W)
		desk_w = MIN_WINDOW_W;
	if(desk_h < 480)
		desk_h = 480;

	int h = desk_h / 2;
	if(h < 720)
		h = 720;
	int max_h = desk_h * 3 / 4;
	if(h > max_h)
		h = max_h;
	int w = h * 16 / 9;
	int max_w = desk_w * 85 / 100;
	if(w > max_w){
		w = max_w;
		h = w * 9 / 16;
	}
	if(w < MIN_WINDOW_W)
		w = MIN_WINDOW_W;
	if(h < MIN_WINDOW_H)
		h = MIN_WINDOW_H;
	if(w > desk_w)
		w = desk_w;
	if(h > desk_h)
		h = desk_h;

	int short_side = w < h ? w : h;
	float s = (float)short_side / UI_REF_SHORT;
	int n = (int)(s + 0.5f);
	if(n >= 1 &&
			s >= (float)n * (1.f - UI_SNAP_UNDER) &&
			s <= (float)n * (1.f + UI_SNAP_OVER)){
		int snap_h = n * (int)UI_REF_SHORT;
		int snap_w = snap_h * 16 / 9;
		if(snap_w <= desk_w * 85 / 100 && snap_h <= desk_h * 85 / 100 &&
				snap_w >= MIN_WINDOW_W && snap_h >= MIN_WINDOW_H){
			w = snap_w;
			h = snap_h;
		}
	}

	*out_w = w;
	*out_h = h;
}

static void check_pick_default_window_size()
{
	int w = 0;
	int h = 0;
	pick_default_window_size(1920, 1080, &w, &h);
	if(w != 1280 || h != 720)
		throw Exception("pick_default_window_size 1080p");
	pick_default_window_size(3840, 2160, &w, &h);
	if(w != 1920 || h != 1080)
		throw Exception("pick_default_window_size 4K");
}

static bool window_is_maximized(magic::Graphics *g)
{
	SDL_Window *win = g ? g->GetWindow() : nullptr;
	if(!win)
		return false;
	return (SDL_GetWindowFlags(win) & SDL_WINDOW_MAXIMIZED) != 0;
}

// Reads the saved preferences into *opt. A missing field keeps its default,
// so a file written by an older build is read by a newer one; a field that is
// present but out of range drops the whole set back to the defaults, because
// a file that has been edited into nonsense is better answered with something
// known than with half of it. The return value is about the window geometry
// alone: it is the one thing that has somewhere else to come from.
static bool load_preferences(int desk_w, int desk_h, app::Options *opt)
{
	json::json_error_t err;
	json::Value o = json::load_file(preferences_path().c_str(), &err);
	if(!o.is_object())
		return false;

	ss_ pref_err;
	const json::Value &jrs = o.get("render_scale");
	const json::Value &jvs = o.get("vsync");
	const json::Value &jmf = o.get("max_fps");
	const json::Value &jms = o.get("multisampling");
	const json::Value &jsv = o.get("sound_volume");
	const json::Value &jsm = o.get("sound_mute");
	// Through the same parser as -o, so that the range checks are written
	// once and a hand-edited file is refused the same way a flag is
	ss_ items;
	if(jrs.is_number())
		items += ss_()+(items.empty()?"":",")+"render_scale="+ftos(jrs.as_number());
	if(jvs.is_boolean())
		items += ss_()+(items.empty()?"":",")+"vsync="+(jvs.as_boolean()?"1":"0");
	if(jmf.is_integer())
		items += ss_()+(items.empty()?"":",")+"max_fps="+itos(jmf.as_integer());
	if(jms.is_integer())
		items += ss_()+(items.empty()?"":",")+"multisampling="+itos(jms.as_integer());
	if(jsv.is_number())
		items += ss_()+(items.empty()?"":",")+"sound_volume="+ftos(jsv.as_number());
	if(jsm.is_boolean())
		items += ss_()+(items.empty()?"":",")+"sound_mute="+(jsm.as_boolean()?"1":"0");
	if(!items.empty()){
		app::Options parsed = *opt;
		if(!app::parse_preference_options(items, &parsed, &pref_err))
			log_w(MODULE, "%s: %s; using defaults",
					cs(preferences_path()), cs(pref_err));
		else
			*opt = parsed;
	}

	// -w said what the size is, so the file does not get to
	if(opt->graphics.size_forced)
		return true;
	const json::Value &jw = o.get("width");
	const json::Value &jh = o.get("height");
	if(!jw.is_integer() || !jh.is_integer())
		return false;
	int rw = (int)jw.as_integer();
	int rh = (int)jh.as_integer();
	if(rw < MIN_WINDOW_W || rh < MIN_WINDOW_H || rw > desk_w || rh > desk_h)
		return false;
	opt->graphics.window_w = rw;
	opt->graphics.window_h = rh;
	const json::Value &jm = o.get("maximized");
	const json::Value &jf = o.get("fullscreen");
	opt->graphics.maximized = jm.is_boolean() && jm.as_boolean();
	opt->graphics.fullscreen = jf.is_boolean() && jf.as_boolean();
	return true;
}

static void save_preferences(const app::Options &opt)
{
	// Nothing that came from the command line is remembered: -w's size, -o's
	// preferences, and a -c run's whole set of them
	if(opt.preferences_disabled || !opt.preference_overrides.empty() ||
			opt.graphics.size_forced)
		return;
	if(opt.graphics.window_w < MIN_WINDOW_W ||
			opt.graphics.window_h < MIN_WINDOW_H)
		return;
	json::Value o = json::object();
	o.set("width", opt.graphics.window_w);
	o.set("height", opt.graphics.window_h);
	o.set("maximized", opt.graphics.maximized);
	o.set("fullscreen", opt.graphics.fullscreen);
	o.set("render_scale", opt.graphics.render_scale);
	o.set("vsync", opt.graphics.vsync);
	o.set("max_fps", opt.graphics.max_fps);
	o.set("multisampling", opt.graphics.multisampling);
	o.set("sound_volume", opt.sound_volume);
	o.set("sound_mute", opt.sound_mute);
	o.save_file(preferences_path().c_str());
}

static void resolve_preferences(app::Options *opt)
{
	int desk_w = 0;
	int desk_h = 0;
	if(!desktop_size(&desk_w, &desk_h)){
		desk_w = 1920;
		desk_h = 1080;
	}
	// -w says what the size is, so nothing else has to; -c reads no file at
	// all, and then the size can only come from the default
	bool size_ok = opt->graphics.size_forced;
	if(!opt->preferences_disabled && load_preferences(desk_w, desk_h, opt))
		size_ok = true;
	if(!size_ok)
		pick_default_window_size(desk_w, desk_h,
				&opt->graphics.window_w, &opt->graphics.window_h);
}

static bool valid_game_name(const ss_ &name)
{
	if(name.empty() || name.size() > 64)
		return false;
	for(char c : name){
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	}
	return true;
}

// Survives CApp reboot so disconnect can kill the server we started.
static interface::process::Handle g_local_server;
// Port the local server was told to listen on ("" if none was started)
static ss_ g_local_server_port;

// simplified: A free port is picked by probing; a race with another process
// grabbing it in between is possible but harmless for a local game (the server
// exits and the menu says so). Upgrade path: have the server bind port 0 and
// report the actual port back to the client.
static ss_ pick_free_local_port()
{
	std::random_device rd;
	for(int i = 0; i < 100; i++){
		// 29168...29999 is unassigned in IANA's registry and below the
		// ephemeral port range, so nothing else should want it
		int port = 29168 + rd() % 832;
		ss_ port_s = std::to_string(port);
		if(!interface::probe_connect("127.0.0.1", port_s))
			return port_s;
	}
	return "29500";
}

static ss_ pidfile_path()
{
	return g_client_config.get<ss_>("cache_path")+"/local_server.pid";
}

static void clear_pidfile()
{
	remove(pidfile_path().c_str());
}

static void write_pidfile()
{
#ifndef _WIN32
	if(!g_local_server.valid())
		return;
	FILE *f = fopen(pidfile_path().c_str(), "w");
	if(!f)
		return;
	fprintf(f, "%ld\n", (long)g_local_server.impl);
	fclose(f);
#endif
}

#ifndef _WIN32
static bool exe_is_buildat_server(long pid)
{
	char link[64];
	snprintf(link, sizeof link, "/proc/%ld/exe", pid);
	char buf[PATH_MAX];
	ssize_t n = readlink(link, buf, sizeof buf - 1);
	if(n < 0)
		return false;
	buf[n] = 0;
	const char *base = strrchr(buf, '/');
	base = base ? base + 1 : buf;
	return strcmp(base, "buildat_server") == 0;
}
#endif

static void adopt_pidfile()
{
#ifndef _WIN32
	if(g_local_server.valid() && interface::process::is_running(g_local_server))
		return;
	g_local_server.impl = 0;
	FILE *f = fopen(pidfile_path().c_str(), "r");
	if(!f)
		return;
	long pid = 0;
	if(fscanf(f, "%ld", &pid) != 1 || pid <= 0){
		fclose(f);
		clear_pidfile();
		return;
	}
	fclose(f);
	if(!exe_is_buildat_server(pid)){
		clear_pidfile();
		return;
	}
	g_local_server.impl = pid;
	if(!interface::process::is_running(g_local_server)){
		g_local_server.impl = 0;
		clear_pidfile();
		return;
	}
	log_i(MODULE, "Adopted leftover local server pid %ld", pid);
#endif
}

static void request_stop_local_server()
{
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	if(!interface::process::is_running(g_local_server)){
		g_local_server.impl = 0;
		clear_pidfile();
		return;
	}
	log_i(MODULE, "Stopping local server");
	interface::process::request_terminate(g_local_server);
}

static void force_kill_local_server()
{
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	log_w(MODULE, "Force-killing local server");
	interface::process::kill_force(g_local_server);
	clear_pidfile();
}

// Quit path: SIGTERM, wait 10s, SIGKILL. No dialog (window is closing).
static void stop_local_server()
{
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	log_i(MODULE, "Stopping local server");
	interface::process::terminate(g_local_server);
	clear_pidfile();
	for(int i = 0; i < 40; i++){
		if(!interface::probe_connect("127.0.0.1", g_local_server_port))
			return;
		interface::os::sleep_us(50000);
	}
	log_w(MODULE, "Local server did not release port %s", cs(g_local_server_port));
}

namespace app {

void GraphicsOptions::apply(magic::Graphics *magic_graphics)
{
	int w = fullscreen ? full_w : window_w;
	int h = fullscreen ? full_h : window_h;
	magic_graphics->SetMode(w, h, fullscreen, borderless, resizable,
			false, vsync, triple_buffer, multisampling, 0, 0);
}

class BuildatResourceRouter: public magic::ResourceRouter
{
	URHO3D_OBJECT(BuildatResourceRouter, magic::ResourceRouter);

	sp_<client::State> m_client;
public:
	BuildatResourceRouter(magic::Context *context):
		magic::ResourceRouter(context)
	{}
	void set_client(sp_<client::State> client)
	{
		m_client = client;
	}

	void Route(magic::String &name, magic::ResourceRequest requestType)
	{
		if(!m_client){
			log_w(MODULE, "Resource route access: %s (client not initialized)",
					name.CString());
			return;
		}
		ss_ orig(name.CString());
		ss_ path = m_client->get_file_path(orig);
		if(path == ""){
			log_v(MODULE, "Resource route access: %s (assuming local file)",
					name.CString());
			// NOTE: Path safety is checked by magic::FileSystem
			return;
		}
		// Cache files are stored as a bare hash. Urho Sound (and some
		// other loaders) pick the decoder from the File path extension.
		magic::String ext = magic::GetExtension(name);
		if(!ext.Empty()){
			ss_ hex = path;
			size_t slash = hex.rfind('/');
			if(slash != ss_::npos)
				hex = hex.substr(slash + 1);
			ss_ dest = g_client_config.get<ss_>("cache_path")+
					"/tmp/"+hex+ext.CString();
			if(!interface::fs::path_exists(dest)){
				if(!interface::fs::copy_file(path, dest)){
					log_w(MODULE, "Resource route copy failed: %s -> %s",
							cs(path), cs(dest));
				} else {
					path = dest;
				}
			} else {
				path = dest;
			}
		}
		log_v(MODULE, "Resource route access: %s -> %s",
				name.CString(), cs(path));
		name = path.c_str();
	}
};

struct CApp: public App, public magic::Application
{
	sp_<client::State> m_state;
	BuildatResourceRouter *m_router;
	magic::LuaScript *m_script;
	lua_State *L;
	// shutdown() is not instant; the frames until the window closes must not
	// each call it again
	bool m_shutdown_signal_handled = false;
	float m_ui_scale_lua = 0.f; // 0 = not set by Lua
	bool m_restore_maximized = false;
	Options m_options;
	bool m_draw_debug_geometry = false;
	int64_t m_last_update_us;

	sv_<client::command_seq::Command> m_commands;
	size_t m_command_index = 0;
	int64_t m_command_wait_until_us = 0;
	ss_ m_pending_screenshot;
	bool m_command_seq_active = false;
	// -c - : commands arrive from standard input while the client runs, and
	// the run ends at end of input rather than when the list is used up
	bool m_command_seq_stdin = false;
	bool m_command_seq_stdin_eof = false;
	bool m_command_seq_failed = false;
	bool m_command_seq_extra_frame = false;

	// The look command, which aims the camera by injecting mouse movement
	// and watching what the camera does about it. Nothing here knows what
	// game is running: how far a pixel turns the camera, and which way, is
	// measured from the last frame's injection rather than assumed.
	// What the command log line has already been written for, so that a
	// command that takes several frames is announced once
	int m_command_logged_index = -1;
	bool m_look_running = false;
	LookAxis m_look_x;
	LookAxis m_look_y;
	float m_look_last_yaw = 0.0f;
	float m_look_last_pitch = 0.0f;
	bool m_look_had_angles = false;
	int m_look_frames = 0;
	int m_look_no_camera_frames = 0;

	magic::SharedPtr<magic::Scene> m_scene;
	magic::SharedPtr<magic::Node> m_camera_node;

	// What set_preferred_viewports() was last given, and the rects the game
	// gave them in -- in window pixels, so that the scale can be applied
	// again from scratch when the window changes size
	sv_<magic::SharedPtr<magic::Viewport>> m_preferred_viewports;
	sv_<magic::IntRect> m_preferred_rects;
	magic::SharedPtr<magic::Texture2D> m_preferred_texture;
	magic::SharedPtr<magic::BorderImage> m_preferred_image;

	sp_<interface::thread_pool::ThreadPool> m_thread_pool;

	CApp(magic::Context *context, const Options &options):
		magic::Application(context),
		m_script(nullptr),
		L(nullptr),
		m_options(options),
		m_last_update_us(get_timeofday_us()),
		m_thread_pool(interface::thread_pool::createThreadPool())
	{
		log_v(MODULE, "constructor()");
		check_pick_default_window_size();
		check_parse_preference_options();
		check_scaled_viewport_size();
		// A -c run is on the built-in defaults, and muted: nothing captures
		// audio, and a driven run playing a game's music through the
		// developer's speakers is a small recurring annoyance with no upside
		m_options.preferences_disabled =
				g_client_config.get<bool>("command_seq_enabled");
		if(m_options.preferences_disabled)
			m_options.sound_mute = true;
		resolve_preferences(&m_options);
		if(!m_options.preference_overrides.empty()){
			// Already accepted once in main(), where a bad -o is a usage
			// error rather than a startup failure
			ss_ err;
			if(!parse_preference_options(m_options.preference_overrides,
					&m_options, &err))
				throw AppStartupError("-o: "+err);
		}
		if(m_options.graphics.size_forced){
			m_options.graphics.fullscreen = false;
			m_options.graphics.maximized = false;
		}
		log_v(MODULE, "preferences: render_scale=%s vsync=%i max_fps=%i"
				" multisampling=%i sound_volume=%s sound_mute=%i",
				cs(ftos(m_options.graphics.render_scale)),
				m_options.graphics.vsync ? 1 : 0,
				m_options.graphics.max_fps,
				m_options.graphics.multisampling,
				cs(ftos(m_options.sound_volume)),
				m_options.sound_mute ? 1 : 0);
		m_restore_maximized = m_options.graphics.maximized;
		log_v(MODULE, "window size: %ix%i maximized=%i fullscreen=%i",
				m_options.graphics.window_w, m_options.graphics.window_h,
				m_options.graphics.maximized ? 1 : 0,
				m_options.graphics.fullscreen ? 1 : 0);

		m_thread_pool->start(4); // TODO: Configurable

		sv_<ss_> resource_paths = {
			g_client_config.get<ss_>("share_path")+"/client/data",
			g_client_config.get<ss_>("cache_path")+"/tmp",
			g_client_config.get<ss_>("share_path")+"/extensions", // Could be unsafe
			g_client_config.get<ss_>("urho3d_path")+"/bin/CoreData",
			g_client_config.get<ss_>("urho3d_path")+"/bin/Data",
		};
		ss_ resource_paths_s;
		for(const ss_ &path : resource_paths){
			if(!resource_paths_s.empty())
				resource_paths_s += ";";
			resource_paths_s += interface::fs::get_absolute_path(path);
		}

		// Set allowed paths in urho3d filesystem (part of sandbox)
		magic::FileSystem *magic_fs = GetSubsystem<magic::FileSystem>();
		for(const ss_ &path : resource_paths){
			magic_fs->RegisterPath(interface::fs::get_absolute_path(path).c_str());
		}
		magic_fs->RegisterPath(interface::fs::get_absolute_path(
				g_client_config.get<ss_>("cache_path")).c_str());

		// Useful for saving stuff for inspection when debugging
		magic_fs->RegisterPath("/tmp");

		// Set Urho3D engine parameters
		engineParameters_["WindowTitle"] = "Buildat Client";
		engineParameters_["Headless"] = false;
		engineParameters_["ResourcePaths"] = resource_paths_s.c_str();
		engineParameters_["AutoloadPaths"] = "";
		engineParameters_["LogName"] = "";
		engineParameters_["LogQuiet"] = true; // Don't log to stdout

		// Graphics options
		engineParameters_["FullScreen"] = m_options.graphics.fullscreen;
		if(m_options.graphics.fullscreen){
			engineParameters_["WindowWidth"] = m_options.graphics.full_w;
			engineParameters_["WindowHeight"] = m_options.graphics.full_h;
		} else {
			engineParameters_["WindowWidth"] = m_options.graphics.window_w;
			engineParameters_["WindowHeight"] = m_options.graphics.window_h;
			engineParameters_["WindowResizable"] = m_options.graphics.resizable;
		}
		engineParameters_["VSync"] = m_options.graphics.vsync;
		engineParameters_["TripleBuffer"] = m_options.graphics.triple_buffer;
		engineParameters_["Multisample"] = m_options.graphics.multisampling;

		magic::Log *magic_log = GetSubsystem<magic::Log>();
		// Disable timestamps in log messages (also added to events)
		magic_log->SetTimeStamp(false);

		// Set up event handlers
		SubscribeToEvent(magic::E_BEGINFRAME, URHO3D_HANDLER(CApp, on_begin_frame));
		SubscribeToEvent(magic::E_UPDATE, URHO3D_HANDLER(CApp, on_update));
		SubscribeToEvent(magic::E_POSTRENDERUPDATE,
				URHO3D_HANDLER(CApp, on_post_render_update));
		SubscribeToEvent(magic::E_ENDRENDERING,
				URHO3D_HANDLER(CApp, on_end_rendering));
		SubscribeToEvent(magic::E_KEYDOWN, URHO3D_HANDLER(CApp, on_keydown));
		SubscribeToEvent(magic::E_SCREENMODE, URHO3D_HANDLER(CApp, on_screenmode));
		SubscribeToEvent(magic::E_LOGMESSAGE, URHO3D_HANDLER(CApp, on_logmessage));

		// Default to not grabbing the mouse
		magic::Input *magic_input = GetSubsystem<magic::Input>();
		magic_input->SetMouseVisible(true);

		// Default to auto-loading resources as they are modified
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic_cache->SetAutoReloadResources(true);
		m_router = new BuildatResourceRouter(context_);
		magic_cache->AddResourceRouter(m_router);
	}

	~CApp()
	{
		stop_local_server();
	}

	void set_state(sp_<client::State> state)
	{
		m_state = state;
		m_router->set_client(state);
	}

	int run()
	{
		int r = magic::Application::Run();
		if(m_command_seq_failed)
			return 1;
		if(m_command_seq_active)
			return 1;
		return r;
	}

	void shutdown()
	{
		log_v(MODULE, "shutdown()");
		// Whatever is running has one last chance to close what it opened.
		// A network client that vanishes without saying goodbye is left on
		// the server until it times out, and the next client to connect
		// under the same name is refused; Urho3D sends this event when the
		// window is closed and nowhere else, so the paths that exit without
		// the window -- a command sequence ending, an error -- send it here.
		SendEvent(magic::E_EXITREQUESTED);
		stop_local_server();

		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		if(g){
			m_options.graphics.fullscreen = g->GetFullscreen();
			if(!m_options.graphics.fullscreen)
				m_options.graphics.maximized = window_is_maximized(g);
			save_preferences(m_options);
		}

		magic::Engine *engine = GetSubsystem<magic::Engine>();
		engine->Exit();
	}

	void run_script(const ss_ &script)
	{
		log_v(MODULE, "run_script():\n%s", cs(script));

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_run_code_in_sandbox");
		lua_pushlstring(L, script.c_str(), script.size());
		error_logging_pcall(L, 1, 1);
		bool status = lua_toboolean(L, -1);
		lua_pop(L, 1);
		if(status == false){
			log_w(MODULE, "run_script(): failed");
		} else {
			log_v(MODULE, "run_script(): succeeded");
		}
	}

	bool run_script_no_sandbox(const ss_ &script)
	{
		log_v(MODULE, "run_script_no_sandbox():\n%s", cs(script));

		// TODO: Use lua_load() so that chunkname can be set
		if(luaL_loadstring(L, script.c_str())){
			ss_ error = lua_bindings::lua_tocppstring(L, -1);
			log_e("%s", cs(error));
			lua_pop(L, 1);
			return false;
		}
		error_logging_pcall(L, 0, 0);
		return true;
	}

	void handle_packet(const ss_ &name, const ss_ &data)
	{
		log_v(MODULE, "handle_packet(): %s", cs(name));

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_handle_packet");
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, data.c_str(), data.size());
		error_logging_pcall(L, 2, 0);
	}

	void file_updated_in_cache(const ss_ &file_name,
			const ss_ &file_hash, const ss_ &cached_path)
	{
		log_v(MODULE, "file_updated_in_cache(): %s", cs(file_name));

		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic_cache->ReloadResourceWithDependencies(file_name.c_str());

		/*lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_file_updated_in_cache");
		if(lua_isnil(L, -1)){
			lua_pop(L, 1);
			return;
		}
		lua_pushlstring(L, file_name.c_str(), file_name.size());
		lua_pushlstring(L, file_hash.c_str(), file_hash.size());
		lua_pushlstring(L, cached_path.c_str(), cached_path.size());
		error_logging_pcall(L, 3, 0);*/
	}

	magic::Scene* get_scene()
	{
		return m_scene;
	}

	interface::thread_pool::ThreadPool* get_thread_pool()
	{
		return m_thread_pool.get();
	}

	lua_State* get_lua()
	{
		return L;
	}

	// Non-public methods

	void apply_ui_scale()
	{
		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!g || !ui)
			return;
		float s = 0.f;
		if(m_ui_scale_lua > 0.f)
			s = m_ui_scale_lua;
		else {
			double cfg = g_client_config.get<double>("ui_scale");
			if(cfg > 0)
				s = (float)cfg;
			else {
				int short_side = g->GetWidth();
				if(g->GetHeight() < short_side)
					short_side = g->GetHeight();
				s = (float)short_side / UI_REF_SHORT;
				if(s < 0.01f)
					s = 0.01f;
				else {
					int n = (int)(s + 0.5f);
					if(n >= 1 &&
							s >= (float)n * (1.f - UI_SNAP_UNDER) &&
							s <= (float)n * (1.f + UI_SNAP_OVER))
						s = (float)n;
				}
			}
		}
		ui->SetScale(s);
		log_i(MODULE, "UI scale %g (%ix%i)", s, g->GetWidth(), g->GetHeight());
	}

	void Start()
	{
		log_v(MODULE, "Start()");

		apply_ui_scale();

		GetSubsystem<magic::Engine>()->SetMaxFps(m_options.graphics.max_fps);
		apply_sound_preferences();

		if(!m_options.graphics.fullscreen && m_restore_maximized){
			magic::Graphics *g = GetSubsystem<magic::Graphics>();
			if(g){
				g->Maximize();
				m_options.graphics.maximized = true;
				save_preferences(m_options);
			}
			m_restore_maximized = false;
		}

		// Instantiate and register the Lua script subsystem so that we can use the LuaScriptInstance component
		context_->RegisterSubsystem(new magic::LuaScript(context_));

		m_script = context_->GetSubsystem<magic::LuaScript>();
		L = m_script->GetState();
		if(L == nullptr)
			throw Exception("m_script.GetState() returned null");

		// Store current CApp instance in registry
		lua_pushlightuserdata(L, (void*)this);
		lua_setfield(L, LUA_REGISTRYINDEX, "__buildat_app");

		lua_bindings::init(L);

#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setglobal(L, "__buildat_" #name); \
}

		DEF_BUILDAT_FUNC(connect_server)
		DEF_BUILDAT_FUNC(disconnect)
		DEF_BUILDAT_FUNC(list_games)
		DEF_BUILDAT_FUNC(start_local_server)
		DEF_BUILDAT_FUNC(stop_local_server)
		DEF_BUILDAT_FUNC(request_stop_local_server)
		DEF_BUILDAT_FUNC(force_kill_local_server)
		DEF_BUILDAT_FUNC(local_server_ready)
		DEF_BUILDAT_FUNC(local_server_running)
		DEF_BUILDAT_FUNC(local_server_port)
		DEF_BUILDAT_FUNC(send_packet);
		DEF_BUILDAT_FUNC(get_file_path)
		DEF_BUILDAT_FUNC(get_file_content)
		DEF_BUILDAT_FUNC(get_path)
		DEF_BUILDAT_FUNC(extension_path)
		DEF_BUILDAT_FUNC(set_ui_scale)
		DEF_BUILDAT_FUNC(get_ui_scale)
		DEF_BUILDAT_FUNC(get_preferred_render_scale)

		// Create a scene that will be synchronized from the server
		m_scene = new magic::Scene(context_);
		m_scene->CreateComponent<magic::Octree>(magic::LOCAL);
		m_scene->CreateComponent<magic::PhysicsWorld>(magic::LOCAL);
		m_scene->CreateComponent<magic::DebugRenderer>(magic::LOCAL);

		// Push the scene to the Lua environment
		lua_bindings::replicate::set_scene(L, m_scene);

		// Run initial client Lua scripts
		ss_ init_lua_path = g_client_config.get<ss_>("share_path")+
				"/client/init.lua";
		int error = luaL_dofile(L, init_lua_path.c_str());
		if(error){
			log_w(MODULE, "luaL_dofile: An error occurred: %s\n",
					lua_tostring(L, -1));
			lua_pop(L, 1);
			throw AppStartupError("Could not initialize Lua environment");
		}

		// Launch menu if requested
		if(g_client_config.get<bool>("boot_to_menu")){
			ss_ extname = g_client_config.get<ss_>("menu_extension_name");
			ss_ script = ss_() +
					"local m = require('buildat/extension/"+extname+"')\n"
					"if type(m) ~= 'table' then\n"
					"    error('Failed to load extension "+extname+"')\n"
					"end\n"
					"m.boot()\n";
			if(!run_script_no_sandbox(script)){
				throw AppStartupError(ss_()+
						"Failed to load and run extension "+extname);
			}
		}

		// Create debug HUD
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic::DebugHud *dhud = GetSubsystem<magic::Engine>()->CreateDebugHud();
		dhud->SetDefaultStyle(magic_cache->GetResource<magic::XMLFile>(
				"UI/DefaultStyle.xml"));

		if(g_client_config.get<bool>("command_seq_enabled")){
			ss_ text = g_client_config.get<ss_>("command_seq");
			ss_ err;
			if(!client::command_seq::parse(text, &m_commands, &err))
				throw AppStartupError("command sequence: "+err);
			m_command_seq_stdin =
					g_client_config.get<bool>("command_seq_stdin");
			m_command_seq_active = true;
			// Urho3D toggles fullscreen on alt+enter. A driven run injects
			// plenty of enters, and SDL's modifier state can have alt in it
			// from an alt+tab the window never saw the release of, which
			// then puts the window into fullscreen in the middle of a
			// sequence -- and a screen mode change loses what was uploaded
			// to the GPU by hand, so the world comes back black.
			GetSubsystem<magic::Input>()->SetToggleFullscreen(false);
			client::command_seq::inhibit_real_input(true);
			client::command_seq::show_window(GetSubsystem<magic::Graphics>(),
					GetSubsystem<magic::Input>());
			if(m_command_seq_stdin)
				log_i(MODULE, "Command sequence: reading stdin,"
						" will exit at end of input");
			else
				log_i(MODULE, "Command sequence: %zu commands,"
						" will exit when done", m_commands.size());
		}
	}

	void command_seq_fail(const ss_ &err)
	{
		log_e(MODULE, "Command sequence failed: %s", cs(err));
		m_command_seq_failed = true;
		m_command_seq_active = false;
		client::command_seq::inhibit_real_input(false);
		client::command_seq::release_forced_focus(
				GetSubsystem<magic::Input>());
		shutdown();
	}

	void command_seq_finish()
	{
		if(m_command_seq_failed)
			return;
		if(!m_command_seq_extra_frame){
			m_command_seq_extra_frame = true;
			return;
		}
		log_i(MODULE, "Command sequence complete");
		m_command_seq_active = false;
		client::command_seq::inhibit_real_input(false);
		client::command_seq::release_forced_focus(
				GetSubsystem<magic::Input>());
		shutdown();
	}

	// Game code may SetMouseVisible(false) / grab. Do not actually capture
	// the OS mouse; injected mouse_move is relative (GetMouseMove) and does
	// not need a cursor position.
	void command_seq_keep_mouse_free()
	{
		if(!m_command_seq_active)
			return;
		magic::Input *input = GetSubsystem<magic::Input>();
		if(!input)
			return;
		bool changed = false;
		if(input->GetMouseMode() == magic::MM_RELATIVE ||
				input->GetMouseMode() == magic::MM_WRAP){
			input->SetMouseMode(magic::MM_ABSOLUTE);
			changed = true;
		}
		if(!input->IsMouseVisible()){
			input->SetMouseVisible(true);
			changed = true;
		}
		if(input->IsMouseGrabbed()){
			input->SetMouseGrabbed(false);
			changed = true;
		}
		if(changed)
			client::command_seq::absorb_mouse_move_suppression(input);
	}

	// Where the camera of the first viewport points: yaw from +Z towards +X
	// and pitch upwards, both in degrees. False when there is no camera --
	// a game that has not made one yet, or a menu.
	bool camera_angles(float *yaw, float *pitch)
	{
		auto *renderer = GetSubsystem<magic::Renderer>();
		if(!renderer || renderer->GetNumViewports() < 1)
			return false;
		magic::Viewport *viewport = renderer->GetViewport(0);
		if(!viewport)
			return false;
		magic::Camera *camera = viewport->GetCamera();
		if(!camera || !camera->GetNode())
			return false;
		magic::Vector3 d = camera->GetNode()->GetWorldDirection();
		if(d.LengthSquared() < 1e-12f)
			return false;
		d.Normalize();
		*yaw = magic::Atan2(d.x_, d.z_);
		*pitch = magic::Asin(d.y_);
		return true;
	}

	static float wrap_degrees(float a)
	{
		while(a > 180.0f)
			a -= 360.0f;
		while(a < -180.0f)
			a += 360.0f;
		return a;
	}

	// How many pixels to ask for on one axis this frame. Never more than a
	// LOOK_MAX_STEP_DEG turn, because a game that smooths its mouse look
	// rings if it is asked to cross the sky at once, and never zero while
	// there is still an error to close, because a rounded-down step would
	// stall the loop short of the target.
	static int look_step_px(float err, float deg_per_px, float tolerance)
	{
		if(fabsf(err) <= tolerance)
			return 0;
		if(fabsf(deg_per_px) < 1e-6f)
			return err > 0.0f ? 1 : -1;
		float px = err / deg_per_px;
		float limit = LOOK_MAX_STEP_DEG / fabsf(deg_per_px);
		if(px > limit)
			px = limit;
		if(px < -limit)
			px = -limit;
		int i = (int)(px >= 0.0f ? px + 0.5f : px - 0.5f);
		if(i == 0)
			i = px >= 0.0f ? 1 : -1;
		return i;
	}

	// One frame of the look command. True when the camera has arrived; on
	// failure it calls command_seq_fail(), which shuts the client down.
	bool command_seq_look(const client::command_seq::Command &c)
	{
		float yaw = 0.0f, pitch = 0.0f;
		bool have = camera_angles(&yaw, &pitch);

		if(!m_look_running){
			m_look_running = true;
			m_look_frames = 0;
			m_look_no_camera_frames = 0;
			m_look_had_angles = false;
			m_look_x.restart();
			m_look_y.restart();
		}

		if(!have){
			// Nothing to steer by. A game that has not made its camera yet
			// gets a few frames; one that never does is not aimable.
			if(++m_look_no_camera_frames >= LOOK_STILL_FRAMES){
				m_look_running = false;
				command_seq_fail("look: there is no camera on viewport 0");
				return false;
			}
			m_look_had_angles = false;
			return false;
		}
		m_look_no_camera_frames = 0;

		// What the last frame's push did, which is the only thing here that
		// knows anything about the game running
		if(m_look_had_angles){
			m_look_x.observe(wrap_degrees(yaw - m_look_last_yaw));
			m_look_y.observe(pitch - m_look_last_pitch);
		}

		if(m_look_x.stuck && m_look_y.stuck &&
				!m_look_x.moved_ever && !m_look_y.moved_ever){
			m_look_running = false;
			command_seq_fail(ss_()+"look: the camera does not follow the "
					"mouse; it stayed at yaw "+ftos(yaw)+" pitch "+
					ftos(pitch)+" however it was pushed");
			return false;
		}

		// A game whose mouse look is coarse cannot be aimed finer than one
		// pixel of it, so the tolerance gives way to that rather than the
		// loop hunting for something it cannot hit
		float tol_x = fmaxf(LOOK_TOLERANCE_DEG,
				0.75f * fabsf(m_look_x.deg_per_px));
		float tol_y = fmaxf(LOOK_TOLERANCE_DEG,
				0.75f * fabsf(m_look_y.deg_per_px));
		float err_yaw = wrap_degrees((float)c.yaw - yaw);
		float err_pitch = (float)c.pitch - pitch;
		// An axis that has moved and then stopped answering in either
		// direction is against a limit the game keeps -- a pitch clamp, most
		// of the time -- and is as arrived as it is going to get
		bool done_x = fabsf(err_yaw) <= tol_x || m_look_x.stuck;
		bool done_y = fabsf(err_pitch) <= tol_y || m_look_y.stuck;
		if(done_x && done_y){
			m_look_running = false;
			if(fabsf(err_yaw) > tol_x || fabsf(err_pitch) > tol_y)
				log_w(MODULE, "look: the camera stops at yaw %.1f pitch %.1f; "
						"asked for yaw %.1f pitch %.1f",
						yaw, pitch, (float)c.yaw, (float)c.pitch);
			else
				log_v(MODULE, "look: arrived at yaw %.1f pitch %.1f in %i "
						"frames", yaw, pitch, m_look_frames);
			return true;
		}

		m_look_x.pushed = m_look_x.stuck ? 0 :
				look_step_px(err_yaw, m_look_x.deg_per_px, tol_x);
		m_look_y.pushed = m_look_y.stuck ? 0 :
				look_step_px(err_pitch, m_look_y.deg_per_px, tol_y);
		m_look_last_yaw = yaw;
		m_look_last_pitch = pitch;
		m_look_had_angles = true;

		log_v(MODULE, "look: at yaw %.2f pitch %.2f, pushing %i,%i at "
				"%.4f,%.4f deg/px", yaw, pitch,
				m_look_x.pushed, m_look_y.pushed,
				m_look_x.deg_per_px, m_look_y.deg_per_px);

		if(m_look_x.pushed != 0 || m_look_y.pushed != 0){
			ss_ err;
			if(!client::command_seq::inject_mouse_move(
					GetSubsystem<magic::Input>(),
					m_look_x.pushed, m_look_y.pushed, &err)){
				m_look_running = false;
				command_seq_fail(err);
				return false;
			}
		}

		if(++m_look_frames >= LOOK_MAX_FRAMES){
			m_look_running = false;
			command_seq_fail(ss_()+"look: the camera did not arrive in "+
					itos(LOOK_MAX_FRAMES)+" frames; it is at yaw "+
					ftos(yaw)+" pitch "+ftos(pitch)+" and was asked for yaw "+
					ftos((float)c.yaw)+" pitch "+ftos((float)c.pitch));
			return false;
		}
		return false;
	}

	bool command_seq_exec(const client::command_seq::Command &c)
	{
		using client::command_seq::Type;
		magic::Input *input = GetSubsystem<magic::Input>();
		ss_ err;
		bool ok = true;
		switch(c.type){
		case Type::KeyDown:
			ok = client::command_seq::inject_key(input, c.s, true, false, &err);
			break;
		case Type::KeyUp:
			ok = client::command_seq::inject_key(input, c.s, false, false, &err);
			break;
		case Type::KeyPress:
			ok = client::command_seq::inject_key(input, c.s, true, true, &err);
			break;
		case Type::MousePos:
			ok = client::command_seq::inject_mouse_pos(input, c.x, c.y, &err);
			break;
		case Type::MouseMove:
			ok = client::command_seq::inject_mouse_move(input, c.x, c.y, &err);
			break;
		case Type::MouseDown:
			ok = client::command_seq::inject_mouse_button(
					input, c.x, true, false, &err);
			break;
		case Type::MouseUp:
			ok = client::command_seq::inject_mouse_button(
					input, c.x, false, false, &err);
			break;
		case Type::MouseClick:
			ok = client::command_seq::inject_mouse_button(
					input, c.x, true, true, &err);
			break;
		case Type::MouseWheel:
			ok = client::command_seq::inject_mouse_wheel(input, (int)c.n, &err);
			break;
		case Type::Text:
			ok = client::command_seq::inject_text(input, c.s, &err);
			break;
		case Type::Quit:
		case Type::Delay:
		case Type::Screenshot:
		case Type::Look:
			return true;
		}
		if(!ok)
			command_seq_fail(err);
		return ok;
	}

	// Whole lines that have arrived on standard input, parsed and appended.
	// A line that does not parse is reported and skipped rather than ending
	// the run: the other end is a person or a script that can try again.
	void command_seq_pump_stdin()
	{
		sv_<ss_> lines;
		bool eof = false;
		client::command_seq::read_stdin_lines(&lines, &eof);
		for(const ss_ &line : lines){
			ss_ err;
			sv_<client::command_seq::Command> parsed;
			if(!client::command_seq::parse(line, &parsed, &err)){
				log_w(MODULE, "command: %s", cs(err));
				continue;
			}
			for(const client::command_seq::Command &c : parsed)
				m_commands.push_back(c);
		}
		if(eof)
			m_command_seq_stdin_eof = true;
	}

	void command_seq_tick()
	{
		using client::command_seq::Type;
		if(!m_command_seq_active)
			return;
		if(!m_pending_screenshot.empty())
			return;
		if(m_command_seq_stdin)
			command_seq_pump_stdin();
		int64_t now = get_timeofday_us();
		if(m_command_wait_until_us > now)
			return;

		while(m_command_index < m_commands.size()){
			const client::command_seq::Command &c =
					m_commands[m_command_index];
			if(m_command_logged_index != (int)m_command_index){
				m_command_logged_index = (int)m_command_index;
				log_i(MODULE, "command: %s",
						cs(client::command_seq::dump_command(c)));
			}
			if(c.type == Type::Delay){
				m_command_wait_until_us = now + c.n * 1000;
				m_command_index++;
				return;
			}
			if(c.type == Type::Screenshot){
				m_pending_screenshot = c.s;
				m_command_index++;
				return;
			}
			if(c.type == Type::Look){
				// One step a frame, so that what the last one did can be
				// seen before the next one is decided
				if(!command_seq_look(c))
					return;
				m_command_index++;
				continue;
			}
			if(c.type == Type::Quit){
				m_command_index = m_commands.size();
				m_command_seq_stdin_eof = true;
				break;
			}
			if(!command_seq_exec(c))
				return;
			m_command_index++;
		}

		if(m_command_index >= m_commands.size() &&
				m_pending_screenshot.empty() &&
				m_command_wait_until_us <= now &&
				(!m_command_seq_stdin || m_command_seq_stdin_eof))
			command_seq_finish();
	}

	void on_update(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		/*magic::AutoProfileBlock profiler_block(
				GetSubsystem<magic::Profiler>(), "App::on_update");*/

		if(g_shutdown_signal != 0 && !m_shutdown_signal_handled){
			m_shutdown_signal_handled = true;
			// SIGINT leaves a "^C" on the terminal to write past
			if(g_shutdown_signal == SIGINT)
				fprintf(stdout, "\n");
			log_i(MODULE, "%s; shutting down",
					g_shutdown_signal == SIGINT ? "SIGINT" : "SIGTERM");
			shutdown();
		}
		if(m_state)
			m_state->update();

		{
			magic::AutoProfileBlock profiler_block(
					GetSubsystem<magic::Profiler>(), "Buildat|ThreadPool::post");
			m_thread_pool->run_post();
		}

#ifdef DEBUG_CORE_TIMING
		int64_t t1 = get_timeofday_us();
		int interval = t1 - m_last_update_us;
		if(interval > 30000)
			log_w(MODULE, "Too long update interval: %ius", interval);
		m_last_update_us = t1;
#endif
	}

	void on_begin_frame(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		command_seq_keep_mouse_free();
		command_seq_tick();
	}

	void on_post_render_update(
			magic::StringHash event_type, magic::VariantMap &event_data)
	{
		if(m_draw_debug_geometry)
			m_scene->GetComponent<magic::PhysicsWorld>()->DrawDebugGeometry(true);
	}

	void on_end_rendering(
			magic::StringHash event_type, magic::VariantMap &event_data)
	{
		if(m_pending_screenshot.empty())
			return;
		ss_ path = m_pending_screenshot;
		m_pending_screenshot.clear();
		ss_ err;
		if(!client::command_seq::save_screenshot(
				GetSubsystem<magic::Graphics>(), path, &err))
			command_seq_fail(err);
	}

	void on_keydown(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		int key = event_data["Key"].GetInt();
		if(key == Urho3D::KEY_F11){
			log_v(MODULE, "F11");
			magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
			if(magic_graphics->GetFullscreen()){
				m_options.graphics.fullscreen = false;
				m_options.graphics.resizable = true;
				m_options.graphics.apply(magic_graphics);
				if(m_options.graphics.maximized)
					magic_graphics->Maximize();
			} else {
				m_options.graphics.fullscreen = true;
				m_options.graphics.resizable = false;
				m_options.graphics.apply(magic_graphics);
			}
		}
		if(key == Urho3D::KEY_F10){
			ss_ extname = "sandbox_test";
			ss_ script = ss_() +
					"local m = require('buildat/extension/"+extname+"')\n"
					"if type(m) ~= 'table' then\n"
					"    error('Failed to load extension "+extname+"')\n"
					"end\n"
					"m.toggle()\n";
			if(!run_script_no_sandbox(script)){
				log_e(MODULE, "Failed to load and run extension %s", cs(extname));
			}
		}
		if(key == Urho3D::KEY_F9){
			magic::DebugHud *dhud = GetSubsystem<magic::Engine>()->CreateDebugHud();
			dhud->ToggleAll();
		}
		if(key == Urho3D::KEY_F8){
			m_draw_debug_geometry = !m_draw_debug_geometry;
		}
	}

	void set_preferred_viewports(const sv_<magic::Viewport*> &viewports)
	{
		m_preferred_viewports.clear();
		m_preferred_rects.clear();
		for(magic::Viewport *vp : viewports){
			m_preferred_viewports.push_back(magic::SharedPtr<magic::Viewport>(vp));
			m_preferred_rects.push_back(vp->GetRect());
		}
		apply_preferred_viewports();
	}

	float get_preferred_render_scale()
	{
		return m_options.graphics.render_scale;
	}

	// The user's render_scale reaching viewports the games made themselves:
	// they go onto an offscreen texture of the asked-for size, and that
	// texture is drawn under the UI. Urho3D draws the UI to the backbuffer
	// after the viewports, so the UI is never undersampled.
	void apply_preferred_viewports()
	{
		magic::Renderer *renderer = GetSubsystem<magic::Renderer>();
		magic::Graphics *graphics = GetSubsystem<magic::Graphics>();
		if(!renderer || !graphics)
			return;
		unsigned n = m_preferred_viewports.size();
		float scale = m_options.graphics.render_scale;
		// 1.0 is a bypass and not a scale of one: no texture, no blit, the
		// frame the client draws when nothing asked for anything
		if(scale > 0.999f && scale < 1.001f){
			drop_preferred_texture();
			renderer->SetNumViewports(n);
			for(unsigned i = 0; i < n; i++){
				m_preferred_viewports[i]->SetRect(m_preferred_rects[i]);
				renderer->SetViewport(i, m_preferred_viewports[i]);
			}
			return;
		}
		if(n == 0){
			// Teardown has to leave nothing behind: a stale texture under
			// the UI is last frame's world, still on the screen
			drop_preferred_texture();
			renderer->SetNumViewports(0);
			return;
		}

		int tw = scaled_length(graphics->GetWidth(), scale);
		int th = scaled_length(graphics->GetHeight(), scale);
		if(!m_preferred_texture || m_preferred_texture->GetWidth() != tw ||
				m_preferred_texture->GetHeight() != th){
			m_preferred_texture = new magic::Texture2D(context_);
			m_preferred_texture->SetSize(tw, th,
					magic::Graphics::GetRGBFormat(), magic::TEXTURE_RENDERTARGET);
			m_preferred_texture->SetFilterMode(magic::FILTER_BILINEAR);
		}
		magic::RenderSurface *surface = m_preferred_texture->GetRenderSurface();
		if(!surface){
			log_w(MODULE, "set_preferred_viewports(): no render surface;"
					" drawing at native resolution");
			drop_preferred_texture();
			renderer->SetNumViewports(n);
			for(unsigned i = 0; i < n; i++)
				renderer->SetViewport(i, m_preferred_viewports[i]);
			return;
		}
		surface->SetNumViewports(n);
		for(unsigned i = 0; i < n; i++){
			m_preferred_viewports[i]->SetRect(
					scaled_rect(m_preferred_rects[i], scale));
			surface->SetViewport(i, m_preferred_viewports[i]);
		}
		surface->SetUpdateMode(magic::SURFACE_UPDATEALWAYS);
		renderer->SetNumViewports(0);

		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!ui)
			return;
		if(!m_preferred_image){
			m_preferred_image = new magic::BorderImage(context_);
			m_preferred_image->SetName("buildat_preferred_viewports");
			// Under whatever UI the game has, and never in the way of it:
			// a disabled element takes no input
			m_preferred_image->SetPriority(-10000);
			m_preferred_image->SetEnabled(false);
			ui->GetRoot()->AddChild(m_preferred_image);
		}
		m_preferred_image->SetTexture(m_preferred_texture);
		m_preferred_image->SetImageRect(magic::IntRect(0, 0, tw, th));
		// UI coordinates, which the UI scale has already divided down
		m_preferred_image->SetPosition(0, 0);
		m_preferred_image->SetSize(ui->GetRoot()->GetSize());
	}

	void drop_preferred_texture()
	{
		if(m_preferred_image){
			m_preferred_image->Remove();
			m_preferred_image.Reset();
		}
		if(m_preferred_texture){
			magic::RenderSurface *surface =
					m_preferred_texture->GetRenderSurface();
			if(surface)
				surface->SetNumViewports(0);
			m_preferred_texture.Reset();
		}
	}

	// Urho3D multiplies a sound type's gain by the "Master" one
	// (Audio::GetSoundSourceMasterGain()), so setting the master here scales
	// every sound in every game, under whatever mixing the game does of its
	// own. The sandbox refuses "Master" to sandboxed code, which is what
	// makes this enforcement rather than a default.
	void apply_sound_preferences()
	{
		magic::Audio *audio = GetSubsystem<magic::Audio>();
		if(!audio)
			return;
		audio->SetMasterGain("Master",
				m_options.sound_mute ? 0.0f : m_options.sound_volume);
	}

	void on_screenmode(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
		bool full = magic_graphics->GetFullscreen();
		bool maxed = !full && window_is_maximized(magic_graphics);
		int w = event_data["Width"].GetInt();
		int h = event_data["Height"].GetInt();
		int desk_w = 0;
		int desk_h = 0;
		bool fills_desktop = desktop_size(&desk_w, &desk_h) &&
				w >= desk_w * 9 / 10 && h >= desk_h * 9 / 10;
		m_options.graphics.fullscreen = full;
		if(!full){
			if(maxed || fills_desktop){
				// Don't save maximized pixel size as the restore size.
				m_options.graphics.maximized = true;
			} else {
				m_options.graphics.maximized = false;
				m_options.graphics.window_w = w;
				m_options.graphics.window_h = h;
			}
		}
		log_v(MODULE, "Window state: %ix%i maximized=%i fullscreen=%i",
				m_options.graphics.window_w, m_options.graphics.window_h,
				m_options.graphics.maximized ? 1 : 0,
				m_options.graphics.fullscreen ? 1 : 0);
		save_preferences(m_options);
		apply_ui_scale();
		// The offscreen texture is a fraction of the window, so a new window
		// size is a new texture
		apply_preferred_viewports();
	}

	void on_logmessage(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		int magic_level = event_data["Level"].GetInt();
		ss_ message = event_data["Message"].GetString().CString();
		//log_v(MODULE, "on_logmessage(): %i, %s", magic_level, cs(message));
		int c55_level = CORE_ERROR;
		if(magic_level == magic::LOG_DEBUG)
			c55_level = CORE_DEBUG;
		else if(magic_level == magic::LOG_INFO)
			c55_level = CORE_VERBOSE;
		else if(magic_level == magic::LOG_WARNING)
			c55_level = CORE_WARNING;
		else if(magic_level == magic::LOG_ERROR)
			c55_level = CORE_ERROR;
		log_(c55_level, MODULE, "Urho3D %s", cs(message));
	}

	// Apps-specific lua functions

	// connect_server(address: string) -> status: bool, error: string or nil
	static int l_connect_server(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ address = lua_bindings::lua_tocppstring(L, 1);

		ss_ error;
		bool ok = self->m_state->connect(address, &error);
		lua_pushboolean(L, ok);
		if(ok)
			lua_pushnil(L);
		else
			lua_pushstring(L, error.c_str());
		return 2;
	}

	// list_games() -> {{name=, size=}, ...}
	static int l_list_games(lua_State *L)
	{
		ss_ games_dir = g_client_config.get<ss_>("share_path")+"/games";
		auto nodes = interface::fs::list_directory(games_dir);
		sv_<ss_> names;
		for(const auto &n : nodes){
			if(!n.is_directory || !valid_game_name(n.name))
				continue;
			names.push_back(n.name);
		}
		std::sort(names.begin(), names.end());
		lua_newtable(L);
		int i = 1;
		for(const ss_ &name : names){
			ss_ game_path = games_dir+"/"+name;
			lua_newtable(L);
			lua_pushstring(L, name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushnumber(L, (lua_Number)interface::fs::directory_tree_size(
					game_path));
			lua_setfield(L, -2, "size");
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// start_local_server(game: string) -> status: bool, error: string or nil
	static int l_start_local_server(lua_State *L)
	{
		ss_ game = lua_bindings::lua_tocppstring(L, 1);
		if(!valid_game_name(game)){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Invalid game name");
			return 2;
		}

		ss_ game_path = g_client_config.get<ss_>("share_path")+"/games/"+game;
		if(!interface::fs::path_exists(game_path)){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Game not found");
			return 2;
		}

		adopt_pidfile();
		if(interface::process::is_running(g_local_server)){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Previous local server is still running");
			return 2;
		}
		g_local_server.impl = 0;
		clear_pidfile();

		ss_ server_path = interface::os::get_sibling_exe_path("buildat_server");
		if(!interface::fs::path_exists(server_path)){
			lua_pushboolean(L, false);
			lua_pushstring(L, "buildat_server not found");
			return 2;
		}

		game_path = interface::fs::get_absolute_path(game_path);
		g_local_server_port = pick_free_local_port();
		log_i(MODULE, "Starting local server on port %s", cs(g_local_server_port));
		g_local_server = interface::process::start(
				server_path, {"-m", game_path, "-P", g_local_server_port});
		if(!g_local_server.valid()){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Failed to start server");
			return 2;
		}
		write_pidfile();
		lua_pushboolean(L, true);
		lua_pushnil(L);
		return 2;
	}

	// stop_local_server()
	static int l_stop_local_server(lua_State *L)
	{
		stop_local_server();
		return 0;
	}

	// set_ui_scale(scale: number)  -- <=0 restores auto/config
	static int l_set_ui_scale(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		double s = lua_tonumber(L, 1);
		self->m_ui_scale_lua = (s > 0) ? (float)s : 0.f;
		self->apply_ui_scale();
		return 0;
	}

	// get_ui_scale() -> number
	static int l_get_ui_scale(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::UI *ui = self->GetSubsystem<magic::UI>();
		lua_pushnumber(L, ui ? ui->GetScale() : 1.0);
		return 1;
	}

	// get_preferred_render_scale() -> number
	static int l_get_preferred_render_scale(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushnumber(L, self->m_options.graphics.render_scale);
		return 1;
	}

	// request_stop_local_server()
	static int l_request_stop_local_server(lua_State *L)
	{
		request_stop_local_server();
		return 0;
	}

	// force_kill_local_server()
	static int l_force_kill_local_server(lua_State *L)
	{
		force_kill_local_server();
		return 0;
	}

	// local_server_ready() -> bool
	static int l_local_server_ready(lua_State *L)
	{
		adopt_pidfile();
		if(!interface::process::is_running(g_local_server)){
			lua_pushboolean(L, false);
			return 1;
		}
		lua_pushboolean(L, interface::probe_connect("127.0.0.1",
				g_local_server_port));
		return 1;
	}

	// local_server_port() -> string
	static int l_local_server_port(lua_State *L)
	{
		lua_pushstring(L, g_local_server_port.c_str());
		return 1;
	}

	// local_server_running() -> bool
	static int l_local_server_running(lua_State *L)
	{
		adopt_pidfile();
		lua_pushboolean(L, interface::process::is_running(g_local_server));
		return 1;
	}

	// disconnect()
	static int l_disconnect(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		// Exiting a game exits the client, also when started from the
		// launcher: the menu's Urho3D/Lua state is not resettable in place.
		self->shutdown();

		return 0;
	}

	// send_packet(name: string, data: string)
	static int l_send_packet(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);
		ss_ data = lua_bindings::lua_tocppstring(L, 2);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		try {
			self->m_state->send_packet(name, data);
			return 0;
		} catch(std::exception &e){
			log_w(MODULE, "Exception in send_packet: %s", e.what());
			return 0;
		}
	}

	// get_file_path(name: string) -> path, hash
	static int l_get_file_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ hash;
		ss_ path = self->m_state->get_file_path(name, &hash);
		if(path == "")
			return 0;
		lua_pushlstring(L, path.c_str(), path.size());
		lua_pushlstring(L, hash.c_str(), hash.size());
		return 2;
	}

	// get_file_content(name: string)
	static int l_get_file_content(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		try {
			ss_ content = self->m_state->get_file_content(name);
			lua_pushlstring(L, content.c_str(), content.size());
			return 1;
		} catch(std::exception &e){
			log_w(MODULE, "Exception in get_file_content: %s", e.what());
			return 0;
		}
	}

	// When calling Lua from C++, this is universally good
	static void error_logging_pcall(lua_State *L, int nargs, int nresults)
	{
		log_t(MODULE, "error_logging_pcall(): nargs=%i, nresults=%i",
				nargs, nresults);
		//log_d(MODULE, "stack 1: %s", cs(dump_stack(L)));
		int start_L = lua_gettop(L);
		lua_pushcfunction(L, lua_bindings::handle_error);
		lua_insert(L, start_L - nargs);
		int handle_error_L = start_L - nargs;
		//log_d(MODULE, "stack 2: %s", cs(dump_stack(L)));
		int r = lua_pcall(L, nargs, nresults, handle_error_L);
		lua_remove(L, handle_error_L);
		//log_d(MODULE, "stack 3: %s", cs(dump_stack(L)));
		if(r != 0){
			ss_ traceback = lua_bindings::lua_tocppstring(L, -1);
			lua_pop(L, 1);
			const char *msg =
					r == LUA_ERRRUN ? "runtime error" :
			r == LUA_ERRMEM ? "ran out of memory" :
			r == LUA_ERRERR ? "error handler failed" : "unknown error";
			//log_e(MODULE, "Lua %s: %s", msg, cs(traceback));
			throw Exception(ss_()+"Lua "+msg+":\n"+traceback);
		}
		//log_d(MODULE, "stack 4: %s", cs(dump_stack(L)));
	}

	static void call_global_if_exists(lua_State *L,
			const char *global_name, int nargs, int nresults)
	{
		log_t(MODULE, "call_global_if_exists(): \"%s\"", global_name);
		//log_d(MODULE, "stack 1: %s", cs(dump_stack(L)));
		int start_L = lua_gettop(L);
		lua_getfield(L, LUA_GLOBALSINDEX, global_name);
		if(lua_isnil(L, -1)){
			lua_pop(L, 1 + nargs);
			return;
		}
		lua_insert(L, start_L - nargs + 1);
		error_logging_pcall(L, nargs, nresults);
		//log_d(MODULE, "stack 2: %s", cs(dump_stack(L)));
	}

	// get_path(name: string)
	static int l_get_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		if(name == "share"){
			ss_ path = g_client_config.get<ss_>("share_path");
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		if(name == "cache"){
			ss_ path = g_client_config.get<ss_>("cache_path");
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		if(name == "tmp"){
			ss_ path = g_client_config.get<ss_>("cache_path")+"/tmp";
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		log_w(MODULE, "Unknown named path: \"%s\"", cs(name));
		return 0;
	}

	// extension_path(name: string)
	static int l_extension_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);
		ss_ path = g_client_config.get<ss_>("share_path")+"/extensions/"+name;
		// TODO: Check if extension actually exists and do something suitable if
		//       not
		lua_pushlstring(L, path.c_str(), path.size());
		return 1;
	}
};

App* createApp(magic::Context *context, const Options &options)
{
	return new CApp(context, options);
}

}
// vim: set noet ts=4 sw=4:
