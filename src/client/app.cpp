// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "app.h"
#include <cmath>
#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#include <emscripten/html5.h>
// [WEB_ID_TRUST] (c): l_http_get's on the web, a job in
// Module.buildatHttp that l_http_poll reads back
EM_JS(void, web_fetch, (int id, const char *url_p, int post,
		const char *body, int len), {
	var jobs = Module['buildatHttp'] = Module['buildatHttp'] || {};
	var url = UTF8ToString(url_p);
	var init = {redirect: 'manual'};
	if(post){
		init.method = 'POST';
		init.headers = {'Content-Type': 'text/plain'};
		init.body = HEAPU8.slice(body, body + len);
	}
	var text = function(t){ return new TextEncoder().encode(t); };
	jobs[id] = null;
	fetch(url, init).then(function(r){
		if(r.type === 'opaqueredirect'){
			jobs[id] = {ok: false, data: text('redirected')};
			return;
		}
		return r.arrayBuffer().then(function(b){
			jobs[id] = r.ok ? {ok: true, data: new Uint8Array(b)} :
				{ok: false, data: text('HTTP ' + r.status)};
		});
	}).catch(function(e){
		jobs[id] = {ok: false, data: text(String(e && e.message || e))};
	});
});
// [PLAY_PAGE] (c): a datagram socket on the web, a WebSocket to apps/play's
// bridge whose each message is one datagram, in Module.buildatDgram
EM_JS(int, web_dgram_open, (const char *url_p), {
	var all = Module['buildatDgram'] = Module['buildatDgram'] || {n: 0};
	var id = ++all.n;
	var d = all[id] = {q: [], out: [], state: 'connecting'};
	try {
		d.ws = new WebSocket(UTF8ToString(url_p));
	} catch(e){
		d.state = 'closed: ' + e.message;
		return id;
	}
	d.ws.binaryType = 'arraybuffer';
	d.ws.onopen = function(){
		d.state = 'open';
		d.out.forEach(function(m){ d.ws.send(m); });
		d.out = [];
	};
	// simplified: what the game does not read in 4096 datagrams is lost,
	// as a full UDP buffer loses it
	d.ws.onmessage = function(e){
		if(d.q.length < 4096)
			d.q.push(new Uint8Array(e.data));
	};
	d.ws.onclose = function(e){
		d.state = 'closed: ' + (e.reason ? 'the bridge refused it: ' + e.reason :
				'the bridge closed the connection (' + e.code + ')');
	};
	return id;
});
EM_JS(void, web_dgram_send, (int id, const char *p, int n), {
	var d = (Module['buildatDgram'] || {})[id];
	if(!d)
		return;
	var m = HEAPU8.slice(p, p + n);
	if(d.state === 'open')
		d.ws.send(m);
	else if(d.state === 'connecting' && d.out.length < 256)
		d.out.push(m);
});
EM_JS(int, web_dgram_peek, (int id), {
	var d = (Module['buildatDgram'] || {})[id];
	return d && d.q.length ? d.q[0].length : -1;
});
EM_JS(void, web_dgram_take, (int id, char *p), {
	HEAPU8.set(Module['buildatDgram'][id].q.shift(), p);
});
EM_JS(char*, web_dgram_state, (int id), {
	var d = (Module['buildatDgram'] || {})[id];
	return stringToNewUTF8(d ? d.state : 'closed: closed');
});
EM_JS(void, web_dgram_close, (int id), {
	var all = Module['buildatDgram'] || {};
	if(all[id]){
		try { all[id].ws.close(); } catch(e){}
		delete all[id];
	}
});
#endif
#include "core/log.h"
#include "core/json.h"
#include "client/config.h"
#include "client/state.h"
#include "client/wss.h"
#include "client/command_seq.h"
#include "lua_bindings/init.h"
#include "lua_bindings/util.h"
#include "lua_bindings/replicate.h"
#include "interface/fs.h"
#include "interface/debug.h"
#include <sys/stat.h>
#include <ctime>
#include "interface/os.h"
#include "interface/process.h"
#include "interface/tcpsocket.h"
#include "interface/voxel.h"
#include "interface/thread_pool.h"
#include "interface/http.h"
#include <map>
#include <atomic>
#include <cctype>
#include <algorithm>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <fstream>
#include "interface/aitta.h"
#include "interface/sha256.h"
#include "interface/bignum.h"
#include <sstream>
#include <c55/getopt.h>
#include <c55/os.h>
#include <Application.h>
#include <Engine.h>
#include <LuaScript.h>
#include <tolua++.h>
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
#include <SoundSource.h>
#include <RenderSurface.h>
#include <Texture2D.h>
#include <Image.h>
#include <MemoryBuffer.h>
#include <zlib.h>
#include <VertexBuffer.h>
#include <Geometry.h>
#include <BorderImage.h>
#include <Octree.h>
#include <FileSystem.h>
#include <PhysicsWorld.h>
#include <DebugRenderer.h>
#include <Profiler.h>
#include <UI.h>
#ifdef __EMSCRIPTEN__
#include <LineEdit.h>
#include <Text.h>
#endif
#include <Text.h>
#include <Font.h>
#include <CustomGeometry.h>
#include <Node.h>
#include <Camera.h>
#include <SDL/SDL.h>
#include <ctime>
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
// windows.h, which SDL and Urho3D pull in above, does #define interface
// struct, and interface is this tree's namespace
#ifdef interface
	#undef interface
#endif
#define MODULE "__app"
namespace magic = Urho3D;

// Auto UI scale: min(window w,h) / this. Lua/config/CLI overrides replace it.
static const float UI_REF_SHORT = 1080.f;
// The fewest UI pixels a web page's short side is given, however big a
// finger wants the UI ([FP_TOUCH] 1): a dialog's width and its margins
static const float UI_MIN_SHORT = 400.f;
// Snap to 1x, 2x, ... when close, so 1px lines stay on-pixel.
// Under: maximized window chrome (taskbar, title). Over: 16:10 like 1200p.
static const float UI_SNAP_UNDER = 0.08f;
static const float UI_SNAP_OVER = 0.12f;
// A file a user gives game code ([FP_EXPORT] 4), at most
static const size_t MAX_USER_FILE_BYTES = 64 * 1024 * 1024;
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
// And how an axis that is never going to arrive is told from one that is
// still on its way: how much closer it has to get to count as getting
// closer, and how many frames it may fail to. A pitch clamp answers every
// push away from it and none towards it, so the sign flipping above
// oscillates against one forever -- what settles it is that the error stops
// shrinking.
static const float LOOK_PROGRESS_DEG = 0.05f;
static const int LOOK_NO_PROGRESS_FRAMES = 30;

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
	// How close this axis has been to where it is wanted, and for how many
	// frames it has not got closer: that is what says a clamped axis has
	// arrived as far as it ever will. The flips alone cannot -- a push away
	// from a limit moves, which clears them.
	float best_err = 1e9f;
	int no_progress = 0;
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
		best_err = 1e9f;
		no_progress = 0;
		stuck = false;
	}

	// Called once a frame with how far this axis still has to go
	void progress(float err)
	{
		const float e = fabsf(err);
		if(e < best_err - LOOK_PROGRESS_DEG){
			best_err = e;
			no_progress = 0;
			return;
		}
		if(++no_progress >= LOOK_NO_PROGRESS_FRAMES)
			stuck = true;
	}

	void observe(float delta)
	{
		if(pushed == 0)
			return;
		if(fabsf(delta) > LOOK_MOVED_DEG){
			deg_per_px = delta / (float)pushed;
			stall = 0;
			flips = 0;
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

// The preference the local server's -l comes from, kept where the static
// start function can read it ([LOG_LEVEL_PREF])
static int g_server_log_level_pref = 3;

static ss_ preferences_path()
{
	return g_client_config.get<ss_>("user_path")+"/settings.json";
}

#ifdef __EMSCRIPTEN__
// The page's hidden stand-in follows the focused LineEdit ([WEB_KEYS] steps
// 2 and 4, src/client/web/index.html): its place, text and selection, and
// whether it is a password's. The browser's IME, a touchscreen's keyboard,
// its right click menu, select all, copy, cut and paste then work on it,
// and what they did comes back as actions, taken here once a frame:
//   "v<caret>,<text>"  the field's text is now this, the caret there
//   "i<text>"          type the text (a paste; its lines kept in a
//                      multi-line field)
//   "s<start>,<len>"   select
//   "e"                Enter, from a touchscreen's keyboard
// Positions are in characters.
static void web_text_sync(magic::UI *ui)
{
	magic::UIElement *f = ui->GetFocusElement();
	magic::LineEdit *e = f && f->GetType() == magic::LineEdit::GetTypeStatic() ?
			static_cast<magic::LineEdit*>(f) : nullptr;
	for(;;){
		char *a = (char*)EM_ASM_PTR({
			var a = window.buildatText ? buildatText.take() : null;
			return a === null ? 0 : stringToNewUTF8(a);
		});
		if(!a)
			break;
		const char *comma = strchr(a, ',');
		if(e && a[0] == 'v' && comma && e->IsEditable()){
			unsigned caret = (unsigned)atoi(a + 1);
			e->SetText(magic::String(comma + 1));
			e->SetCursorPosition(caret);
			e->GetTextElement()->ClearSelection();
		} else if(e && a[0] == 'i'){
			e->OnTextInput(magic::String(a + 1));
		} else if(e && a[0] == 'e'){
			// A touchscreen keyboard's Enter: the field's own, which is
			// what finishes it (TextFinished)
			e->OnKey(magic::KEY_RETURN, 0, 0);
		} else if(e && a[0] == 's'){
			unsigned start = 0, len = 0;
			if(sscanf(a + 1, "%u,%u", &start, &len) == 2){
				e->SetCursorPosition(start + len);
				e->GetTextElement()->SetSelection(start, len);
			}
		}
		free(a);
	}
	if(!e){
		EM_ASM({ if(window.buildatText) buildatText.sync(null); });
		return;
	}
	float k = ui->GetScale();
	magic::IntVector2 p = e->GetScreenPosition();
	magic::IntVector2 size = e->GetSize();
	magic::Text *t = e->GetTextElement();
	unsigned len = t->GetSelectionLength();
	unsigned start = len ? t->GetSelectionStart() : e->GetCursorPosition();
	// A password's stand-in is a password input: never copied, and a phone's
	// keyboard does not suggest it
	bool secret = !e->IsTextCopyable() || e->GetEchoCharacter();
	EM_ASM({
		if(window.buildatText)
			buildatText.sync($0, $1, $2, $3, UTF8ToString($4), $5, $6, $7, $8,
					$9);
	}, p.x_ * k, p.y_ * k, size.x_ * k, size.y_ * k, e->GetText().CString(),
			start, len, e->IsEditable() ? 1 : 0, secret ? 1 : 0,
			e->IsMultiLine() ? 1 : 0);
}
#endif

namespace app {

// Every preference -o and settings.json can carry is listed here once, so
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
		// **The launch UI is a name, not a number**: it is an
		// extension's directory name, so letters, digits and
		// underscores and nothing that could be a path
		if(key == "launch_ui"){
			bool ok = !value.empty() && value.size() <= 84;
			for(char c : value)
				if(!(isalnum((unsigned char)c) || c == '_'))
					ok = false;
			if(!ok){
				*error = "launch_ui: \""+value+"\" is not an extension name";
				return false;
			}
			opt->launch_ui = value;
			continue;
		}
		if(key == "default_username"){
			bool ok = !value.empty() && value.size() <= 20;
			for(char c : value)
				if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
					ok = false;
			if(!ok){
				*error = "default_username: \""+value+"\" is not 1 to 20 "
						"letters, digits, _ or -";
				return false;
			}
			opt->default_username = value;
			continue;
		}
		if(key == "render_scale" && value == "auto"){
			opt->graphics.render_scale_auto = true;
			continue;
		}
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
			opt->graphics.render_scale_auto = false;
		} else if(key == "vsync"){
			opt->graphics.vsync = (v != 0);
		} else if(key == "max_fps"){
			in_range = (v >= 0 && v <= 1000);
			opt->graphics.max_fps = (int)v;
		} else if(key == "web_idle_fps"){
			in_range = (v == 1 || v == 5 || v == 10 || v == 30 || v == 60);
			opt->graphics.web_idle_fps = (int)v;
		} else if(key == "multisampling"){
			in_range = (v == 1 || v == 2 || v == 4 || v == 8 || v == 16);
			opt->graphics.multisampling = (int)v;
		} else if(key == "sound_volume_db"){
			in_range = (v >= app::SOUND_OFF_DB && v <= 0.0);
			opt->sound_volume_db = (float)v;
		} else if(key == "sound_mute"){
			opt->sound_mute = (v != 0);
		} else if(key == "log_level"){
			in_range = (v >= 0 && v <= 6);
			opt->log_level = (int)v;
		} else if(key == "server_log_level"){
			in_range = (v >= 0 && v <= 6);
			opt->server_log_level = (int)v;
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
	if(o.graphics.render_scale_auto)
		throw Exception("parse_preference_options: a number left it auto");
	if(!app::parse_preference_options("render_scale=auto", &o, &err) ||
			!o.graphics.render_scale_auto)
		throw Exception("parse_preference_options: refused render_scale=auto");
	if(app::parse_preference_options("render_scale", &o, &err))
		throw Exception("parse_preference_options: took a bare key");
	if(app::parse_preference_options("render_scale=0.5x", &o, &err))
		throw Exception("parse_preference_options: took a non-number");
	if(app::parse_preference_options("render_scale=9", &o, &err))
		throw Exception("parse_preference_options: took an out-of-range value");
	if(app::parse_preference_options("multisampling=3", &o, &err))
		throw Exception("parse_preference_options: took a bad sample count");
	if(app::parse_preference_options("web_idle_fps=7", &o, &err) ||
			!app::parse_preference_options("web_idle_fps=10", &o, &err) ||
			o.graphics.web_idle_fps != 10)
		throw Exception("parse_preference_options: web_idle_fps's choices");
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
	// apps/bomber_drone's second viewport: the same factor, so the two
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
	const json::Value &jwf = o.get("web_idle_fps");
	const json::Value &jms = o.get("multisampling");
	const json::Value &jsv = o.get("sound_volume_db");
	// **The old key, read once** ([VOLUME_LAW]): a `sound_volume` in a
	// file from before is a fader position, 0 to 1. It is turned into
	// the decibels that sound the same and written back on the next
	// save, so nobody's volume jumps on an upgrade. The two cannot be
	// told apart by their values -- 0 is silence on one scale and full
	// on the other -- which is why the key is a new one.
	const json::Value &jsv_old = o.get("sound_volume");
	const json::Value &jsm = o.get("sound_mute");
	const json::Value &jui = o.get("launch_ui");
	const json::Value &jdu = o.get("default_username");
	const json::Value &jll = o.get("log_level");
	const json::Value &jsl = o.get("server_log_level");
	// Through the same parser as -o, so that the range checks are written
	// once and a hand-edited file is refused the same way a flag is
	ss_ items;
	if(jll.is_integer())
		items += ss_()+(items.empty()?"":",")+"log_level="+itos(jll.as_integer());
	if(jsl.is_integer())
		items += ss_()+(items.empty()?"":",")+"server_log_level="+itos(jsl.as_integer());
	if(jrs.is_number())
		items += ss_()+(items.empty()?"":",")+"render_scale="+ftos(jrs.as_number());
	else if(jrs.is_string() && jrs.as_string() == "auto")
		items += ss_()+(items.empty()?"":",")+"render_scale=auto";
	if(jvs.is_boolean())
		items += ss_()+(items.empty()?"":",")+"vsync="+(jvs.as_boolean()?"1":"0");
	if(jmf.is_integer())
		items += ss_()+(items.empty()?"":",")+"max_fps="+itos(jmf.as_integer());
	if(jwf.is_integer())
		items += ss_()+(items.empty()?"":",")+"web_idle_fps="+itos(jwf.as_integer());
	if(jms.is_integer())
		items += ss_()+(items.empty()?"":",")+"multisampling="+itos(jms.as_integer());
	if(jsv.is_number()){
		items += ss_()+(items.empty()?"":",")+
				"sound_volume_db="+ftos(jsv.as_number());
	} else if(jsv_old.is_number()){
		const double v = jsv_old.as_number();
		double db = app::SOUND_OFF_DB;
		if(v > 0.0){
			db = 20.0 * log10(v);
			// Onto the step grid the settings now move on, to the
			// nearest step: the point is that nobody's volume jumps,
			// and flooring 0.5 -- which is -6.02 dB -- to -9 is a jump
			// down of a third of the gain
			db = std::floor(db / 3.0 + 0.5) * 3.0;
			if(db > 0.0)
				db = 0.0;
			if(db < app::SOUND_OFF_DB)
				db = app::SOUND_OFF_DB;
		}
		log_i(MODULE, "sound_volume %s in the settings is a fader position"
				" and is now %s dB", cs(ftos(v)), cs(ftos(db)));
		items += ss_()+(items.empty()?"":",")+"sound_volume_db="+ftos(db);
	}
	if(jsm.is_boolean())
		items += ss_()+(items.empty()?"":",")+"sound_mute="+(jsm.as_boolean()?"1":"0");
	if(jui.is_string())
		items += ss_()+(items.empty()?"":",")+"launch_ui="+jui.as_string();
	if(jdu.is_string())
		items += ss_()+(items.empty()?"":",")+"default_username="+
				jdu.as_string();
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
	// Nothing that came from the command line is remembered: -o's
	// preferences, a -c run's whole set of them, and -w's size -- the rest
	// of a -w run's are, since the web page always gives -w, and the
	// window's are then what the file had
	if(opt.preferences_disabled || !opt.preference_overrides.empty())
		return;
	json::Value o = json::object();
	if(opt.graphics.size_forced){
		json::json_error_t err;
		json::Value old = json::load_file(preferences_path().c_str(), &err);
		if(old.is_object()){
			for(const char *k : {"width", "height", "maximized", "fullscreen"}){
				if(!old.get(k).is_undefined())
					o.set(k, old.get(k));
			}
		}
	} else {
		if(opt.graphics.window_w < MIN_WINDOW_W ||
				opt.graphics.window_h < MIN_WINDOW_H)
			return;
		o.set("width", opt.graphics.window_w);
		o.set("height", opt.graphics.window_h);
		o.set("maximized", opt.graphics.maximized);
		o.set("fullscreen", opt.graphics.fullscreen);
	}
	if(opt.graphics.render_scale_auto)
		o.set("render_scale", "auto");
	else
		o.set("render_scale", opt.graphics.render_scale);
	o.set("vsync", opt.graphics.vsync);
	o.set("max_fps", opt.graphics.max_fps);
	o.set("web_idle_fps", opt.graphics.web_idle_fps);
	o.set("multisampling", opt.graphics.multisampling);
	o.set("sound_volume_db", opt.sound_volume_db);
	o.set("sound_mute", opt.sound_mute);
	o.set("log_level", opt.log_level);
	o.set("server_log_level", opt.server_log_level);
	o.set("launch_ui", opt.launch_ui);
	o.set("default_username", opt.default_username);
	o.save_file(preferences_path().c_str());
}

// What render_scale "auto" is: natively 1, the bypass
static float auto_render_scale()
{
#ifdef __EMSCRIPTEN__
	// **The web's render scale default** (user, 2026-09-30): a browser is
	// not a performance setup. The 3D gets about a 1080p frame's pixels
	// (2.1 M) of the page's canvas, a screen of over 3000 device pixels on
	// a side (4K) half at most, and a GPU that is the CPU (SwiftShader,
	// llvmpipe, Microsoft's basic renderer) half at most too; rounded down
	// to a step the settings offer. Only while render_scale is "auto".
	return (float)EM_ASM_DOUBLE({
		var dpr = window.devicePixelRatio || 1;
		var s = Math.min(1, Math.sqrt(2.1e6 /
				(window.innerWidth * window.innerHeight * dpr * dpr)));
		if(Math.max(screen.width, screen.height) * dpr > 3000)
			s = Math.min(s, 0.5);
		try {
			var gl = document.createElement('canvas').getContext('webgl');
			var info = gl && gl.getExtension('WEBGL_debug_renderer_info');
			var name = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : '';
			if(/swiftshader|llvmpipe|softpipe|basic render|software/i.test(name))
				s = Math.min(s, 0.5);
			var lose = gl && gl.getExtension('WEBGL_lose_context');
			if(lose)
				lose.loseContext();
		} catch(e){}
		// (no [a, b] here: a comma outside parentheses splits the macro)
		var steps = '1 0.75 0.67 0.5 0.33 0.25'.split(' ');
		for(var i = 0; i < steps.length; i++){
			if(+steps[i] <= s + 0.001)
				return +steps[i];
		}
		return 0.25;
	});
#else
	return 1.0f;
#endif
}

// A render scale of "auto" made a number, for now: at the start, on a
// resize and when the setting is chosen
static void settle_render_scale(app::Options *opt)
{
	if(opt->graphics.render_scale_auto)
		opt->graphics.render_scale = auto_render_scale();
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
	if(!opt->preferences_disabled && load_preferences(desk_w, desk_h, opt)){
		size_ok = true;
		if(!g_client_config.get<bool>("log_level_given"))
			log_set_max_level(opt->log_level);
		g_server_log_level_pref = opt->server_log_level;
	}
	if(!size_ok)
		pick_default_window_size(desk_w, desk_h,
				&opt->graphics.window_w, &opt->graphics.window_h);
}

static bool valid_app_name(const ss_ &name)
{
	if(name.empty() || name.size() > 64)
		return false;
	for(char c : name){
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	}
	return true;
}

// **An app installed from a release** ([AITTA_MVP]) is named on the grid
// and to start_local_server() "<author>.<name>@<version>", and lives in
// <user>/installed/<author>/<name>/<version>/; its server calls it
// "<author>.<name>" (server::app_of()). Each part as the install checked
// it (interface::aitta::check_manifest()); "" for anything else.
static ss_ installed_app_dir(const ss_ &id)
{
	const size_t dot = id.find('.'), at = id.find('@');
	if(dot == ss_::npos || at == ss_::npos || at < dot)
		return "";
	const ss_ author = id.substr(0, dot), name = id.substr(dot + 1, at - dot - 1),
			version = id.substr(at + 1);
	auto plain = [](const ss_ &p, bool dots){
		if(p.empty() || p.size() > 40 || p == "." || p == "..")
			return false;
		for(char c : p)
			if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' ||
					(dots && (isalnum((unsigned char)c) || c == '.' ||
					c == '-' || c == '+'))))
				return false;
		return true;
	};
	if(!plain(author, false) || !plain(name, false) || !plain(version, true))
		return "";
	return g_client_config.get<ss_>("user_path")+"/installed/"+author+"/"+
			name+"/"+version;
}

// Every installed version's id, sorted: the apps', or the extensions'
static sv_<ss_> installed_app_ids(bool extensions = false)
{
	const ss_ installed = g_client_config.get<ss_>("user_path")+"/installed";
	sv_<ss_> ids;
	for(const auto &a : interface::fs::list_directory(installed))
		for(const auto &n : interface::fs::list_directory(installed+"/"+a.name))
			for(const auto &v : interface::fs::list_directory(
					installed+"/"+a.name+"/"+n.name)){
				const ss_ id = a.name+"."+n.name+"@"+v.name;
				if(v.is_directory && !installed_app_dir(id).empty() &&
						(interface::aitta::kind_of(json::load_file((
						installed_app_dir(id)+"/meta.json").c_str())) ==
						"extension") == extensions)
					ids.push_back(id);
			}
	std::sort(ids.begin(), ids.end());
	return ids;
}

// An installed extension's directory by its name in the client,
// "<author>__<name>" ([AITTA]), or "" -- there is one version of it
static ss_ installed_extension_dir(const ss_ &name)
{
	const size_t sep = name.find("__");
	if(sep == ss_::npos)
		return "";
	const ss_ prefix = name.substr(0, sep)+"."+name.substr(sep + 2)+"@";
	for(const ss_ &id : installed_app_ids(true))
		if(id.compare(0, prefix.size(), prefix) == 0)
			return installed_app_dir(id);
	return "";
}

// A tree app's directory or an installed one's, "" for neither
static ss_ app_dir(const ss_ &id)
{
	if(valid_app_name(id))
		return g_client_config.get<ss_>("share_path")+"/apps/"+id;
	return installed_app_dir(id);
}

// What the app's server calls it: an installed one without its version
static ss_ server_app_id(const ss_ &id)
{
	const size_t at = id.find('@');
	return installed_app_dir(id).empty() ? id : id.substr(0, at);
}

// Survives CApp reboot so disconnect can kill the server we started.
static interface::process::Handle g_local_server;
// Port the local server was told to listen on ("" if none was started)
static ss_ g_local_server_port;
// The game the local server was started with, for the storage of the game
// code it serves
static ss_ g_local_server_app;
// The watchdog's stall, in seconds; a screen may lower it ([BOX_PLAYTEST_2] 12)
static int g_watchdog_seconds = 10;
// **A script that does not return is stopped, not waited out**: a
// server's Lua has no instruction limit, and `while true do end` froze
// the client for good. After 30 s without a frame the watchdog sets this
// hook from its signal handler, the way luajit's own Ctrl-C does, and
// the first Lua instruction after it errors out to the nearest pcall.
// simplified: a loop LuaJIT has compiled never returns to the
// interpreter, so the hook does not reach it, and a freeze in C++ leaves
// the hook to fire in whatever Lua runs next before the frame clears it
static lua_State *g_watchdog_L = nullptr;
static std::atomic_bool g_watchdog_hooked(false);
static void watchdog_lua_hook(lua_State *L, lua_Debug *ar)
{
	(void)ar;
	lua_sethook(L, nullptr, 0, 0);
	g_watchdog_hooked = false;
	luaL_error(L, "the watchdog stopped Lua that ran for 30 s without a frame");
}
static void watchdog_freeze()
{
	g_watchdog_hooked = true;
	lua_sethook(g_watchdog_L, watchdog_lua_hook,
			LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
}
// The local server's log, tailed for its STATUS lines ([START_PROGRESS])
static ss_ g_local_server_log;
static size_t g_local_server_log_offset = 0;
static bool g_local_server_listening = false;
// What makes this client the local server's owner and admin, and nobody
// else who reaches its port ([SECURITY_RUN_1], decided by the user): made
// fresh per server, handed over in its environment -- a command line is
// every local user's to read -- and sent once connected. Not a script's
// to see.
static ss_ g_local_server_token;
static int64_t g_local_server_started_s = 0;
static ss_ g_local_server_status;

// [PROCESS_SANDBOX] B 2: on Windows the local server is boxed and loopback
// does not reach it, so it is joined, and asked whether it is up, by its
// pipe. "" where loopback is the way (client/wss.h).
static ss_ local_pipe()
{
	if(g_local_server_app.empty() || g_local_server_port.empty())
		return "";
	return client::local_server_pipe(g_local_server_app, g_local_server_port);
}
static ss_ to_local_pipe(const ss_ &address)
{
	const ss_ pipe = local_pipe();
	if(!pipe.empty() && (address == "localhost:"+g_local_server_port ||
			address == "127.0.0.1:"+g_local_server_port))
		return "pipe:"+pipe;
	return address;
}
static bool local_server_answers()
{
	const ss_ pipe = local_pipe();
	if(!pipe.empty())
		return client::pipe_ready(pipe);
	return interface::probe_connect("127.0.0.1", g_local_server_port);
}

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
	// The server, and the client that started it ([SERVER_ADOPTED])
	fprintf(f, "%ld %ld\n", (long)g_local_server.impl, (long)getpid());
	fclose(f);
#endif
}

#ifndef _WIN32
static bool exe_is(long pid, const char *name)
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
	return strcmp(base, name) == 0;
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
	long pid = 0, client = 0;
	if(fscanf(f, "%ld %ld", &pid, &client) < 1 || pid <= 0){
		fclose(f);
		clear_pidfile();
		return;
	}
	fclose(f);
	// Another client's server, while that client runs, is that client's to
	// stop: a scripted client quitting beside a person's launcher stopped
	// the person's game ([SERVER_ADOPTED]). Only a server whose client is
	// gone is taken, which is what a crash leaves.
	if(client > 0 && client != (long)getpid() && exe_is(client, "buildat"))
		return;
	if(!exe_is(pid, "buildat_server")){
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
// **Stopping the server is a wait, and a wait on the frame is a freeze**
// ([QUIT_STALL], 2026-09-24): terminate() sends SIGTERM and then sleeps
// up to ten seconds waiting to reap, and stop_local_server() then probes
// the port for two more -- twelve seconds of a main thread that is
// reached from a Lua UI handler, so the window is dead to the
// compositor while it sleeps and the watchdog says "no frame for 2 s".
//
// The Lua side asks for this instead: SIGTERM now, and the reaping and
// the force-kill happen a frame at a time in on_update(). The blocking
// one below is kept for the quit path, where there are no more frames
// to do it in.
static bool g_stopping_server = false;
static int64_t g_stopping_since_us = 0;

static void begin_stop_local_server()
{
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	log_i(MODULE, "Stopping local server (across frames)");
	interface::process::request_terminate(g_local_server);
	g_stopping_server = true;
	g_stopping_since_us = get_timeofday_us();
}

// One frame's worth of that wait; returns true while it is still going
static bool step_stop_local_server()
{
	if(!g_stopping_server)
		return false;
	if(interface::process::reap(g_local_server) ||
			!interface::process::is_running(g_local_server)){
		g_stopping_server = false;
		g_local_server.impl = 0;
		clear_pidfile();
		log_i(MODULE, "Local server stopped");
		return false;
	}
	if(get_timeofday_us() - g_stopping_since_us > 10000000){
		log_w(MODULE, "Local server did not stop in 10 s; killing");
		interface::process::kill_force(g_local_server);
		g_stopping_server = false;
		clear_pidfile();
		return false;
	}
	return true;
}

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
	// The web's canvas is drawn at device pixels ([FP_TOUCH] 1)
#ifdef __EMSCRIPTEN__
	const bool high_dpi = true;
#else
	const bool high_dpi = false;
#endif
	magic_graphics->SetMode(w, h, fullscreen, borderless, resizable,
			high_dpi, vsync, triple_buffer, multisampling, 0, 0);
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

	// **A builtin module's client_data, with no server to send it.** A
	// module publishes its client_data as <module>/<path> and the client
	// gets it over the wire; an extension that wants the same shaders --
	// extensions/launch_world wants voxel_shading's -- has no server to
	// get them from. So a name nobody has announced is looked for under
	// builtin/<module>/client_data/ before it is given up on.
	ss_ builtin_client_data(const ss_ &orig)
	{
		size_t slash = orig.find('/');
		if(slash == ss_::npos || slash == 0)
			return "";
		// A name is a resource name and never a path out of the tree
		if(orig.find("..") != ss_::npos)
			return "";
		ss_ path = g_client_config.get<ss_>("share_path")+"/builtin/"+
				orig.substr(0, slash)+"/client_data/"+orig.substr(slash + 1);
		if(!interface::fs::path_exists(path))
			return "";
		return path;
	}

	void Route(magic::String &name, magic::ResourceRequest requestType)
	{
		if(!m_client){
			ss_ builtin = builtin_client_data(ss_(name.CString()));
			if(builtin != ""){
				log_v(MODULE, "Resource route access: %s -> %s (builtin)",
						name.CString(), cs(builtin));
				name = builtin.c_str();
				return;
			}
			log_w(MODULE, "Resource route access: %s (client not initialized)",
					name.CString());
			return;
		}
		ss_ orig(name.CString());
		ss_ path = m_client->get_file_path(orig);
		if(path == "")
			path = builtin_client_data(orig);
		if(path == ""){
			log_v(MODULE, "Resource route access: %s (assuming local file)",
					name.CString());
			// NOTE: Path safety is checked by magic::FileSystem
			return;
		}
		// Announced but not here yet -- a cold cache with the media on its
		// way ([FIRST_RUN]): the name stays as it is, so cache:Exists()
		// says no and a GetResource fails on the name rather than on a
		// path in the cache, and whoever asked asks again later
		if(!interface::fs::path_exists(path)){
			log_v(MODULE, "Resource route access: %s (not arrived yet)",
					name.CString());
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
	// dump_meshes(): the textures written so far this session, by the
	// Texture2D they were read back from, so that eight viewpoints of one
	// world read the atlas back once and not eight times -- the read-back
	// and the PNG encode were 96% of a dump, and a dump longer than 30 s
	// has the server drop the client as stalled
	sm_<magic::Texture2D*, ss_> m_dumped_textures;
	// The PNG encoding of a dump's textures, off the main thread: sixty
	// atlas pages of 2048^2 took a minute to encode on it, which is
	// longer than the server waits for a client that answers nothing, and
	// the frames the client owes are the main thread's. One worker for
	// the session with a queue, never joined between dumps -- a join
	// before the second dump was the same minute on the main thread --
	// only at shutdown. A texture is queued once a session (see
	// m_dumped_textures), so a later dump never rewrites a file the
	// worker is still on.
	std::thread m_texture_writer;
	std::mutex m_texture_mutex;
	std::condition_variable m_texture_cv;
	std::deque<std::pair<ss_, magic::SharedPtr<magic::Image>>> m_texture_queue;
	bool m_texture_stop = false;
	void queue_textures(sv_<std::pair<ss_, magic::SharedPtr<magic::Image>>> &items)
	{
		{
			std::lock_guard<std::mutex> lock(m_texture_mutex);
			for(auto &item : items)
				m_texture_queue.push_back(item);
		}
		if(!m_texture_writer.joinable()){
			m_texture_writer = std::thread([this](){
				for(;;){
					std::pair<ss_, magic::SharedPtr<magic::Image>> item;
					{
						std::unique_lock<std::mutex> lock(m_texture_mutex);
						m_texture_cv.wait(lock, [this](){
							return m_texture_stop || !m_texture_queue.empty();
						});
						if(m_texture_queue.empty())
							return;
						item = m_texture_queue.front();
						m_texture_queue.pop_front();
					}
					const int64_t t0 = interface::os::time_us();
					write_dump_texture(item.first, item.second);
					log_v(MODULE, "dump_meshes: wrote %s in %.1f s",
							cs(item.first),
							(interface::os::time_us() - t0) / 1e6);
				}
			});
		}
		m_texture_cv.notify_one();
	}
	// A map's PNG, and for the two whose alpha is a channel of its own --
	// the spec map's spots, the normal map's static spots -- the alpha
	// forced opaque and the channel written beside it as <stem>_spots.png
	// or <stem>_static_spots.png: a viewer composited the used tiles
	// transparent over black and the map looked empty when it was not.
	// [SPEC_DUMP_ALPHA]
	static void write_dump_texture(const ss_ &path,
			magic::SharedPtr<magic::Image> img)
	{
		const bool spec = path.size() > 9 &&
				path.compare(path.size() - 9, 9, "_spec.png") == 0;
		const bool normal = path.size() > 11 &&
				path.compare(path.size() - 11, 11, "_normal.png") == 0;
		if((!spec && !normal) || img->GetComponents() != 4){
			img->SavePNG(magic::String(path.c_str()));
			return;
		}
		const int w = img->GetWidth(), h = img->GetHeight();
		const unsigned char *src = img->GetData();
		magic::SharedPtr<magic::Image> opaque(new magic::Image(img->GetContext()));
		magic::SharedPtr<magic::Image> chan(new magic::Image(img->GetContext()));
		opaque->SetSize(w, h, 4);
		chan->SetSize(w, h, 4);
		unsigned char *o = opaque->GetData(), *c = chan->GetData();
		for(int i = 0; i < w * h; i++){
			o[i * 4] = src[i * 4];
			o[i * 4 + 1] = src[i * 4 + 1];
			o[i * 4 + 2] = src[i * 4 + 2];
			o[i * 4 + 3] = 255;
			c[i * 4] = c[i * 4 + 1] = c[i * 4 + 2] = src[i * 4 + 3];
			c[i * 4 + 3] = 255;
		}
		opaque->SavePNG(magic::String(path.c_str()));
		const ss_ stem = path.substr(0, path.size() - (spec ? 9 : 11));
		chan->SavePNG(magic::String((stem + (spec ? "_spots.png" :
				"_static_spots.png")).c_str()));
	}

	void join_texture_writer()
	{
		{
			std::lock_guard<std::mutex> lock(m_texture_mutex);
			m_texture_stop = true;
		}
		m_texture_cv.notify_one();
		if(m_texture_writer.joinable())
			m_texture_writer.join();
	}
	BuildatResourceRouter *m_router;
	magic::LuaScript *m_script;
	lua_State *L;
	// shutdown() is not instant; the frames until the window closes must not
	// each call it again
	bool m_shutdown_signal_handled = false;
	// The last key, button or touch the user gave, down or up
	// (l_user_activated)
	int64_t m_last_press_us = 0;
	float m_ui_scale_lua = 0.f; // 0 = not set by Lua
	// **What the scale is multiplied by for a menu to fit** (user,
	// 2026-09-30: a phone in portrait showed part of a menu, its buttons
	// out of reach): 1, or less while a top-level element is bigger than
	// the screen; see update_ui_fit()
	float m_fit_factor = 1.f;
	// The root's size before the fit last changed the scale: what a
	// root-sized element still is for a frame after it ([LUANTI_NO_WORLD])
	magic::IntVector2 m_fit_prev_root;
	// When a button, a finger or a key was last down: the scale is not
	// changed under a press or a gesture, nor for FIT_QUIET_US after one
	int64_t m_input_busy_us = 0;
	static constexpr int64_t FIT_QUIET_US = 500000;
	static constexpr float FIT_FLOOR = 0.5f;
	bool m_restore_maximized = false;
	Options m_options;
	bool m_draw_debug_geometry = false;
	int64_t m_last_update_us;

	sv_<client::command_seq::Command> m_commands;
	size_t m_command_index = 0;
	int64_t m_command_wait_until_us = 0;
	// wait_log: the log's line count when the wait began, -1 for none
	long long m_wait_log_since = -1;
	int64_t m_wait_log_until_us = 0;
	// When the wait last said it was still waiting
	int64_t m_wait_log_said_us = 0;
	ss_ m_pending_screenshot;
	bool m_command_seq_active = false;
	// The logical size a scripted client keeps whatever the window does
	// ([SEQ_FIXED_SIZE]): the -w size. The world renders into a texture of
	// it, the UI lays out at it, and both are shown scaled and letterboxed
	// in the window; the scan, the mouse and the screenshots are in it.
	int m_logical_w = 0;
	int m_logical_h = 0;
	// How the logical frame sits in the window: scale and offset, in pixels
	float m_logical_scale = 1.f;
	int m_logical_ox = 0;
	int m_logical_oy = 0;
	bool logical_mode() const { return m_command_seq_active && m_logical_w > 0; }
	void update_logical_placement()
	{
		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		if(!g || !logical_mode())
			return;
		float sx = (float)g->GetWidth() / (float)m_logical_w;
		float sy = (float)g->GetHeight() / (float)m_logical_h;
		m_logical_scale = sx < sy ? sx : sy;
		m_logical_ox = (int)((g->GetWidth() - m_logical_w * m_logical_scale) / 2);
		m_logical_oy = (int)((g->GetHeight() - m_logical_h * m_logical_scale) / 2);
	}
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
	// Frames a mouse_up has waited for its own down to be read
	int m_mouse_up_frames = 0;
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
	// Bumped by set_preferred_viewports(); read through
	// buildat.viewport_generation() by a launcher waiting for a game
	int m_viewport_generation = 0;
	sv_<magic::SharedPtr<magic::Viewport>> m_preferred_viewports;
	sv_<magic::IntRect> m_preferred_rects;
	magic::SharedPtr<magic::Texture2D> m_preferred_texture;
	magic::SharedPtr<magic::BorderImage> m_preferred_image;

	// **What the launcher's UI was before a game was started**
	// ([MENU_CONTEXT]). A game's client half puts its HUD straight on
	// ui.root and nothing of it is named or removed, so the way back to
	// the launcher has to take it off -- and it cannot do that by
	// sweeping ui.root, because the client's own image is a child of it
	// too: the world's texture is drawn through
	// "buildat_preferred_viewports", and sweeping ui.root blind takes
	// the world off the screen and leaves a black frame (which is what
	// the first attempt found, 2026-09-23). So the launcher's children
	// are remembered when a connection starts, and the way back removes
	// the difference.
	sv_<magic::SharedPtr<magic::UIElement>> m_menu_ui_children;
	// No connection since the last leave, so no game put anything there:
	// a launch cancelled while its server compiled left through the same
	// leave and took the launcher's own elements ([RELEASE_RED] core.sh)
	bool m_menu_ui_remembered = false;
	// The launch UI that was asked for and did not load, so that the one
	// that did can say why it is not the one the setting names
	ss_ m_launch_ui_fell_back;
	// [LAN_DISCOVERY]: the group's socket, opened by the first
	// lan_servers(), and what was heard, by "host:port"
	struct LanEntry {
		ss_ name, app, version;
		int64_t players = 0;
		bool account = false;
		int64_t heard_us = 0;
	};
	int m_lan_fd = -1;
	bool m_lan_tried = false;
	bool m_lan_full_said = false;
	sm_<ss_, LanEntry> m_lan;

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
		// [LAN_DISCOVERY]: a launcher listens from the client's start,
		// so one built in its first frames (launch_world's floor) has
		// heard the 2 s announcements by then: the window takes ~2 s.
		// No address given is a launcher (boot_to_menu, set after this).
		if(g_client_config.get<ss_>("server_address").empty())
			lan_listen();
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
		settle_render_scale(&m_options);
		if(m_options.graphics.size_forced){
			m_options.graphics.fullscreen = false;
			m_options.graphics.maximized = false;
		}
		log_v(MODULE, "preferences: render_scale=%s vsync=%i max_fps=%i"
				" multisampling=%i sound_volume_db=%s sound_mute=%i",
				cs(ftos(m_options.graphics.render_scale)),
				m_options.graphics.vsync ? 1 : 0,
				m_options.graphics.max_fps,
				m_options.graphics.multisampling,
				cs(ftos(m_options.sound_volume_db)),
				m_options.sound_mute ? 1 : 0);
		m_restore_maximized = m_options.graphics.maximized;
		log_v(MODULE, "window size: %ix%i maximized=%i fullscreen=%i",
				m_options.graphics.window_w, m_options.graphics.window_h,
				m_options.graphics.maximized ? 1 : 0,
				m_options.graphics.fullscreen ? 1 : 0);

#ifdef __EMSCRIPTEN__
		// No threads in the web client ([WEB_CLIENT]): the pool runs its
		// tasks' threaded part in run_post() instead
		m_thread_pool->start(0);
#else
		m_thread_pool->start(4); // TODO: Configurable
#endif

		interface::fs::create_directories(
				g_client_config.get<ss_>("cache_path")+"/server_icons");
		sv_<ss_> resource_paths = {
			g_client_config.get<ss_>("share_path")+"/client/data",
			g_client_config.get<ss_>("cache_path")+"/tmp",
			// The icons native servers sent ([LAUNCH_WORLD] (4)): a PNG a
			// file, named by its sha256, checked before it was kept
			g_client_config.get<ss_>("cache_path")+"/server_icons",
			g_client_config.get<ss_>("share_path")+"/extensions", // Could be unsafe
			// The launch grid's icons: <name>/launcher/<icon>.png and a
			// game's icon.png, resolved by the menu on the trusted side
			// ([LAUNCH_GRID]). The same exposure as extensions above.
			g_client_config.get<ss_>("share_path")+"/apps",
			g_client_config.get<ss_>("share_path")+"/builtin",
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
		// Where dump_meshes() writes its albedo textures through Urho's
		// own Image::SavePNG; the .obj beside them goes through fopen
		magic_fs->RegisterPath(interface::fs::get_absolute_path(
				g_client_config.get<ss_>("user_path")+"/meshdumps").c_str());

		// Set Urho3D engine parameters
		engineParameters_["WindowTitle"] =
				g_client_config.get<bool>("command_seq_enabled") ?
				"Buildat Client (scripted)" : "Buildat Client";
#ifdef __EMSCRIPTEN__
		// [PAGE_TITLE] SDL's window title is the page's: the one the server
		// wrote stays
		engineParameters_["WindowTitle"] = emscripten_run_script_string(
				"document.title");
#endif
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
#ifdef __EMSCRIPTEN__
		engineParameters_["HighDPI"] = true;
#endif
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
		for(magic::StringHash e : {magic::E_KEYUP, magic::E_MOUSEBUTTONDOWN,
				magic::E_MOUSEBUTTONUP, magic::E_TOUCHBEGIN, magic::E_TOUCHEND})
			SubscribeToEvent(e, URHO3D_HANDLER(CApp, on_press));
		SubscribeToEvent(magic::E_SCREENMODE, URHO3D_HANDLER(CApp, on_screenmode));
		SubscribeToEvent(magic::E_INPUTFOCUS, URHO3D_HANDLER(CApp, on_inputfocus));
		SubscribeToEvent(magic::E_LOGMESSAGE, URHO3D_HANDLER(CApp, on_logmessage));

		// Default to not grabbing the mouse
		magic::Input *magic_input = GetSubsystem<magic::Input>();
		magic_input->SetMouseChangeReason("the client's start");
		magic_input->SetMouseVisible(true);

		// Default to auto-loading resources as they are modified
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic_cache->SetAutoReloadResources(true);
		m_router = new BuildatResourceRouter(context_);
		magic_cache->AddResourceRouter(m_router);
	}

	~CApp()
	{
		client::command_seq::finish_screenshots();
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
		join_texture_writer();
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

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_run_served_code");
		lua_pushlstring(L, script.c_str(), script.size());
		// A name of its own, which sandbox.lua counts as a server's chunk:
		// unnamed, its name was its own text, which no gate knew
		lua_pushstring(L, "=server");
		error_logging_pcall(L, 2, 1);
		bool status = lua_toboolean(L, -1);
		lua_pop(L, 1);
		if(status == false){
			log_w(MODULE, "run_script(): failed");
		} else {
			log_v(MODULE, "run_script(): succeeded");
		}
	}

	// When the connection went, if a local server this client started
	// might be what went with it; see lost_connection() and on_update()
	int64_t m_lost_connection_us = 0;

	ss_ owner_token_for(const ss_ &address)
	{
		if(g_local_server_token.empty() || g_local_server_port.empty() ||
				!interface::process::is_running(g_local_server))
			return "";
		if(address == "localhost:"+g_local_server_port ||
				address == "127.0.0.1:"+g_local_server_port ||
				(!local_pipe().empty() && address == "pipe:"+local_pipe()))
			return g_local_server_token;
		return "";
	}

#ifdef __EMSCRIPTEN__
	// **A web client left alone draws at web_idle_fps** ([WEB_IDLE_FPS]):
	// while the page is hidden or unfocused, or has had no input for a
	// minute. The frame is the browser's animation callback there, and
	// Urho3D's own limits (max_fps, the unfocused rate) are skipped under
	// __EMSCRIPTEN__, so the callback's timing is what changes. The page's
	// input listener (index.html) calls buildatWake, which puts the full
	// rate back on that input rather than on the next slow frame.
	bool m_web_idle = false;
	int m_web_idle_rate = 0;
	void web_idle_step()
	{
		const int rate = m_options.graphics.web_idle_fps;
		const int st = EM_ASM_INT({
			var idle = !(document.visibilityState === 'visible' &&
					document.hasFocus()) ||
					Date.now() - (Module['buildatInputAt'] || 0) > 60000;
			return (idle ? 1 : 0) | (Module['buildatWake'] ? 0 : 2);
		});
		const bool idle = st & 1;
		// The page's input woke it: the rate is full again, whatever this
		// side last set, and an unfocused page goes back to slow from there
		if(m_web_idle && (st & 2))
			m_web_idle = false;
		if(idle == m_web_idle && rate == m_web_idle_rate)
			return;
		m_web_idle = idle;
		m_web_idle_rate = rate;
		if(idle){
			emscripten_set_main_loop_timing(EM_TIMING_SETTIMEOUT,
					1000 / (rate > 0 ? rate : 5));
			EM_ASM({
				Module['buildatWake'] = function(){
					Module['buildatWake'] = null;
					_emscripten_set_main_loop_timing(1, 1); // EM_TIMING_RAF
				};
			});
		} else {
			emscripten_set_main_loop_timing(EM_TIMING_RAF, 1);
			EM_ASM({ Module['buildatWake'] = null; });
		}
		log_v(MODULE, "web: %s", idle ? cs("idle, "+itos(rate)+" frames a second") :
				"full rate");
	}
#endif

	void lost_connection(const ss_ &reason)
	{
#ifdef __EMSCRIPTEN__
		// The web client has no menu to go back to and cannot close its
		// tab ([WEB_CLIENT]): it stops, and the page says so and offers the
		// reload that connects again. An engine shutdown here only died in
		// its GL calls on the way out.
		EM_ASM({
			if(Module['onDisconnected'])
				Module['onDisconnected'](UTF8ToString($0));
		}, reason.c_str());
		emscripten_pause_main_loop();
		return;
#endif
		if(g_local_server.valid() && !g_local_server_log.empty()){
			// The socket closes before the process is gone -- a crash
			// writes its backtrace first -- so the verdict waits a moment
			m_lost_connection_us = get_timeofday_us();
			return;
		}
		shutdown();
	}

	void check_lost_connection()
	{
		if(m_lost_connection_us == 0)
			return;
		if(!interface::process::is_running(g_local_server)){
			m_lost_connection_us = 0;
			// The dialog closes the client; the frozen view stays behind
			// it, and a client with no menu extension loaded gets the
			// plain shutdown
			const ss_ menu = launch_ui_name();
			if(run_script_no_sandbox(
					"local m = buildat.menu_extension and "
					"buildat.menu_extension()\n"
					"if not m or not m.show_dead_server then\n"
					"    m = require('buildat/extension/"+menu+"')\n"
					"end\n"
					"if not m or not m.show_dead_server then\n"
					"    error('the launcher cannot show a dead server')\n"
					"end\n"
					"m.show_dead_server('The server exited', "
					"function() __buildat_disconnect() end)\n"))
				return;
			shutdown();
		} else if(get_timeofday_us() - m_lost_connection_us > 2000000){
			m_lost_connection_us = 0;
			shutdown();
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

	// **A server's icon** ([LAUNCH_WORLD] (4), 2026-10-03): what a native
	// server sends at connect, kept for the lobby's list of servers after
	// the connection is gone. Checked here and not trusted from the wire
	// -- a PNG of 64 KB at most and 512 pixels a side -- kept under the
	// cache by its sha256, and its hash written against the address the
	// client connected to in network_addresses.csv (the network
	// extension's own store, a column of its own). Not for the local
	// server the client started, whose address is a port of the moment,
	// nor a pipe's.
	// simplified: a TLS address (https://) is not kept; its row would
	// need the scheme the room's list leaves out.
	// **One a server** ([SECURITY_RUN_1]): each new PNG was a new file
	// and a rewrite of the address store, so a server sending them in a
	// loop filled the cache. The first one from an address in a run.
	// simplified: a server's new icon is taken at the client's next run
	// **A server's icon, checked and kept** under the cache's
	// server_icons/ by its hash, which it returns; "" when it is not a
	// picture of SERVER_ICON_SIDE pixels a side or less. The handshake's
	// and Starport's listings' ([SERVER_ICONS]) both; from names the
	// source for the log.
	ss_ keep_icon(const ss_ &data, const ss_ &from)
	{
		// The size the PNG says it is, before decoding: a 64 KB file can
		// say 65535 pixels a side and be given the memory for it
		// ([SECURITY_RUN_1])
		const unsigned side = interface::fs::SERVER_ICON_SIDE;
		if(!interface::fs::icon_png_ok(data, side)){
			log_w(MODULE, "server icon from %s: not a PNG of 64 KB or less "
					"and %u pixels a side or less", cs(from), side);
			return "";
		}
		magic::MemoryBuffer buf(data.data(), (unsigned)data.size());
		magic::SharedPtr<magic::Image> img(new magic::Image(context_));
		if(!img->Load(buf) || img->GetWidth() < 1 || img->GetHeight() < 1 ||
				img->GetWidth() > (int)side || img->GetHeight() > (int)side){
			log_w(MODULE, "server icon from %s: not a picture of %u "
					"pixels a side or less", cs(from), side);
			return "";
		}
		const ss_ sha = interface::sha256::hex(interface::sha256::calculate(data));
		const ss_ dir = g_client_config.get<ss_>("cache_path")+"/server_icons";
		const ss_ path = dir+"/"+sha+".png";
		if(!interface::fs::path_exists(path)){
			interface::fs::create_directories(dir);
			std::ofstream f(path, std::ios::binary);
			f<<data;
			if(!f.good()){
				log_w(MODULE, "server icon: cannot write %s", cs(path));
				return "";
			}
		}
		return sha;
	}

	ss_ m_icon_address;
	void handle_server_icon(const ss_ &data)
	{
		const ss_ address = m_state ? m_state->get_address() : "";
		if(address.empty() || address.compare(0, 5, "pipe:") == 0 ||
				address.find("://") != ss_::npos || address == m_icon_address)
			return;
		adopt_pidfile();
		if(!g_local_server_app.empty() &&
				interface::process::is_running(g_local_server) &&
				(address == "localhost:"+g_local_server_port ||
				address == "127.0.0.1:"+g_local_server_port))
			return;
		// The address as the network extension writes it: tcp://host:port
		ss_ hostport = address;
		if(hostport.find(':', hostport[0] == '[' ? hostport.find(']') : 0) ==
				ss_::npos)
			hostport += ":29500";
		for(char c : hostport)
			if(!(isalnum((unsigned char)c) || c == '.' || c == '-' ||
					c == ':' || c == '[' || c == ']'))
				return; // not an address the store's rows can carry
		const ss_ sha = keep_icon(data, address);
		if(sha.empty())
			return;
		m_icon_address = address;
		run_script_no_sandbox("require('buildat/extension/network')"
				".remember_server_icon('tcp://"+hostport+"', '"+sha+"')");
		log_i(MODULE, "server icon from %s kept as %s", cs(address),
				cs(sha.substr(0, 12)));
	}

	void handle_packet(const ss_ &name, const ss_ &data)
	{
		if(name == "core:server_icon"){
			handle_server_icon(data);
			return;
		}
		log_v(MODULE, "handle_packet(): %s", cs(name));
		magic::AutoProfileBlock profiler_block(
				GetSubsystem<magic::Profiler>(), "Buildat|handle_packet");
		// **Which packet** ([PACKET_STALL]): the block above covers the
		// whole Lua dispatch and names nothing, and the worst frame on
		// the box is one packet -- so a nested block per packet type is
		// what tells an expensive handler from a burst of cheap ones.
		// Urho3D keeps the name pointer rather than the string, so the
		// names are interned here and outlive every block made from
		// them; the set of packet types is defined on the wire and does
		// not grow with traffic.
		static sm_<ss_, ss_> block_names;
		auto bn = block_names.find(name);
		if(bn == block_names.end())
			bn = block_names.insert(std::make_pair(name,
					ss_("Buildat|packet:")+name)).first;
		magic::AutoProfileBlock type_block(
				GetSubsystem<magic::Profiler>(), bn->second.c_str());

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
				// From the logical size in a scripted client, so that the
				// layout does not move with the window ([SEQ_FIXED_SIZE])
				int short_side = logical_mode() ? m_logical_w : g->GetWidth();
				int other = logical_mode() ? m_logical_h : g->GetHeight();
				if(other < short_side)
					short_side = other;
#ifdef __EMSCRIPTEN__
				// [FP_TOUCH] 1: the canvas is at device pixels, and a CSS
				// pixel is about as big to the eye on any screen, so the UI
				// is sized in those: never below one UI pixel to one CSS
				// pixel, and half again for a finger (the page says whether
				// the pointer is one)
				const double dpr = emscripten_get_device_pixel_ratio();
				short_side = (int)(short_side / dpr);
#endif
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
#ifdef __EMSCRIPTEN__
				if(s < 1.f)
					s = 1.f;
				const char *touch = getenv("BUILDAT_TOUCH");
				if(touch && touch[0] == '1')
					s *= 1.5f;
				s *= (float)dpr;
				// But a phone's short side keeps room for a dialog: at least
				// UI_MIN_SHORT UI pixels across
				const float fit = (float)(short_side * dpr) / UI_MIN_SHORT;
				if(s > fit)
					s = fit;
#endif
			}
		}
		// A scripted client keeps its logical size, which is what its
		// pictures are compared at; update_ui_fit() leaves it at 1 there
		s *= m_fit_factor;
		if(logical_mode()){
			// The root stays the logical size over the game's own UI scale,
			// drawn at that scale times the window's, and sits in the
			// letterbox
			update_logical_placement();
			// Urho divides the custom size by the scale for the root, so
			// the custom size is the letterboxed frame in pixels and the
			// root comes out at the logical size over the game's scale
			ui->SetCustomSize((int)(m_logical_w * m_logical_scale + 0.5f),
					(int)(m_logical_h * m_logical_scale + 0.5f));
			ui->SetScale(s * m_logical_scale);
			ui->GetRoot()->SetPosition(
					(int)(m_logical_ox / (s * m_logical_scale)),
					(int)(m_logical_oy / (s * m_logical_scale)));
			log_i(MODULE, "UI scale %g at logical %ix%i in %ix%i (x%g at %i,%i)",
					s, m_logical_w, m_logical_h, g->GetWidth(), g->GetHeight(),
					m_logical_scale, m_logical_ox, m_logical_oy);
			return;
		}
		ui->SetScale(s);
		log_i(MODULE, "UI scale %g (%ix%i)", s, g->GetWidth(), g->GetHeight());
	}

	// **Menus fit the screen** (user, 2026-09-30): each frame, the visible
	// top-level UI elements' sizes in UI units -- which a scale does not
	// change, so shrinking cannot feed back -- against the screen, and the
	// scale made small enough for the biggest to fit, down to FIT_FLOOR of
	// what it would be; back up when they fit again. By size, and for one
	// held to the top or the left by where it starts too, which scales
	// with it (user, 2026-09-30: the floorplanner's palette, under a
	// toolbar of two rows on a phone, ran off the bottom while its size
	// alone fitted); one that starts in the far half of the screen is put
	// partly off it on purpose, and is its game's. Centred or held to the
	// bottom or the right, the place moves with the scale and would feed
	// back, so only the size counts.
	// A side that is the root's own (a HUD, a stretched bar) follows the
	// screen and does not count.
	void update_ui_fit()
	{
		if(logical_mode())
			return;
		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		magic::UI *ui = GetSubsystem<magic::UI>();
		magic::Input *in = GetSubsystem<magic::Input>();
		if(!g || !ui || !in)
			return;
		const int64_t now = get_timeofday_us();
		bool busy = in->GetMouseButtonDown(magic::MOUSEB_LEFT |
				magic::MOUSEB_MIDDLE | magic::MOUSEB_RIGHT) ||
				in->GetNumTouches() > 0;
		if(!busy){
			int n = 0;
			const Uint8 *keys = SDL_GetKeyboardState(&n);
			for(int i = 0; keys && i < n && !busy; i++)
				busy = keys[i] != 0;
		}
		if(busy){
			m_input_busy_us = now;
			return;
		}
		if(now - m_input_busy_us < FIT_QUIET_US)
			return;
		magic::UIElement *root = ui->GetRoot();
		const float base = ui->GetScale() / m_fit_factor;
		const magic::IntVector2 rs = root->GetSize();
		const float room_w = g->GetWidth() * 0.98f;
		const float room_h = g->GetHeight() * 0.98f;
		float need = base;
		// What set `need`, for the line: a fit that flips is a size that
		// follows the scale, and the line has to say whose
		magic::UIElement *by = nullptr;
		// A layer the size of the screen (a launcher's stack of screens)
		// is looked into: what is in it is what has to fit
		std::function<void(magic::UIElement *, int)> scan =
				[&](magic::UIElement *parent, int depth){
			for(magic::UIElement *c : parent->GetChildren()){
				if(!c || !c->IsVisible())
					continue;
				// A wrapped text is as wide as it was made, never what is in
				// it: a chat line follows the root's width, and counted it
				// scaled the UI down to fit itself ([LUANTI_CHAT_WRAP])
				if(c->GetType() == magic::Text::GetTypeStatic() &&
						static_cast<magic::Text *>(c)->GetWordwrap())
					continue;
				const magic::IntVector2 sz = c->GetSize();
				// The root's own size, give or take its rounding -- or its
				// size before the last fit: an element that follows the
				// root (a loading panel, a HUD) is resized after it, and
				// counted at its old size it moved the fit, which moved the
				// root, and the scale flipped between two values for good
				// ([LUANTI_NO_WORLD], x0.5 and x0.658 twice a second)
				const bool fill_w = std::abs(sz.x_ - rs.x_) <= 1 ||
						std::abs(sz.x_ - m_fit_prev_root.x_) <= 1;
				const bool fill_h = std::abs(sz.y_ - rs.y_) <= 1 ||
						std::abs(sz.y_ - m_fit_prev_root.y_) <= 1;
				if(fill_w && fill_h){
					if(depth < 4)
						scan(c, depth + 1);
					continue;
				}
				const magic::IntVector2 at = c->GetPosition();
				int ext_w = sz.x_;
				int ext_h = sz.y_;
				if(c->GetHorizontalAlignment() == magic::HA_LEFT &&
						at.x_ > 0 && at.x_ < rs.x_ / 2)
					ext_w += at.x_;
				if(c->GetVerticalAlignment() == magic::VA_TOP &&
						at.y_ > 0 && at.y_ < rs.y_ / 2)
					ext_h += at.y_;
				if(ext_w > 0 && !fill_w && ext_w * base > room_w &&
						room_w / ext_w < need){
					need = room_w / ext_w;
					by = c;
				}
				if(ext_h > 0 && !fill_h && ext_h * base > room_h &&
						room_h / ext_h < need){
					need = room_h / ext_h;
					by = c;
				}
			}
		};
		scan(root, 0);
		float f = std::max(FIT_FLOOR, std::min(1.f, need / base));
		if(std::fabs(f - m_fit_factor) > 0.02f){
			m_fit_factor = f;
			m_fit_prev_root = rs;
			if(by)
				log_i(MODULE, "UI scale fitted to the screen: x%g, by %s"
						" \"%s\" %ix%i at %i,%i in a root of %ix%i", f,
						by->GetTypeName().CString(), by->GetName().CString(),
						by->GetSize().x_, by->GetSize().y_,
						by->GetPosition().x_, by->GetPosition().y_,
						rs.x_, rs.y_);
			else
				log_i(MODULE, "UI scale fitted to the screen: x%g", f);
			apply_ui_scale();
		}
	}

	void Start()
	{
		log_v(MODULE, "Start()");

		apply_ui_scale();

#ifdef __EMSCRIPTEN__
		// Text input only while a text field has focus ([WEB_KEYS]): SDL
		// starts it with the window, and LineEdit turns it on and off with
		// its focus only for a screen keyboard. The web client's key handler
		// leaves character keys to the browser only while it is on.
		GetSubsystem<magic::UI>()->SetUseScreenKeyboard(true);
		SDL_StopTextInput();
#endif

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
		g_watchdog_L = L;
		interface::debug::watchdog_on_freeze(watchdog_freeze);

		// Store current CApp instance in registry
		lua_pushlightuserdata(L, (void*)this);
		lua_setfield(L, LUA_REGISTRYINDEX, "__buildat_app");

		lua_bindings::init(L);

#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, lua_bindings::guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}

		DEF_BUILDAT_FUNC(connect_server)
		DEF_BUILDAT_FUNC(keep_server_icon)
		DEF_BUILDAT_FUNC(connect_server_start)
		DEF_BUILDAT_FUNC(connect_server_poll)
		DEF_BUILDAT_FUNC(disconnect)
		DEF_BUILDAT_FUNC(list_apps)
		DEF_BUILDAT_FUNC(aitta_install)
		DEF_BUILDAT_FUNC(start_local_server)
		DEF_BUILDAT_FUNC(list_launchers)
		DEF_BUILDAT_FUNC(list_installed_games)
		DEF_BUILDAT_FUNC(list_saves)
		DEF_BUILDAT_FUNC(stop_local_server)
		DEF_BUILDAT_FUNC(request_stop_local_server)
		DEF_BUILDAT_FUNC(force_kill_local_server)
		DEF_BUILDAT_FUNC(local_server_ready)
		DEF_BUILDAT_FUNC(local_server_running)
		DEF_BUILDAT_FUNC(local_server_port)
		DEF_BUILDAT_FUNC(game_storage_dir)
		DEF_BUILDAT_FUNC(server_address)
		DEF_BUILDAT_FUNC(lan_address)
		DEF_BUILDAT_FUNC(lan_servers)
		DEF_BUILDAT_FUNC(local_server_status)
		DEF_BUILDAT_FUNC(local_server_log_tail)
		DEF_BUILDAT_FUNC(send_packet);
		DEF_BUILDAT_FUNC(take_screenshot)
		DEF_BUILDAT_FUNC(save_file)
		DEF_BUILDAT_FUNC(exported_files)
		DEF_BUILDAT_FUNC(read_exported)
		DEF_BUILDAT_FUNC(pick_file)
		DEF_BUILDAT_FUNC(picked_file)
		DEF_BUILDAT_FUNC(dump_meshes)
		DEF_BUILDAT_FUNC(get_file_path)
		DEF_BUILDAT_FUNC(get_file_content)
		DEF_BUILDAT_FUNC(get_path)
		DEF_BUILDAT_FUNC(create_directories)
		DEF_BUILDAT_FUNC(count_files)
		DEF_BUILDAT_FUNC(set_watchdog_seconds)
		DEF_BUILDAT_FUNC(set_reload_on_return)
		DEF_BUILDAT_FUNC(set_web_fullscreen)
		DEF_BUILDAT_FUNC(web_authorize)
		DEF_BUILDAT_FUNC(web_authorized)
		DEF_BUILDAT_FUNC(web_dgram)
		DEF_BUILDAT_FUNC(extension_path)
		DEF_BUILDAT_FUNC(set_ui_scale)
		DEF_BUILDAT_FUNC(user_activated)
		DEF_BUILDAT_FUNC(get_ui_scale)
		DEF_BUILDAT_FUNC(logical_size)
		DEF_BUILDAT_FUNC(get_preferred_render_scale)
		DEF_BUILDAT_FUNC(viewport_generation)
		DEF_BUILDAT_FUNC(get_preference)
		DEF_BUILDAT_FUNC(set_preference)
		DEF_BUILDAT_FUNC(list_preferences)
		DEF_BUILDAT_FUNC(launch_ui_fell_back)
		DEF_BUILDAT_FUNC(get_env)
		DEF_BUILDAT_FUNC(is_scripted)
		DEF_BUILDAT_FUNC(leave_to_menu)
		DEF_BUILDAT_FUNC(http_get)
		DEF_BUILDAT_FUNC(http_poll)
		DEF_BUILDAT_FUNC(parse_json)

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

		// **Which extension is the launcher**, for the places that have to
		// go back to it: leaving a game, a server that exited, and
		// whether a game is running under it. They named launch_menu,
		// which is wrong the moment the client is booted with another one
		// (-m launch_world). client/api.lua reads this.
		{
			const ss_ name = launch_ui_name();
			lua_pushstring(L, name.c_str());
			lua_setglobal(L, "__buildat_menu_extension_name");
		}

		// **A run is scripted from before the launcher boots**, not from
		// when the sequence starts stepping. It was set below, after the
		// menu extension had already loaded and taken the cursor --
		// which is what [SCRIPTED_CURSOR] exists to stop, and both its
		// guards read this flag (user, 2026-09-23: "I can't use my
		// mouse during your tests").
		m_command_seq_active = g_client_config.get<bool>("command_seq_enabled");

		// Launch menu if requested
		if(g_client_config.get<bool>("boot_to_menu")){
			ss_ extname = launch_ui_name();
			// -a kind/name/id: the menu boots and runs that one action of
			// its grid ([LAUNCH_GRID]); the string goes in quoted, and it
			// is a path's shape or nothing -- with an installed app's
			// "<author>.<name>@<version>" in it ([AITTA_MVP])
			ss_ action = g_client_config.get<ss_>("launch_action");
			for(char c : action)
				if(!(isalnum((unsigned char)c) || c == '_' || c == '-' ||
						c == '/' || c == '.' || c == '@' || c == '+')){
					action = "";
					break;
				}
			// **A launch UI that asks to be sandboxed is run in the
			// sandbox** ([LAUNCH_SANDBOX]): its own init.lua goes
			// through run_extension_file, which is the same door its
			// other files use, and what it gets is `buildat.safe` under
			// the name `buildat` -- the API every game has and nothing
			// else. A launch UI that does not ask for it is loaded the
			// way it always was, so the two kinds can live side by side
			// while the rest are moved over.
			const ss_ arg = action.empty() ? ss_("") : "'"+action+"'";
			ss_ script = ss_() +
					"if buildat.launch_ui_sandboxed('"+extname+"') then\n"
					"    local ok, err = __buildat_run_code_in_sandbox(\n"
					"        \"local m = buildat.run_extension_file('init.lua')\\n\"\n"
					"        ..\"if type(m) ~= 'table' or type(m.boot) ~= 'function' then\\n\"\n"
					"        ..\"    error('"+extname+" has no boot()')\\n\"\n"
					"        ..\"end\\n\"\n"
					"        ..\"m.boot("+arg+")\\n\"\n"
					// **And it hands its interface over**: a sandboxed
					// launch UI is not in the trusted table of loaded
					// extensions, so without this a game's own "back to
					// the launcher" finds no launcher and disconnects
					// instead ([LAUNCH_SANDBOX], 2026-09-24)
					"        ..\"buildat.provide_launch_interface(m)\\n\",\n"
					"        '"+extname+"/init.lua')\n"
					"    if not ok then error(err) end\n"
					"else\n"
					"    local m = require('buildat/extension/"+extname+"')\n"
					"    if type(m) ~= 'table' then\n"
					"        error('Failed to load extension "+extname+"')\n"
					"    end\n"
					"    m.boot("+arg+")\n"
					"end\n";
			// **A launch UI that raises is a launch UI that did not
			// load**: the runner turns a Lua error into an exception,
			// so a raising one would otherwise take the client with it
			// rather than falling back.
			bool booted = false;
			try {
				booted = run_script_no_sandbox(script);
			} catch(std::exception &e){
				log_w(MODULE, "launch UI \"%s\" raised: %s",
						cs(extname), e.what());
				booted = false;
			}
			if(!booted){
				// **A user cannot be left with no launcher**, which is
				// what a slot anybody can fill has to promise: the one
				// that came with the client is what a missing or
				// raising one falls back to, and the log says which
				// was asked for ([LAUNCH_SANDBOX]).
				bool tried_fallback = false;
				if(extname != "launch_menu"){
					log_w(MODULE, "launch UI \"%s\" did not load; falling"
							" back to launch_menu", cs(extname));
					m_launch_ui_fell_back = extname;
					lua_pushstring(L, "launch_menu");
					lua_setglobal(L, "__buildat_menu_extension_name");
					ss_ fallback = ss_() +
							"local m = require('buildat/extension/launch_menu')\n"
							"if type(m) ~= 'table' then\n"
							"    error('Failed to load extension launch_menu')\n"
							"end\n"
							"m.boot()\n";
					// **The fallback is caught too, which is the whole
					// promise**: a Lua error in the runner becomes a C++
					// exception, and nothing caught it here -- so the one
					// case this code exists for, a launch UI that raises,
					// terminated the client instead of falling back
					// ([MENU_FALLBACK], 2026-09-23).
					bool ok2 = false;
					try {
						// BUILDAT_TEST_NO_LAUNCHER=1 makes the fallback
						// fail, which is the only way to drive the last
						// resort without breaking launch_menu on disk: the
						// promise it keeps is worth a check of its own
						if(getenv("BUILDAT_TEST_NO_LAUNCHER"))
							throw Exception("BUILDAT_TEST_NO_LAUNCHER");
						ok2 = run_script_no_sandbox(fallback);
					} catch(std::exception &e2){
						log_e(MODULE, "the fallback launch UI launch_menu"
								" raised: %s", e2.what());
						ok2 = false;
					}
					tried_fallback = true;
					if(ok2){
						log_i(MODULE, "the launch UI is launch_menu, not \"%s\"",
								cs(extname));
						goto launch_ui_done;
					}
				}
				// **A last resort that is not Lua**: there is nothing
				// left to draw a screen with, so it is the operating
				// system's own box, and it says how to pick another.
				{
					ss_ msg = ss_() +
							"buildat could not start a launch UI.\n\n"
							"Asked for: " + extname + "\n" +
							(tried_fallback ?
							"The built-in menu (launch_menu) raised as well.\n" :
							"") +
							"\nStart it with another one:\n"
							"    buildat -m launch_world\n"
							"or take launch_ui out of settings.json.\n\n"
							"The log has the error.";
					log_e(MODULE, "%s", cs(msg));
					// **In the client's own window, not a box from the
					// window manager** (user, 2026-09-23: "that dialog
					// comes up as a different WM window"). A separate
					// window steals the desktop's focus, which is the
					// same intrusion as taking the screen or the
					// keyboard. This is Urho3D's own UI from C++ --
					// there is no Lua left to draw with, but the engine
					// is up -- and the client keeps running so the
					// message can be read.
					magic::UI *ui = GetSubsystem<magic::UI>();
					magic::ResourceCache *rc =
							GetSubsystem<magic::ResourceCache>();
					if(ui && ui->GetRoot() && rc){
						magic::Text *t =
								ui->GetRoot()->CreateChild<magic::Text>();
						magic::Font *font = rc->GetResource<magic::Font>(
								"Fonts/OverpassMono-Regular.ttf");
						if(!font)
							font = rc->GetResource<magic::Font>(
									"Fonts/Anonymous Pro.ttf");
						if(font)
							t->SetFont(font, 15);
						t->SetText(msg.c_str());
						t->SetColor(magic::Color(1.0f, 0.85f, 0.6f));
						t->SetTextAlignment(magic::HA_CENTER);
						t->SetAlignment(magic::HA_CENTER, magic::VA_CENTER);
					}
					// **And the rest of Start() still runs**: a client
					// that returned here had no command sequence set up
					// either, so a driven run hung with nothing to
					// quit it (2026-09-23).
				}
				launch_ui_done: ;
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
			m_logical_w = m_options.graphics.window_w;
			m_logical_h = m_options.graphics.window_h;
			apply_ui_scale();
			apply_preferred_viewports();
			// Urho3D toggles fullscreen on alt+enter. A driven run injects
			// plenty of enters, and SDL's modifier state can have alt in it
			// from an alt+tab the window never saw the release of, which
			// then puts the window into fullscreen in the middle of a
			// sequence -- and a screen mode change loses what was uploaded
			// to the GPU by hand, so the world comes back black.
			GetSubsystem<magic::Input>()->SetToggleFullscreen(false);
			// **The first injected mouse motion of a run was swallowed**
			// and a scripted look started one command late: whatever
			// takes it, it takes what arrives in that first frame, so
			// the absorbing motion has to be a frame earlier than any
			// real one rather than pushed beside it. That is what
			// absorb_mouse_move_suppression() is for, and it had never
			// been called at all (2026-09-23).
			client::command_seq::absorb_mouse_move_suppression(
					GetSubsystem<magic::Input>());
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
		client::command_seq::release_held_keys();
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
		client::command_seq::release_held_keys();
		client::command_seq::release_forced_focus(
				GetSubsystem<magic::Input>());
		shutdown();
	}

	// A scripted client never hides or captures the cursor: the Input
	// wrapper in client/extensions/urho3d/safe_classes.lua refuses those calls
	// while is_scripted(). Undoing a hide after the fact was what warped
	// the desktop cursor to the window's corner -- Urho's re-show restores
	// a position sampled while the cursor was hidden. See [SCRIPTED_CURSOR]
	// in doc/plan/miscellaneous_plan.md.

	// Where the camera of the first viewport points: yaw from +Z towards +X
	// and pitch upwards, both in degrees. False when there is no camera --
	// a game that has not made one yet, or a menu.
	bool camera_angles(float *yaw, float *pitch)
	{
		auto *renderer = GetSubsystem<magic::Renderer>();
		magic::Viewport *viewport = nullptr;
		// The game's viewports are on the offscreen texture under a render
		// scale or in logical mode, and the renderer then has none
		if(!m_preferred_viewports.empty())
			viewport = m_preferred_viewports[0];
		else if(renderer && renderer->GetNumViewports() >= 1)
			viewport = renderer->GetViewport(0);
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
		// Is each axis still getting closer? An axis against a limit is not,
		// however it is pushed, and that is what ends the command instead of
		// its frame budget.
		m_look_x.progress(err_yaw);
		m_look_y.progress(err_pitch);
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
			ok = client::command_seq::inject_mouse_pos(input,
					logical_mode() ? (int)(m_logical_ox + c.x * m_logical_scale) : c.x,
					logical_mode() ? (int)(m_logical_oy + c.y * m_logical_scale) : c.y,
					&err);
			break;
		case Type::MouseMove:
			ok = client::command_seq::inject_mouse_move(input, c.x, c.y, &err);
			break;
		case Type::MouseDown:
			ok = client::command_seq::inject_mouse_button(
					input, c.x, true, false, &err);
			break;
		case Type::MouseUp:
			// **A hold nothing saw is not a hold** ([SEQ_HOLD_FRAME],
			// 2026-09-24): a client under llvmpipe in a container draws
			// about a frame a second, so the down and the up of a
			// 1.4-second hold landed in one SDL_PollEvent and the button
			// was never down on any frame a script could read. Whatever
			// polls GetMouseButtonDown -- the launcher room's dig and
			// its launch among them -- saw nothing at all. The up waits
			// for the frame that reads the down, bounded so a button
			// that never arrives ends the run instead of hanging it.
			if(client::command_seq::button_held_unseen(c.x)){
				if(++m_mouse_up_frames < 600)
					return false;
				log_w(MODULE, "mouse_up: the button was never read as "
						"down in 600 frames; letting go anyway");
			}
			m_mouse_up_frames = 0;
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
		case Type::Event:
			{
				// Sent now, in the sequence's own frame; the receiver
				// answers in the log, which is what a test reads
				magic::VariantMap data;
				data["Param"] = magic::String(c.param.c_str());
				SendEvent(magic::StringHash(
						magic::String(("command_seq:"+c.s).c_str())), data);
			}
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
		client::command_seq::reassert_held_keys(GetSubsystem<magic::Input>());
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
			if(c.type == Type::WaitLog || c.type == Type::WaitLogAny){
				if(m_wait_log_since < 0){
					// WaitLogAny looks back over the whole run; WaitLog
					// waits for the next line after it starts
					m_wait_log_since = c.type == Type::WaitLogAny ? 0 :
							log_line_count();
					m_wait_log_until_us = now + c.n * 1000;
					log_watch(c.s.c_str());
				}
				if(log_watch_seen() ||
						log_lines_since_contain(m_wait_log_since, c.s.c_str())){
					log_i(MODULE, "wait_log: \"%s\" seen", cs(c.s));
				} else if(now < m_wait_log_until_us){
					// **A wait says it is waiting**, every ten seconds:
					// a run that has stopped saying anything is how a
					// harness tells a stuck client from a patient one,
					// and a wait of two minutes was two minutes of
					// silence indistinguishable from a wedge
					// **Without the text it is waiting for**: the line
					// would otherwise be a line containing that text,
					// and the wait would see its own heartbeat and go
					// on (2026-09-24). The command's own line above
					// says what it waits for.
					if(now >= m_wait_log_said_us + 10000000){
						m_wait_log_said_us = now;
						log_i(MODULE, "wait_log: still waiting, %s s left",
								cs(itos((int)((m_wait_log_until_us - now) /
								1000000))));
					}
					return;
				} else {
					log_w(MODULE, "wait_log: \"%s\" not seen in %s ms; on",
							cs(c.s), cs(itos(c.n)));
				}
				m_wait_log_since = -1;
				m_command_index++;
				continue;
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
		// A frame: the watchdog hears it, and logs this thread's stack
		// when none comes for ten seconds ([WIN8_START] 14) -- or for
		// what a screen asked (the starting screen asks for two: its
		// counter froze for seconds on the box while the server loaded
		// worldgen, and the stack says what this thread was doing;
		// [BOX_PLAYTEST_2] 12)
		interface::debug::watchdog_alive(g_watchdog_seconds);
		if(g_watchdog_hooked.exchange(false))
			lua_sethook(L, nullptr, 0, 0);
#ifdef __EMSCRIPTEN__
		web_text_sync(GetSubsystem<magic::UI>());
		web_idle_step();
#endif
		update_ui_fit();
		// A local server on its way out is reaped here rather than in
		// whoever asked for it to go ([QUIT_STALL])
		step_stop_local_server();
		// Before anything reads it: a scripted mouse_move's delta lands
		// at the top of the frame after the one that asked for it
		client::command_seq::apply_pending_mouse_move(
				GetSubsystem<magic::Input>());
		/*magic::AutoProfileBlock profiler_block(
				GetSubsystem<magic::Profiler>(), "App::on_update");*/

		check_lost_connection();
		if(g_shutdown_signal != 0 && !m_shutdown_signal_handled){
			m_shutdown_signal_handled = true;
			// SIGINT leaves a "^C" on the terminal to write past
			if(g_shutdown_signal == SIGINT)
				fprintf(stdout, "\n");
			log_i(MODULE, "%s; shutting down",
					g_shutdown_signal == SIGINT ? "SIGINT" : "SIGTERM");
			shutdown();
		}
		if(m_state){
			// Under a block of its own: the network's packets and the Lua
			// they run land here, and a frame that goes into them showed
			// as an Update with nothing in it ([FRAME_PEAK])
			magic::AutoProfileBlock profiler_block(
					GetSubsystem<magic::Profiler>(), "Buildat|State::update");
			m_state->update();
		}

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
		update_logical_placement();
		if(!client::command_seq::save_screenshot(
				GetSubsystem<magic::Graphics>(), path, &err,
				logical_mode() ? m_logical_w : 0, logical_mode() ? m_logical_h : 0,
				m_logical_ox, m_logical_oy, m_logical_scale))
			command_seq_fail(err);
	}

	void on_press(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		m_last_press_us = interface::os::time_us();
	}

	void on_keydown(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		m_last_press_us = interface::os::time_us();
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
		if(key == Urho3D::KEY_F12 && (event_data["Qualifiers"].GetInt() & Urho3D::QUAL_CTRL)){
			ss_ extname = "sandbox_scan";
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
		// **F9 to F12 are the client's, every other key an app's**
		// ([CLIENT_KEYS]); no script hears these four
		// (client/extensions/urho3d). F9 is the trusted overlay's.
		const bool ctrl = event_data["Qualifiers"].GetInt() & Urho3D::QUAL_CTRL;
		// F10: the engine's DebugHud, the profiler there is; Ctrl+F10 the
		// physics debug geometry
		if(key == Urho3D::KEY_F10 && !ctrl){
			magic::DebugHud *dhud = GetSubsystem<magic::Engine>()->CreateDebugHud();
			dhud->ToggleAll();
		}
		if(key == Urho3D::KEY_F10 && ctrl){
			m_draw_debug_geometry = !m_draw_debug_geometry;
			log_i(MODULE, "Ctrl+F10: physics debug geometry %s",
					m_draw_debug_geometry ? "on" : "off");
		}
		// F12 alone: a screenshot under <user>/screenshots, as official's
		// ([VIEW_KEYS]); Ctrl+F12 stays the sandbox test's
		if(key == Urho3D::KEY_F12 && !(event_data["Qualifiers"].GetInt() & Urho3D::QUAL_CTRL)){
			if(m_pending_screenshot.empty()){
				const ss_ dir = g_client_config.get<ss_>("user_path")+"/screenshots";
				const ss_ name = client::command_seq::screenshot_name(dir);
				m_pending_screenshot = dir+"/"+name;
				log_i(MODULE, "F12: screenshot %s", cs(name));
			}
		}
	}

	void remember_menu_ui()
	{
		m_menu_ui_children.clear();
		m_menu_ui_remembered = true;
		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!ui || !ui->GetRoot())
			return;
		const magic::Vector<magic::SharedPtr<magic::UIElement>> &cs =
				ui->GetRoot()->GetChildren();
		for(unsigned i = 0; i < cs.Size(); i++)
			m_menu_ui_children.push_back(cs[i]);
		log_v(MODULE, "remember_menu_ui(): %zu elements",
				m_menu_ui_children.size());
	}

	// Everything a game put on ui.root, and nothing the launcher or the
	// client owns. The client's own image is kept whether or not it was
	// there when the connection started -- it carries the world.
	void forget_game_ui()
	{
		if(!m_menu_ui_remembered)
			return;
		m_menu_ui_remembered = false;
		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!ui || !ui->GetRoot())
			return;
		magic::Vector<magic::SharedPtr<magic::UIElement>> cs =
				ui->GetRoot()->GetChildren();
		unsigned removed = 0;
		for(unsigned i = 0; i < cs.Size(); i++){
			magic::UIElement *e = cs[i];
			if(!e || e == m_preferred_image)
				continue;
			// **The client's own trusted overlay**, whenever it was made
			// ([TRUST_OVERLAY_LEAVE]): the trust colour's sample is made on
			// the first frame, and one made during a connection was taken
			// for the game's -- and its handler holds it
			if(e->GetName().StartsWith("__trusted"))
				continue;
			bool theirs = true;
			for(const auto &k : m_menu_ui_children){
				if(k == e){
					theirs = false;
					break;
				}
			}
			if(theirs){
				e->Remove();
				removed++;
			}
		}
		m_menu_ui_children.clear();
		log_i(MODULE, "forget_game_ui(): %u elements removed", removed);
	}

	// **Which extension is the launch UI** ([LAUNCH_SANDBOX]: a slot an
	// extension fills, not a setting with three values). `-m` wins for
	// the run it is given on; otherwise it is the saved preference,
	// which defaults to `launch_menu`.
	ss_ launch_ui_name()
	{
		const ss_ named = g_client_config.get<ss_>("menu_extension_name");
		if(!named.empty())
			return named;
		if(m_options.launch_ui.empty())
			return "launch_menu";
		return m_options.launch_ui;
	}

	void set_preferred_viewports(const sv_<magic::Viewport*> &viewports)
	{
		// **Who has the screen** ([LAUNCH_WORLD], 2026-09-24: the room
		// stands down too early). Taking the view is this call, and a
		// launcher that keeps drawing while a game loads has to know
		// when the game has actually taken it. The count lives here
		// rather than in client/extensions/urho3d because each sandbox has its
		// own copy of that file: a game bumping its own count is not
		// something the launcher's copy can see.
		m_viewport_generation++;
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
		// frame the client draws when nothing asked for anything -- except
		// in the scripted client, whose world always goes onto a texture of
		// the logical size ([SEQ_FIXED_SIZE])
		if(scale > 0.999f && scale < 1.001f && !logical_mode()){
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
		// The rects the game gave are in the window it saw; in logical
		// mode they are taken as fractions of it onto the logical frame
		float rx = 1.f, ry = 1.f;
		if(logical_mode()){
			tw = m_logical_w;
			th = m_logical_h;
			scale = 1.f;
			rx = (float)m_logical_w / (float)graphics->GetWidth();
			ry = (float)m_logical_h / (float)graphics->GetHeight();
		}
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
			magic::IntRect r = scaled_rect(m_preferred_rects[i], scale);
			if(logical_mode()){
				const magic::IntRect &p = m_preferred_rects[i];
				r = magic::IntRect((int)(p.left_ * rx), (int)(p.top_ * ry),
						(int)(p.right_ * rx), (int)(p.bottom_ * ry));
				if(n == 1)
					r = magic::IntRect(0, 0, tw, th);
			}
			m_preferred_viewports[i]->SetRect(r);
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
	// What a changed preference does now rather than at the next start. Each
	// one is applied only when it actually changed: setting a screen mode
	// that is already the screen mode still costs a mode change.
	void apply_changed_preferences(const app::Options &before)
	{
		const GraphicsOptions &g = m_options.graphics;
		const GraphicsOptions &b = before.graphics;
		if(m_options.sound_volume_db != before.sound_volume_db ||
				m_options.sound_mute != before.sound_mute)
			apply_sound_preferences();
		// The client's own level at once; the server's on its next start.
		// Not over a -l given for this run.
		if(m_options.log_level != before.log_level &&
				!g_client_config.get<bool>("log_level_given")){
			log_set_max_level(m_options.log_level);
			log_i(MODULE, "log level %d, from the preferences", m_options.log_level);
		}
		g_server_log_level_pref = m_options.server_log_level;
		if(g.max_fps != b.max_fps){
			if(magic::Engine *e = GetSubsystem<magic::Engine>())
				e->SetMaxFps(g.max_fps);
		}
		if(g.vsync != b.vsync || g.multisampling != b.multisampling){
			if(magic::Graphics *gr = GetSubsystem<magic::Graphics>())
				m_options.graphics.apply(gr);
		}
		if(g.render_scale != b.render_scale)
			apply_preferred_viewports();
	}

	void apply_sound_preferences()
	{
		magic::Audio *audio = GetSubsystem<magic::Audio>();
		if(!audio)
			return;
		// **The one place a decibel becomes a gain** ([VOLUME_LAW]).
		// Everything above this line -- the settings screen, the pause
		// menu, the room's desk -- carries decibels and nothing else.
		const float db = m_options.sound_volume_db;
		const float gain = (m_options.sound_mute ||
				db <= app::SOUND_OFF_DB + 0.01f) ? 0.0f :
				(float)pow(10.0, db / 20.0);
		audio->SetMasterGain("Master", gain);
	}

	// With the cursor hidden, Urho3D on Linux hands the focus back only on
	// a click inside the window, and drops it again the same frame if the
	// WM has not given the window SDL's input focus. A client that stops
	// taking the mouse looks like that; this is the line that says so
	// (doc/plan/luanti_module_history.md, [MOUSE_FOCUS_LOST]).
	// The reason and the state before it are Urho3D's line (Input.cpp,
	// [FOCUS_LOG]); this adds what only the client knows
	void on_inputfocus(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		log_i(MODULE, "input focus %s; a command sequence %s",
				event_data["Focus"].GetBool() ? "gained" : "lost",
				m_command_seq_active ? "is running" : "is not running");
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
		// An "auto" render scale follows the window's size
		settle_render_scale(&m_options);
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
			// Urho3D's INFO is chatter, except the input lines this tree
			// added to it ([FOCUS_LOG]): a lost mouse is read from a log
			// at info
			// (the message carries Urho's "INFO: " prefix)
			c55_level = (message.find("INFO: input ") != ss_::npos ||
					message.find("INFO: mouse ") != ss_::npos) ?
					CORE_INFO : CORE_VERBOSE;
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

		self->remember_menu_ui();
		ss_ error;
		bool ok = self->m_state->connect(to_local_pipe(address), &error);
		lua_pushboolean(L, ok);
		if(ok)
			lua_pushnil(L);
		else
			lua_pushstring(L, error.c_str());
		return 2;
	}

	// connect_server_start(address: string): the same connect on a worker,
	// so that the frame keeps drawing while it runs ([BOX_PLAYTEST_2] 12).
	// connect_server_poll() is what says how it went.
	static int l_connect_server_start(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ address = lua_bindings::lua_tocppstring(L, 1);
		self->remember_menu_ui();
		self->m_state->connect_start(to_local_pipe(address));
		return 0;
	}

	// connect_server_poll() -> status: "pending"|"ok"|"failed",
	// error: string or nil
	static int l_connect_server_poll(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ error;
		const int r = self->m_state->connect_poll(&error);
		lua_pushstring(L, r == 0 ? "pending" : (r > 0 ? "ok" : "failed"));
		if(r < 0)
			lua_pushstring(L, error.c_str());
		else
			lua_pushnil(L);
		return 2;
	}

	// list_launchers() -> {{kind = "app"|"builtin"|"extension", name, path},
	// ...}: every apps/<name>, builtin/<name> and extensions/<name> in the
	// tree, with whether it ships launcher/init.lua as `launcher = true`.
	// Nothing else is scanned -- not a save, not a Luanti game's mods. The
	// menu draws the launch grid from this and runs the launcher files in
	// the sandbox ([LAUNCH_GRID]).
	static int l_list_launchers(lua_State *L)
	{
		const ss_ share = g_client_config.get<ss_>("share_path");
		const struct { const char *kind; const char *dir; } kinds[] = {
			{"app", "apps"}, {"builtin", "builtin"},
			{"extension", "extensions"}};
		lua_newtable(L);
		int i = 1;
		for(const auto &k : kinds){
			const ss_ dir = share+"/"+k.dir;
			auto nodes = interface::fs::list_directory(dir);
			sv_<ss_> names;
			for(const auto &n : nodes)
				if(n.is_directory && valid_app_name(n.name))
					names.push_back(n.name);
			std::sort(names.begin(), names.end());
			for(const ss_ &name : names){
				const ss_ path = interface::fs::get_absolute_path(dir+"/"+name);
				lua_newtable(L);
				lua_pushstring(L, k.kind);
				lua_setfield(L, -2, "kind");
				lua_pushstring(L, name.c_str());
				lua_setfield(L, -2, "name");
				lua_pushstring(L, path.c_str());
				lua_setfield(L, -2, "path");
				lua_pushboolean(L, interface::fs::path_exists(
						path+"/launcher/init.lua"));
				lua_setfield(L, -2, "launcher");
				lua_rawseti(L, -2, i++);
			}
		}
		// And the apps installed from releases, every version a tile
		sv_<ss_> ids = installed_app_ids();
		for(const ss_ &id : ids){
			const ss_ path = interface::fs::get_absolute_path(
					installed_app_dir(id));
			lua_newtable(L);
			lua_pushstring(L, "installed");
			lua_setfield(L, -2, "kind");
			lua_pushstring(L, id.c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, path.c_str());
			lua_setfield(L, -2, "path");
			lua_pushboolean(L, interface::fs::path_exists(
					path+"/launcher/init.lua"));
			lua_setfield(L, -2, "launcher");
			lua_rawseti(L, -2, i++);
		}
		// And the installed extensions ([AITTA]), with no launcher: a
		// launcher launches apps, and one from Aitta launches only itself
		for(const ss_ &id : installed_app_ids(true)){
			const size_t dot = id.find('.'), at = id.find('@');
			const ss_ name = id.substr(0, dot)+"__"+
					id.substr(dot + 1, at - dot - 1);
			const ss_ path = interface::fs::get_absolute_path(
					installed_app_dir(id));
			lua_newtable(L);
			lua_pushstring(L, "extension");
			lua_setfield(L, -2, "kind");
			lua_pushstring(L, name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, path.c_str());
			lua_setfield(L, -2, "path");
			lua_pushstring(L, id.substr(at + 1).c_str());
			lua_setfield(L, -2, "version");
			lua_pushboolean(L, false);
			lua_setfield(L, -2, "launcher");
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// **A game's own icon, made reachable.** A Luanti game ships
	// menu/icon.png in its own directory under the user path, and a
	// resource dir may only be added under the cache path
	// (add_resource_dir()), so the file is copied there once, under
	// <cache>/installed_games/<app>/<name>.png -- namespaced by app and
	// game, so no two collide ([LAUNCH_API]). Returns the resource name to
	// draw it by, or "" where the game ships no icon.
	static ss_ installed_game_icon(lua_State *L, const ss_ &family,
			const ss_ &name)
	{
		const ss_ from = g_client_config.get<ss_>("user_path")+"/shared/"+
				family+"/games/"+name+"/menu/icon.png";
		if(!interface::fs::path_exists(from))
			return "";
		const ss_ root = g_client_config.get<ss_>("cache_path")+
				"/installed_games";
		const ss_ to = root+"/"+family+"/"+name+".png";
		// Copied when it is not there or the game's has changed size: a
		// game is installed rarely and this is asked every time the grid
		// is shown
		if(!interface::fs::path_exists(to) ||
				interface::fs::file_size(to) !=
				interface::fs::file_size(from)){
			interface::fs::create_directories(root+"/"+family);
			if(!interface::fs::copy_file(from, to)){
				log_w(MODULE, "installed_game_icon(): cannot copy %s",
						cs(from));
				return "";
			}
		}
		static std::set<ss_> added;
		if(added.insert(root).second){
			lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
			CApp *self = (CApp*)lua_touserdata(L, -1);
			lua_pop(L, 1);
			magic::ResourceCache *rc = self->GetSubsystem<
					magic::ResourceCache>();
			if(!rc->AddResourceDir(root.c_str()))
				log_w(MODULE, "installed_game_icon(): cannot add %s",
						cs(root));
		}
		return family+"/"+name+".png";
	}

	// list_installed_games(app) -> {{name =, size =, icon =}, ...}: the
	// directories under <user>/shared/<app>/games, for a launcher file that
	// offers a tile per game another engine's app installed -- "vanilla"
	// is the Luanti games ([PROCESS_SANDBOX]: what an app shares is
	// <user>/shared/<app>). In the sandbox: read-only and only that one
	// directory shape ([LAUNCH_GRID]).
	//
	// The size is the directory tree's, as list_apps() answers for a
	// buildat game, and it is what a launch action carries as its
	// significance ([LAUNCH_API]); the icon is the resource name of the
	// game's own menu/icon.png, or nil where the game ships none.
	static int l_list_installed_games(lua_State *L)
	{
		const ss_ family = lua_bindings::lua_tocppstring(L, 1);
		if(!valid_app_name(family))
			return luaL_error(L, "list_installed_games(): bad app");
		const ss_ dir = g_client_config.get<ss_>("user_path")+"/shared/"+
				family+"/games";
		sv_<ss_> names;
		for(const auto &n : interface::fs::list_directory(dir))
			if(n.is_directory && valid_app_name(n.name))
				names.push_back(n.name);
		std::sort(names.begin(), names.end());
		lua_newtable(L);
		int i = 1;
		for(const ss_ &name : names){
			lua_newtable(L);
			lua_pushstring(L, name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushnumber(L, (lua_Number)interface::fs::directory_tree_size(
					dir+"/"+name));
			lua_setfield(L, -2, "size");
			const ss_ icon = installed_game_icon(L, family, name);
			if(icon != ""){
				lua_pushstring(L, icon.c_str());
				lua_setfield(L, -2, "icon");
			}
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// list_saves([app]) -> {{app =, name =, modified =}, ...}: every
	// save under <user>/apps/<app>/saves/<name>/save.sqlite, newest
	// first, for the whole tree or for one app. That path is the
	// storage module's own (builtin/storage/storage.cpp), and it is
	// enumerated here rather than asked of a server because a launcher
	// has no server to ask -- which is what [LAUNCH_WORLD] wanted it
	// for: a save is a thing on its floor, listed beside its games.
	//
	// Read-only, names only, and only that one directory shape, as
	// list_installed_games() is.
	// The three lines builtin/storage keeps for itself; one caller here
	// does not earn a place in the fs interface
	static int64_t save_modified_us(const ss_ &path)
	{
		struct stat st;
		if(stat(path.c_str(), &st) != 0)
			return 0;
		return (int64_t)st.st_mtime * 1000000;
	}

	static int l_list_saves(lua_State *L)
	{
		ss_ only_game;
		if(lua_gettop(L) >= 1 && !lua_isnil(L, 1)){
			only_game = lua_bindings::lua_tocppstring(L, 1);
			if(!valid_app_name(only_game))
				return luaL_error(L, "list_saves(): bad app name");
		}
		const ss_ games = g_client_config.get<ss_>("user_path")+"/apps";
		struct Row { ss_ game, name; int64_t modified; };
		sv_<Row> rows;
		for(const auto &g : interface::fs::list_directory(games)){
			if(!g.is_directory || !valid_app_name(g.name))
				continue;
			if(only_game != "" && g.name != only_game)
				continue;
			const ss_ dir = games+"/"+g.name+"/saves";
			for(const auto &n : interface::fs::list_directory(dir)){
				// _server is the server's accounts (builtin/accounts), and a
				// save beginning with _ is none of the player's
				if(!n.is_directory || !valid_app_name(n.name) ||
						n.name[0] == '_')
					continue;
				const ss_ db = dir+"/"+n.name+"/save.sqlite";
				if(!interface::fs::path_exists(db))
					continue;
				rows.push_back(Row{g.name, n.name,
						save_modified_us(db)});
			}
		}
		// The one played last is the one most likely wanted next, which
		// is the order the vanilla menu puts them in
		std::sort(rows.begin(), rows.end(), [](const Row &a, const Row &b){
			if(a.modified != b.modified)
				return a.modified > b.modified;
			return a.name < b.name;
		});
		lua_newtable(L);
		int i = 1;
		for(const Row &r : rows){
			lua_newtable(L);
			lua_pushstring(L, r.game.c_str());
			lua_setfield(L, -2, "app");
			lua_pushstring(L, r.name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushnumber(L, (double)r.modified);
			lua_setfield(L, -2, "modified");
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// aitta_install(zip, sig) -> the directory, or nil and why: a release
	// fetched from an Aitta, checked and installed under <user>/installed
	// ([AITTA_MVP]). Trusted only: client/extensions/starport.
	static int l_aitta_install(lua_State *L)
	{
		const ss_ zip = lua_bindings::lua_tocppstring(L, 1);
		const ss_ sig = lua_bindings::lua_tocppstring(L, 2);
		const ss_ tmp = g_client_config.get<ss_>("cache_path")+"/tmp/aitta-"+
				interface::sha256::hex(interface::bignum::random_bytes(8));
		try {
			interface::fs::create_directories(
					g_client_config.get<ss_>("cache_path")+"/tmp");
			for(const auto &f : {std::make_pair(tmp+".zip", zip),
					std::make_pair(tmp+".sig", sig)}){
				std::ofstream o(f.first, std::ios::binary);
				o<<f.second;
				if(!o.good())
					throw Exception("cannot write "+f.first);
			}
			const ss_ dir = interface::aitta::install(tmp+".zip", tmp+".sig",
					g_client_config.get<ss_>("user_path"));
			interface::fs::remove_all(tmp+".zip");
			interface::fs::remove_all(tmp+".sig");
			lua_pushstring(L, dir.c_str());
			return 1;
		} catch(std::exception &e){
			interface::fs::remove_all(tmp+".zip");
			interface::fs::remove_all(tmp+".sig");
			lua_pushnil(L);
			lua_pushstring(L, e.what());
			return 2;
		}
	}

	// list_apps() -> {{name=, size=}, ...}
	static int l_list_apps(lua_State *L)
	{
		ss_ games_dir = g_client_config.get<ss_>("share_path")+"/apps";
		auto nodes = interface::fs::list_directory(games_dir);
		sv_<ss_> names;
		for(const auto &n : nodes){
			if(!n.is_directory || !valid_app_name(n.name))
				continue;
			names.push_back(n.name);
		}
		std::sort(names.begin(), names.end());
		for(const ss_ &id : installed_app_ids())
			names.push_back(id);
		lua_newtable(L);
		int i = 1;
		for(const ss_ &name : names){
			ss_ game_path = app_dir(name);
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

	// start_local_server(game: string [, launch: string]) -> status: bool,
	// error: string or nil. launch is what an untrusted launcher asked for,
	// key=value a line, handed to the server as -u ([LAUNCH_GRID]); never
	// the environment, since a sandboxed script choosing a child's
	// environment is a breach.
	static int l_start_local_server(lua_State *L)
	{
		ss_ game = lua_bindings::lua_tocppstring(L, 1);
		ss_ launch = lua_isstring(L, 2) ? lua_bindings::lua_tocppstring(L, 2) : "";
		ss_ game_path = app_dir(game);
		if(game_path.empty()){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Invalid app name");
			return 2;
		}
		// An app from a release is someone else's code: never started with
		// the box off ([AITTA_MVP])
		{
			const char *u = getenv("BUILDAT_UNCONFINED");
			const char *w = getenv("BUILDAT_WINDOWS_BOX");
			if(!installed_app_dir(game).empty() &&
					((u && ss_(u) == "1") || (w && ss_(w) == "0"))){
				lua_pushboolean(L, false);
				lua_pushstring(L, "An installed app runs only in the server's\n"
						"box, and it is off here\n(BUILDAT_UNCONFINED=1 or "
						"BUILDAT_WINDOWS_BOX=0).");
				return 2;
			}
		}

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
#ifndef _WIN32
		// The server compiles a game's modules as it loads them, and on
		// Linux the compiler is the system's ([PACKAGING]): said here, in
		// the dialog, rather than as a server that exits at once
		if(interface::process::shell_exec("c++ --version >/dev/null 2>&1") != 0){
			lua_pushboolean(L, false);
			lua_pushstring(L, "No C++ compiler (c++) found in PATH.\n"
					"buildat compiles a game's modules as it loads them.\n"
					"Debian, Ubuntu:  sudo apt install build-essential\n"
					"Fedora:  sudo dnf install gcc-c++");
			return 2;
		}
#endif

		game_path = interface::fs::get_absolute_path(game_path);
		g_local_server_app = server_app_id(game);
		g_local_server_port = pick_free_local_port();
		log_i(MODULE, "Starting local server on port %s", cs(g_local_server_port));
		{
			const ss_ raw = interface::bignum::random_bytes(16);
			g_local_server_token.clear();
			static const char *hex = "0123456789abcdef";
			for(unsigned char c : raw){
				g_local_server_token += hex[c >> 4];
				g_local_server_token += hex[c & 15];
			}
#ifdef _WIN32
			_putenv_s("BUILDAT_OWNER_TOKEN", g_local_server_token.c_str());
#else
			setenv("BUILDAT_OWNER_TOKEN", g_local_server_token.c_str(), 1);
#endif
		}
		sv_<ss_> args{"-m", game_path, "-P", g_local_server_port,
				// This machine only, until its owner opens it to the LAN
				// from the pause menu (the user's call, [SECURITY_RUN_1])
				"-A", "127.0.0.1",
				// The client's own paths, so that a client started on other
				// paths than the build's (-D, -C, the same letters both sides: a test on empty ones,
				// [FIRST_RUN]) has its server on the same
				// Absolute, as the log path below is and for the same
				// reason: the child's cwd is not this process's, and a
				// relative -D then names a directory beside the tree
				// rather than the tree's own -- the server made its saves
				// somewhere the client never looks (2026-09-24)
				"-D", interface::fs::get_absolute_path(
						g_client_config.get<ss_>("user_path")),
				"-C", interface::fs::get_absolute_path(
						g_client_config.get<ss_>("cache_path"))};
		// The server the client starts writes beside the client's own log
		// when there is one: half of what a bug report is about happens over
		// there, and -L asked for a log of the session. Not the same file --
		// a line here is several fprintf calls and log_no_nl leaves one
		// unfinished on purpose, so two processes appending to one file
		// splice each other's halves.
		// And always one ([START_PROGRESS]): a player's client has no
		// -L, and its server then logged nowhere -- nothing to read after
		// a failed start, and nothing for the waiting screen to tail.
		// cache/local_server_<port>.log at info, truncated per start;
		// the port tells several clients' servers from one tree apart.
		// The server's log beside the client's: <log>_server.<ext>, and
		// the client's is absolute by now (boot::autodetect::open_log), so
		// the child finds it wherever it starts ([WIN8_START]: a relative
		// path resolved against the child's cwd, which on one box was
		// nowhere -- "Invalid file handle. Error is 3"). The previous one
		// is rotated to _1 beside it, as the client's own is. With the
		// client on its default log that is cache/buildat_server.log.
		// The server's log beside the client's -L: <log>_server.<ext>,
		// absolute by now (boot::autodetect::open_log), so the child finds
		// it wherever it starts ([WIN8_START]: a relative path resolved
		// against the child's cwd, which on one box was nowhere --
		// "Invalid file handle. Error is 3"). Rotation is the server's
		// own (open_log, the same for every path). With no -L the server
		// defaults to <cache>/buildat_server.log by itself.
		const ss_ log_file = g_client_config.get<ss_>("log_file");
		if(!log_file.empty()){
			const size_t slash = log_file.find_last_of("/\\");
			const size_t dot = log_file.find_last_of('.');
			const bool has_ext = dot != ss_::npos &&
					(slash == ss_::npos || dot > slash);
			g_local_server_log = (has_ext ? log_file.substr(0, dot) : log_file)+
					"_server"+(has_ext ? log_file.substr(dot) : ss_());
			args.push_back("-L");
			args.push_back(g_local_server_log);
			args.push_back("-l");
			args.push_back(itos(log_get_max_level()));
		} else {
			// The server's level from the preferences ([LOG_LEVEL_PREF]);
			// a -l given to this client for the run is handed on instead
			args.push_back("-l");
			args.push_back(itos(g_client_config.get<bool>("log_level_given") ?
					log_get_max_level() : g_server_log_level_pref));
			g_local_server_log = g_client_config.get<ss_>("cache_path")+
					"/buildat_server.log";
		}
		g_local_server_log_offset = 0;
		g_local_server_listening = false;
		g_local_server_started_s = (int64_t)time(NULL);
		g_local_server_status.clear();
		log_i(MODULE, "server log: %s", cs(g_local_server_log));
		// And whether that server restarts a module when its source
		// changes, which is off unless this client was asked for it
		if(g_client_config.get<bool>("reload_modules"))
			args.push_back("-R");
		// The server knows it is this launcher's: its own user joins by
		// name alone, and a game keeps its launcher-only doors open
		// (builtin/accounts, [VANILLA_PUBLIC] 1). Whoever else starts a
		// server gives it no -u, and it is a public one.
		args.push_back("-u");
		args.push_back(launch.empty() ? ss_("launcher=1") :
				"launcher=1\n"+launch);
		// Started in the root, whatever the client's cwd: from bin/ (a
		// click on the exe) every path it forms would be off by one
		g_local_server = interface::process::start(server_path, args,
				g_client_config.get<ss_>("root_path"));
		// The child has it; nothing started later inherits it
#ifdef _WIN32
		_putenv_s("BUILDAT_OWNER_TOKEN", "");
#else
		unsetenv("BUILDAT_OWNER_TOKEN");
#endif
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
		// Across frames ([QUIT_STALL]): the blocking one froze the
		// window for up to twelve seconds when a UI handler called it
		begin_stop_local_server();
		return 0;
	}

	// user_activated() -> bool: the window has the input and the user
	// pressed or let go of a key, a button or the screen within a second
	// -- what a browser calls user activation, for what may only follow
	// the user's own action (the clipboard's write, safe_classes.lua)
	static int l_user_activated(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushboolean(L, self->GetSubsystem<magic::Input>()->HasFocus() &&
				interface::os::time_us() - self->m_last_press_us < 1000000);
		return 1;
	}

	// set_ui_scale(scale: number)  -- <=0 restores auto/config
	static int l_set_ui_scale(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		double s = lua_tonumber(L, 1);
		// 0.25 to 8: a server's Lua asking for 1e308 made every glyph a
		// page of its own that failed, a frame in tens of seconds
		self->m_ui_scale_lua = (s > 0) ? (float)std::max(0.25, std::min(s, 8.0)) : 0.f;
		self->apply_ui_scale();
		return 0;
	}

	// logical_size() -> w, h: the frame a scan's and a sequence's pixels
	// are in -- the -w size in a scripted client ([SEQ_FIXED_SIZE]), the
	// window otherwise
	static int l_logical_size(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::Graphics *g = self->GetSubsystem<magic::Graphics>();
		if(self->logical_mode()){
			lua_pushinteger(L, self->m_logical_w);
			lua_pushinteger(L, self->m_logical_h);
		} else {
			lua_pushinteger(L, g ? g->GetWidth() : 0);
			lua_pushinteger(L, g ? g->GetHeight() : 0);
		}
		return 2;
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

	// viewport_generation() -> number: how many times anybody has set
	// the preferred viewports in this run ([LAUNCH_WORLD]). A launch UI
	// records it when a launch commits and watches for it to change,
	// which is the game taking the screen; sandbox-safe, and a number
	// rather than a callback because the reader asks once a frame.
	static int l_viewport_generation(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushinteger(L, self->m_viewport_generation);
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

	// The preferences a screen can show and change. Their values live in
	// app::Options and the C++ side is what parses, range checks and
	// persists them, so a screen is a page of widgets over these two calls
	// and knows nothing about the file.
	static const char** preference_names()
	{
		static const char *names[] = {"render_scale", "vsync", "max_fps",
				"multisampling", "sound_volume_db", "sound_mute", "launch_ui",
				"default_username",
#ifdef __EMSCRIPTEN__
				// Only where it does something
				"web_idle_fps",
#endif
				nullptr};
		return names;
	}

	// launch_ui_fell_back() -> the name of the launch UI that was asked
	// for and did not load, or nil. What the one that did load says to
	// the user, so a setting that quietly does nothing is not a thing
	// this slot can do ([LAUNCH_SANDBOX]).
	static int l_launch_ui_fell_back(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		if(self->m_launch_ui_fell_back.empty())
			lua_pushnil(L);
		else
			lua_pushstring(L, self->m_launch_ui_fell_back.c_str());
		return 1;
	}

	// get_preference(name) -> number, boolean or string, or nil for a name there is
	// no preference by
	static int l_get_preference(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ name = luaL_checkstring(L, 1);
		const app::Options &o = self->m_options;
		if(name == "render_scale" && o.graphics.render_scale_auto)
			lua_pushstring(L, "auto");
		else if(name == "render_scale")
			lua_pushnumber(L, o.graphics.render_scale);
		else if(name == "vsync")
			lua_pushboolean(L, o.graphics.vsync);
		else if(name == "max_fps")
			lua_pushinteger(L, o.graphics.max_fps);
		else if(name == "web_idle_fps")
			lua_pushinteger(L, o.graphics.web_idle_fps);
		else if(name == "multisampling")
			lua_pushinteger(L, o.graphics.multisampling);
		else if(name == "sound_volume_db")
			lua_pushnumber(L, o.sound_volume_db);
		else if(name == "sound_mute")
			lua_pushboolean(L, o.sound_mute);
		else if(name == "launch_ui")
			lua_pushstring(L, o.launch_ui.c_str());
		else if(name == "default_username")
			lua_pushstring(L, o.default_username.c_str());
		else if(name == "log_level")
			lua_pushinteger(L, o.log_level);
		else if(name == "server_log_level")
			lua_pushinteger(L, o.server_log_level);
		else
			lua_pushnil(L);
		return 1;
	}

	// set_preference(name, value) -> true, or false and why
	//
	// Through the same parser -o and the preferences file go through, so a
	// range check is written once and a screen cannot set something a flag
	// could not. What it changes takes effect now and is persisted, unless
	// this run was told not to remember anything -- a -o run, a -c run --
	// in which case it still takes effect and save_preferences() declines.
	static int l_set_preference(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ name = luaL_checkstring(L, 1);
		ss_ value;
		if(lua_isboolean(L, 2))
			value = lua_toboolean(L, 2) ? "1" : "0";
		else
			value = luaL_checkstring(L, 2);

		app::Options parsed = self->m_options;
		ss_ err;
		if(!app::parse_preference_options(name+"="+value, &parsed, &err)){
			lua_pushboolean(L, 0);
			lua_pushstring(L, err.c_str());
			return 2;
		}
		settle_render_scale(&parsed);
		const app::Options before = self->m_options;
		self->m_options = parsed;
		self->apply_changed_preferences(before);
		save_preferences(self->m_options);
		lua_pushboolean(L, 1);
		return 1;
	}

	// get_env(name) -> the environment variable, or nil when unset or when
	// the name does not start with BUILDAT_. A knob a harness sets on the
	// client's process, the way extensions/luanti_client reads its own
	// outside the sandbox; the prefix is the fence, so a game cannot read
	// the user's environment through this.
	// HTTP for the extension environment ([SERVER_LIST]: Luanti's official
	// server list): __buildat_http_get(url[, body]) starts a fetch -- a POST of JSON with a body -- on a thread of
	// its own and answers a job id; __buildat_http_poll(id) answers nil
	// while it runs, then (true, body) or (false, error) once, and forgets
	// the job. A redirect is not followed: (false, why, target) says where
	// it led, and the extension asks about that host as about any other. Who may fetch what is the network extension's question,
	// which gates this behind its permission dialog the way it gates a
	// socket; the sandbox never sees these two names.
	struct HttpJob {
		std::thread thread;
		std::atomic<bool> done{false};
		bool ok = false;
		ss_ result;
		ss_ redirect;
	};
	std::map<int, sp_<HttpJob>> m_http_jobs;
	int m_http_next_id = 1;

	// **JSON for the sandbox** ([URHO_SWEEP], 2026-09-25): a game that
	// fetched a body with `network.http_get` had no way to read it, and
	// Urho3D's own JSONValue is not the answer -- its GetRoot() hands
	// Lua a pointer into the file, which dangles the moment the file is
	// collected. The parse is the client's own (core/json.h, sajson) and
	// what comes back is **plain Lua**: tables, strings, numbers and
	// booleans, so nothing holds a C++ object and no lifetime crosses
	// the sandbox.
	//
	// null becomes nil, which in an array leaves a hole -- said in
	// client_api.txt, because a length that stops early is otherwise a
	// puzzle. A document deeper than this nests no further.
	static const int JSON_MAX_DEPTH = 64;
	static void push_json(lua_State *L, const json::Value &v, int depth)
	{
		if(depth > JSON_MAX_DEPTH){
			lua_pushnil(L);
			return;
		}
		switch(v.get_type()){
		case json::Value::T_BOOL:
			lua_pushboolean(L, v.as_boolean());
			break;
		case json::Value::T_INT:
			lua_pushnumber(L, (lua_Number)v.as_integer());
			break;
		case json::Value::T_FLOAT:
			lua_pushnumber(L, (lua_Number)v.as_real());
			break;
		case json::Value::T_STRING:
			lua_pushstring(L, v.as_cstring());
			break;
		case json::Value::T_ARRAY: {
			lua_newtable(L);
			const unsigned int n = v.size();
			for(unsigned int i = 0; i < n; i++){
				push_json(L, v.at(i), depth + 1);
				lua_rawseti(L, -2, (int)i + 1);
			}
			break;
		}
		case json::Value::T_OBJECT: {
			lua_newtable(L);
			for(json::Iterator it(v); it.valid(); it.next()){
				push_json(L, it.value(), depth + 1);
				lua_setfield(L, -2, it.ckey());
			}
			break;
		}
		default:
			lua_pushnil(L);
			break;
		}
	}

	// parse_json(text) -> value, or nil and why not
	static int l_parse_json(lua_State *L)
	{
		size_t len = 0;
		const char *text = luaL_checklstring(L, 1, &len);
		// A trust boundary: the body came off the network. sajson holds
		// the whole document in memory and the copy here doubles it, so
		// the size is capped rather than left to the fetch's own limits.
		if(len > 8u * 1024 * 1024){
			lua_pushnil(L);
			lua_pushstring(L, "parse_json: over 8 MB");
			return 2;
		}
		json::json_error_t err;
		const json::Value v = json::load_string(text, &err);
		if(v.get_type() == json::Value::T_UNDEFINED){
			lua_pushnil(L);
			lua_pushfstring(L, "parse_json: %s (line %d, column %d)",
					err.text, err.line, err.column);
			return 2;
		}
		push_json(L, v, 0);
		return 1;
	}

	static int l_http_get(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ url = luaL_checkstring(L, 1);
		// A second argument, a body, makes it a POST of JSON ([STARPORT])
		const bool post = lua_isstring(L, 2);
		const ss_ body = post ? lua_bindings::lua_tocppstring(L, 2) : ss_();
#ifdef __EMSCRIPTEN__
		// [WEB_ID_TRUST] (c): the browser's fetch(), under its rules -- the
		// other origin answers with CORS or the fetch fails. text/plain so
		// a POST is a simple request (no preflight; Starport reads the
		// body whatever its type). A redirect is not followed and says
		// no target: the browser does not tell it.
		const int id = self->m_http_next_id++;
		web_fetch(id, url.c_str(), post ? 1 : 0, body.data(), (int)body.size());
		lua_pushinteger(L, id);
		return 1;
#else
		sp_<HttpJob> job(new HttpJob());
		const int id = self->m_http_next_id++;
		self->m_http_jobs[id] = job;
		HttpJob *j = job.get();
		j->thread = std::thread([j, url, post, body](){
			try {
				j->result = post ? interface::http_post(url, body,
						"application/json", &j->redirect) :
						interface::http_get(url, &j->redirect);
				j->ok = j->redirect.empty();
				if(!j->ok)
					j->result = "redirected to "+j->redirect;
			} catch(std::exception &e){
				j->result = e.what();
			}
			j->done = true;
		});
		lua_pushinteger(L, id);
		return 1;
#endif
	}

	static int l_http_poll(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const int id = (int)luaL_checkinteger(L, 1);
#ifdef __EMSCRIPTEN__
		// -1 no such job, -2 running, else the length; ok in the sign of
		// a second call's answer
		const int len = EM_ASM_INT({
			var jobs = Module['buildatHttp'] || {};
			if(!(($0) in jobs)) return -1;
			var j = jobs[$0];
			return j ? j.data.length : -2;
		}, id);
		if(len == -2){
			lua_pushnil(L);
			return 1;
		}
		if(len == -1){
			lua_pushboolean(L, false);
			lua_pushstring(L, "no such fetch");
			return 2;
		}
		ss_ data(len, '\0');
		const int ok = EM_ASM_INT({
			var jobs = Module['buildatHttp'];
			var j = jobs[$0];
			delete jobs[$0];
			HEAPU8.set(j.data, $1);
			return j.ok ? 1 : 0;
		}, id, &data[0]);
		(void)self;
		lua_pushboolean(L, ok);
		lua_pushlstring(L, data.data(), data.size());
		return 2;
#else
		auto it = self->m_http_jobs.find(id);
		if(it == self->m_http_jobs.end()){
			lua_pushboolean(L, false);
			lua_pushstring(L, "no such fetch");
			return 2;
		}
		if(!it->second->done){
			lua_pushnil(L);
			return 1;
		}
		sp_<HttpJob> job = it->second;
		self->m_http_jobs.erase(it);
		job->thread.join();
		lua_pushboolean(L, job->ok);
		lua_pushlstring(L, job->result.c_str(), job->result.size());
		if(job->redirect.empty())
			return 2;
		lua_pushlstring(L, job->redirect.c_str(), job->redirect.size());
		return 3;
#endif
	}

	static int l_get_env(lua_State *L)
	{
		const ss_ name = luaL_checkstring(L, 1);
		if(name.compare(0, 8, "BUILDAT_") != 0){
			lua_pushnil(L);
			return 1;
		}
		const char *v = getenv(name.c_str());
		if(v)
			lua_pushstring(L, v);
		else
			lua_pushnil(L);
		return 1;
	}

	// is_scripted() -> true when a command sequence drives this client
	static int l_is_scripted(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushboolean(L, self->m_command_seq_active);
		return 1;
	}

	// list_preferences() -> {name, ...}
	static int l_list_preferences(lua_State *L)
	{
		const char **names = preference_names();
		lua_newtable(L);
		for(int i = 0; names[i]; i++){
			lua_pushstring(L, names[i]);
			lua_rawseti(L, -2, i + 1);
		}
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

	// The local server's log from where the last read left off, for its
	// "STATUS ..." lines; "STATUS Listening" is the one readiness reads
	static void tail_local_server_log()
	{
		if(g_local_server_log.empty())
			return;
		// Not the run before: a default log is rotated away by the child
		// when it starts, and until then the file here is the old one,
		// with an old "Listening" in it
		struct stat st;
		if(stat(g_local_server_log.c_str(), &st) != 0 ||
				(int64_t)st.st_mtime < g_local_server_started_s)
			return;
		std::ifstream f(g_local_server_log, std::ios::binary);
		if(!f.good())
			return;
		f.seekg(g_local_server_log_offset);
		ss_ line;
		while(std::getline(f, line)){
			g_local_server_log_offset += line.size() + 1;
			// A log written on Windows ends its lines in \r\n, and the
			// status read as "Listening\r" never matched ([WIN8_START] 12)
			if(!line.empty() && line[line.size() - 1] == '\r')
				line.erase(line.size() - 1);
			const size_t at = line.find("STATUS ");
			if(at != ss_::npos){
				g_local_server_status = line.substr(at + 7);
				if(g_local_server_status == "Listening")
					g_local_server_listening = true;
			}
		}
	}

	// local_server_ready() -> bool: the server runs and has logged that it
	// listens. Read from its log rather than by connecting to it: a probe
	// connect was a peer to the server, one that vanished before it said
	// anything, and the server warned about it twice per start
	// ([WIN8_START] 11). A server started by somebody else (the pidfile's)
	// has no log here and is probed.
	static int l_local_server_ready(lua_State *L)
	{
		adopt_pidfile();
		if(!interface::process::is_running(g_local_server)){
			lua_pushboolean(L, false);
			return 1;
		}
		if(g_local_server_log.empty()){
			lua_pushboolean(L, local_server_answers());
			return 1;
		}
		tail_local_server_log();
		// And the port itself, once the log says so: a "Listening" read
		// off a log the previous run left (the box's first ContentDB try,
		// 2026-09-21: the client then connected to a server still
		// loading and sat in the connect for good) is not a server. The
		// non-blocking probe is a peer to the server for a moment, which
		// is the price of not trusting a file.
		lua_pushboolean(L, g_local_server_listening && local_server_answers());
		return 1;
	}

	// local_server_status() -> string or nil: the last "STATUS ..." line
	// the local server logged, read from where the last call left off
	static int l_local_server_status(lua_State *L)
	{
		tail_local_server_log();
		if(g_local_server_status.empty())
			lua_pushnil(L);
		else
			lua_pushstring(L, g_local_server_status.c_str());
		return 1;
	}

	// local_server_log_tail(lines) -> path, text: the local server's log
	// file and its last lines, for a dialog about a server that died
	static int l_local_server_log_tail(lua_State *L)
	{
		const int want = luaL_optinteger(L, 1, 20);
		lua_pushstring(L, g_local_server_log.c_str());
		std::ifstream f(g_local_server_log, std::ios::binary);
		std::deque<ss_> lines;
		ss_ line;
		while(f.good() && std::getline(f, line)){
			if(!line.empty() && line[line.size() - 1] == '\r')
				line.erase(line.size() - 1);
			// The dialog does not wrap, and a file list can be a
			// thousand characters: the line's start is the part that
			// says what it was
			if(line.size() > 160)
				line = line.substr(0, 157) + "...";
			lines.push_back(line);
			if((int)lines.size() > want)
				lines.pop_front();
		}
		ss_ text;
		for(const ss_ &l : lines)
			text += l + "\n";
		lua_pushstring(L, text.c_str());
		return 2;
	}

	// local_server_port() -> string
	static int l_local_server_port(lua_State *L)
	{
		lua_pushstring(L, g_local_server_port.c_str());
		return 1;
	}

	// local_server_running() -> bool
	// game_storage_dir() -> the directory under the user path where the
	// game code of the server this client is connected to keeps what it
	// stores on the client, or nil when there is no server: like a web
	// page's localStorage, one per origin. A server this client started is
	// its game's (the port changes every launch); any other its address's,
	// so a server cannot read what another one, or a local game, stored.
	// server_address() -> the address the client is connected to, or nil.
	// Trusted only: client/extensions/starport's report of the server one is on
	static int l_server_address(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ address = self->m_state ? self->m_state->get_address() : "";
		if(address.empty())
			return 0;
		lua_pushlstring(L, address.c_str(), address.size());
		return 1;
	}

	// lan_address() -> "a.b.c.d" or nothing: this machine's address on the
	// LAN, for the pause menu's "Open to LAN" to say. Only while connected
	// to the server this client started: to any other, where this machine
	// is on its network is not that server's business.
	// keep_server_icon(png) -> its hash, or nil: a Starport listing's icon
	// ([SERVER_ICONS]), checked and kept as the handshake's is
	static int l_keep_server_icon(lua_State *L)
	{
		size_t n = 0;
		const char *d = luaL_checklstring(L, 1, &n);
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ sha = self->keep_icon(ss_(d, n), "a Starport");
		if(sha.empty())
			return 0;
		lua_pushstring(L, sha.c_str());
		return 1;
	}

	static int l_lan_address(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ address = self->m_state ? self->m_state->get_address() : "";
		if(self->owner_token_for(address).empty())
			return 0;
		const ss_ lan = interface::local_lan_address();
		if(lan.empty())
			return 0;
		lua_pushlstring(L, lan.c_str(), lan.size());
		return 1;
	}

	// lan_servers() -> {{host, port, name, app, version, players,
	// account}, ...}: the servers announcing themselves on the LAN
	// ([LAN_DISCOVERY]), heard within 6 s. Empty while connected to a
	// server: what is on this machine's network is not a server's
	// business. An announcement is anyone's to send, so every field is
	// cleaned and capped, a sender is heard once a second, and the list
	// holds 32.
	// simplified: the socket stays open once the launcher has asked; the
	// kernel drops what is not read. Closing it on a connect when a
	// game's long session makes that matter.
	void lan_listen()
	{
		if(m_lan_fd != -1 || m_lan_tried)
			return;
		m_lan_tried = true;
		m_lan_fd = interface::lan_socket(true);
		log_i(MODULE, "Listening for LAN games on %s:%i%s",
				interface::LAN_GROUP, interface::LAN_PORT,
				m_lan_fd == -1 ? ": cannot" :
#ifdef _WIN32
				" (Windows may ask whether to let this program hear "
				"the network: that is what for)"
#else
				""
#endif
				);
	}

	static ss_ lan_clean(const json::Value &v, size_t max, bool ident)
	{
		if(!v.is_string())
			return "";
		ss_ out;
		for(unsigned char c : v.as_string()){
			if(out.size() >= max)
				break;
			if(ident ? (isalnum(c) || c == '_' || c == '-' || c == '.' ||
					c == '+') : (c >= 0x20 && c != 0x7f))
				out += (char)c;
		}
		// A cut multibyte character goes
		while(!out.empty() && ((unsigned char)out.back() & 0xc0) == 0x80)
			out.pop_back();
		if(!out.empty() && ((unsigned char)out.back() & 0xc0) == 0xc0)
			out.pop_back();
		return out;
	}

	static int l_lan_servers(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_newtable(L);
		if(self->m_state && !self->m_state->get_address().empty())
			return 1;
		self->lan_listen();
		const int64_t now = interface::os::time_us();
		ss_ data, from;
		for(int i = 0; i < 256 && self->m_lan_fd != -1 &&
				interface::lan_recv(self->m_lan_fd, &data, &from); i++){
			const json::Value v = json::load_string(data.c_str());
			if(!v.is_object() || !v.get("buildat_lan").is_integer() ||
					v.get("buildat_lan").as_integer() != 1 ||
					!v.get("port").is_integer())
				continue;
			const int64_t port = v.get("port").as_integer();
			if(port < 1 || port > 65535)
				continue;
			const ss_ key = from+":"+itos(port);
			auto it = self->m_lan.find(key);
			if(it == self->m_lan.end()){
				if(self->m_lan.size() >= 32){
					if(!self->m_lan_full_said)
						log_w(MODULE, "LAN list full (32): %s and others "
								"not shown", cs(key));
					self->m_lan_full_said = true;
					continue;
				}
			} else if(now - it->second.heard_us < 1000000){
				continue;
			}
			LanEntry &e = self->m_lan[key];
			e.name = lan_clean(v.get("name"), 64, false);
			e.app = lan_clean(v.get("app"), 32, true);
			e.version = lan_clean(v.get("version"), 32, true);
			const json::Value &pl = v.get("players");
			e.players = pl.is_integer() ? std::max<int64_t>(0,
					std::min<int64_t>(pl.as_integer(), 100000)) : 0;
			e.account = v.get("account").is_true();
			e.heard_us = now;
		}
		int n = 0;
		for(auto it = self->m_lan.begin(); it != self->m_lan.end();){
			if(now - it->second.heard_us > 6000000){
				it = self->m_lan.erase(it);
				continue;
			}
			const LanEntry &e = it->second;
			const size_t colon = it->first.rfind(':');
			lua_newtable(L);
			lua_pushstring(L, it->first.substr(0, colon).c_str());
			lua_setfield(L, -2, "host");
			lua_pushstring(L, it->first.substr(colon + 1).c_str());
			lua_setfield(L, -2, "port");
			lua_pushstring(L, e.name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, e.app.c_str());
			lua_setfield(L, -2, "app");
			lua_pushstring(L, e.version.c_str());
			lua_setfield(L, -2, "version");
			lua_pushinteger(L, e.players);
			lua_setfield(L, -2, "players");
			lua_pushboolean(L, e.account);
			lua_setfield(L, -2, "account");
			lua_rawseti(L, -2, ++n);
			++it;
		}
		return 1;
	}

	static int l_game_storage_dir(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		ss_ address = self->m_state ? self->m_state->get_address() : "";
		if(address.empty())
			return 0;
		ss_ user = g_client_config.get<ss_>("user_path");
		adopt_pidfile();
		bool local = !g_local_server_app.empty() &&
				interface::process::is_running(g_local_server) &&
				(address == "localhost:"+g_local_server_port ||
				address == "127.0.0.1:"+g_local_server_port ||
				(!local_pipe().empty() && address == "pipe:"+local_pipe()));
		ss_ dir;
		if(local){
			dir = user+"/apps/"+g_local_server_app+"/client";
		} else {
			// One directory name: what is not a letter, a digit, - or . is _
			ss_ name = address;
			for(char &c : name)
				if(!(isalnum((unsigned char)c) || c == '-' || c == '.'))
					c = '_';
			dir = user+"/servers/"+name;
		}
		lua_pushstring(L, dir.c_str());
		return 1;
	}

	static int l_local_server_running(lua_State *L)
	{
		adopt_pidfile();
		lua_pushboolean(L, interface::process::is_running(g_local_server));
		return 1;
	}

	// disconnect()
	// leave_to_menu(): a menu-only connection left for the launcher without
	// exiting the client ([MENU_CONTEXT]): the local server stopped, the
	// state made ready for another connection, and the sandbox's leavings
	// dropped (client/sandbox.lua). The UI stack is the launcher's to pop.
	static int l_leave_to_menu(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		log_i(MODULE, "leave_to_menu()");
		// **Across frames** ([QUIT_STALL], 2026-09-24): this is called
		// from a Lua UI handler -- it is what "quitting a game" runs --
		// and the blocking stop sleeps up to twelve seconds inside it,
		// with the window dead to the compositor for all of them. The
		// SIGTERM goes now and on_update() reaps the child and
		// force-kills it if it will not go; a menu-only server is gone
		// in a second anyway.
		begin_stop_local_server();
		self->m_state->reset();
		self->m_lost_connection_us = 0;
		// **The last frame of the game goes with the game** ([MENU_LEAVE],
		// 2026-09-27). A game drawn through set_preferred_viewports() --
		// which is every game at a render scale -- is rendered into a
		// texture that a UI image shows, and `forget_game_ui()` skips
		// that image on purpose (it is the client's, not the game's). So
		// leaving emptied the scene and took the viewports away while the
		// image stayed, and the launcher's grid came up over the last
		// frame of the world: driven, the picture two seconds after the
		// leave was the same picture, to the pixel.
		self->drop_preferred_texture();
		self->m_preferred_viewports.clear();
		self->m_preferred_rects.clear();
		self->forget_game_ui();
		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_reset_sandbox");
		if(lua_isfunction(L, -1))
			error_logging_pcall(L, 0, 0);
		else
			lua_pop(L, 1);
		// **The game's sounds go with the game** ([MENU_MUSIC], 2026-10-04):
		// a SoundSource is mixed from its construction to its destruction,
		// scene or no scene, so a looped one whose node the reset took out
		// of the scene -- held by the game's Lua until a collection --
		// went on playing in the launch menu. Everything playing now is
		// the game's: the launch menu plays nothing.
		// simplified: all of them; a launch UI that plays its own sounds
		// through a game would need to keep those apart.
		if(magic::Audio *audio = self->GetSubsystem<magic::Audio>()){
			unsigned n = 0;
			for(magic::SoundSource *s : audio->GetSoundSources()){
				if(s->IsPlaying())
					n++;
				s->Stop();
			}
			log_i(MODULE, "leave_to_menu(): %u sounds stopped", n);
		}
		self->say_what_is_left("leave_to_menu");
		return 0;
	}

	// **What a leave leaves** ([MENU_LEAVE]): the scene the game filled,
	// the viewports that draw it and the camera they draw through, said
	// once at the end of a leave. The report is that the launcher's grid
	// comes up over a world that is still there, and a leave that says
	// what it did not take is the difference between reading that and
	// guessing at it.
	void say_what_is_left(const char *when)
	{
		ss_ line = ss_("what is left after ") + when + ": ";
		if(m_scene){
			const unsigned n = m_scene->GetNumChildren(false);
			line += "the scene holds " + itos(n) + " children";
			unsigned said = 0;
			for(unsigned i = 0; i < n && said < 8; i++){
				magic::Node *c = m_scene->GetChild(i);
				if(!c)
					continue;
				line += (said == 0 ? " (" : ", ");
				line += ss_(c->GetName().CString()) + "#" +
						itos(c->GetID()) + " " +
						itos(c->GetNumComponents()) + " components";
				said++;
			}
			if(said)
				line += n > said ? ", ..." : "";
			if(said)
				line += ")";
		} else {
			line += "no scene";
		}
		// The image the client shows a game's render target through: it
		// is the client's own element, so `forget_game_ui()` leaves it,
		// and it is the last frame of the world if it is still here
		line += ss_("; the preferred image is ") +
				(m_preferred_image ? "still here" : "gone");
		magic::Renderer *r = GetSubsystem<magic::Renderer>();
		if(r){
			line += "; " + itos(r->GetNumViewports()) + " viewports";
			for(unsigned i = 0; i < r->GetNumViewports(); i++){
				magic::Viewport *vp = r->GetViewport(i);
				if(!vp)
					continue;
				magic::Scene *sc = vp->GetScene();
				magic::Camera *cam = vp->GetCamera();
				line += ss_(", ") + itos(i) + ": scene " +
						(sc ? (sc == m_scene ? "the game's" : "another") :
						"none") + ", camera " +
						(cam ? (cam->GetNode() ?
						cam->GetNode()->GetName().CString() : "unnamed") :
						"none");
			}
		}
		log_i(MODULE, "%s", cs(line));
	}

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
		if(name == "user"){
			ss_ path = g_client_config.get<ss_>("user_path");
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

	// set_reload_on_return(bool): on the web, whether a disconnect while
	// the page was away reloads it on the return, which is what a phone's
	// browser dropping a page in the background calls for. A light game
	// asks for it; a heavy one leaves the user to say, with the page's
	// reload button (user, 2026-09-30). Nothing natively.
	static int l_set_reload_on_return(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		EM_ASM({ Module['buildatReloadOnReturn'] = !!$0; },
				lua_toboolean(L, 1) ? 1 : 0);
#endif
		(void)L;
		return 0;
	}

	// set_web_fullscreen(bool): on a touchscreen's web page, whether the
	// page is fullscreen, which is what puts a phone browser's address bar
	// away. Entering waits for the next tap; nothing natively.
	static int l_set_web_fullscreen(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		EM_ASM({
			Module['buildatFullscreen'] = !!$0;
			Module['buildatSyncFullscreen']();
		}, lua_toboolean(L, 1) ? 1 : 0);
#endif
		(void)L;
		return 0;
	}

	// [WEB_ID_TRUST] web_authorize(url) -> whether a window opened (the
	// browser blocks one not right after a click): a Starport's /authorize
	// page, which posts a token back to this page. web_authorized() -> the
	// message as JSON once that page has sent it, from that page's origin
	// only; nil until then. Trusted Lua's (the starport extension); nothing
	// natively.
	static int l_web_authorize(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		const char *url = luaL_checkstring(L, 1);
		int ok = EM_ASM_INT({
			// The page's own origin, so a page with no game of its own
			// (play.buildat.org, the Starport's web_clients) is told apart
			var url = UTF8ToString($0) + '&origin=' +
					encodeURIComponent(location.origin);
			Module['buildatAuthMsg'] = null;
			Module['buildatAuthOrigin'] = new URL(url).origin;
			if(!Module['buildatAuthListen']){
				Module['buildatAuthListen'] = true;
				window.addEventListener('message', function(e){
					var d = e.data;
					if(e.origin === Module['buildatAuthOrigin'] && d &&
							typeof d.buildat_starport_token === 'string')
						Module['buildatAuthMsg'] = JSON.stringify(d);
				});
			}
			return window.open(url, 'buildat_starport',
					'popup,width=480,height=680') ? 1 : 0;
		}, url);
		lua_pushboolean(L, ok);
#else
		(void)L;
		lua_pushboolean(L, 0);
#endif
		return 1;
	}
	static int l_web_authorized(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		char *msg = (char*)EM_ASM_PTR({
			var m = Module['buildatAuthMsg'];
			Module['buildatAuthMsg'] = null;
			return m ? stringToNewUTF8(m) : 0;
		});
		if(msg){
			lua_pushstring(L, msg);
			free(msg);
			return 1;
		}
#endif
		lua_pushnil(L);
		return 1;
	}

	// [PLAY_PAGE] (c) web_dgram(op, ...): the web's datagram socket (see
	// web_dgram_open above); trusted Lua's (the network extension).
	// ("open", url) -> id; ("send", id, data); ("recv", id) -> a datagram,
	// "" when none; ("state", id) -> "connecting", "open" or "closed: why";
	// ("close", id). Nothing natively.
	static int l_web_dgram(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		const ss_ op = luaL_checkstring(L, 1);
		if(op == "open"){
			lua_pushinteger(L, web_dgram_open(luaL_checkstring(L, 2)));
			return 1;
		}
		const int id = (int)luaL_checkinteger(L, 2);
		if(op == "send"){
			size_t n = 0;
			const char *p = luaL_checklstring(L, 3, &n);
			web_dgram_send(id, p, (int)n);
		} else if(op == "recv"){
			const int n = web_dgram_peek(id);
			ss_ d(n > 0 ? n : 0, '\0');
			if(n >= 0)
				web_dgram_take(id, &d[0]);
			lua_pushlstring(L, d.data(), d.size());
			return 1;
		} else if(op == "state"){
			char *s = web_dgram_state(id);
			lua_pushstring(L, s);
			free(s);
			return 1;
		} else if(op == "close"){
			web_dgram_close(id);
		}
#endif
		return 0;
	}

	// set_watchdog_seconds(n): how long without a frame before the
	// watchdog logs this thread's stack; 0 puts the default (10) back
	static int l_set_watchdog_seconds(lua_State *L)
	{
		int n = (int)luaL_optinteger(L, 1, 0);
		g_watchdog_seconds = n > 0 ? n : 10;
		return 0;
	}

	// create_directories(path) -> bool: the directory and its parents, for
	// trusted Lua keeping a file of its own under the user path (the
	// extension's settings made its directory with a shell's mkdir, which
	// Windows has no such of; [BOX_PLAYTEST_2] 1). Unsafe: not in the
	// sandbox, where a path is not a thing a game gets to name.
	static int l_create_directories(lua_State *L)
	{
		ss_ path = lua_bindings::lua_tocppstring(L, 1);
		lua_pushboolean(L, interface::fs::create_directories(path));
		return 1;
	}

	// count_files(path) -> the number of entries in the directory
	static int l_count_files(lua_State *L)
	{
		ss_ path = lua_bindings::lua_tocppstring(L, 1);
		lua_pushinteger(L, interface::fs::list_directory(path).size());
		return 1;
	}

	// take_screenshot() -> the file name it was saved under, or nil and why
	// not.
	//
	// **Safe, and this is the argument for it.** The caller says when, and
	// nothing else: the client picks the directory -- <user>/screenshots --
	// and the name, the date and the time it was taken. Sandboxed
	// code cannot choose a path, cannot read what it wrote, and cannot
	// overwrite an existing shot. What it can do is fill a directory with
	// pictures of the screen, which is what the screenshot key already does
	// and what a game the user is running can reasonably ask for -- a
	// comparison harness photographing itself is the case this was added
	// for; see [ONE_CYCLE] in doc/plan/rendering_plan.md.
	//
	// The file lands at the end of the frame, not inside this call: the
	// buffer is only whole once the frame is drawn, which is why the command
	// sequence's screenshot goes through the same pending slot. The name is
	// reserved by then, so it is the right one to report.
	static int l_take_screenshot(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		// One pending shot at a time: the command sequence uses the same
		// slot, and overwriting it would drop somebody else's picture
		if(!self->m_pending_screenshot.empty()){
			lua_pushnil(L);
			lua_pushstring(L, "a screenshot is already pending");
			return 2;
		}
		// **A run's worth** ([SECURITY_RUN_1]): one a frame was a server's
		// script filling the disk at a frame rate.
		// simplified: per client run, as save_file's
		static int s_shots = 0;
		if(s_shots >= 1000){
			lua_pushnil(L);
			lua_pushstring(L, "1000 screenshots taken already in this run");
			return 2;
		}
		s_shots++;
		const ss_ dir = g_client_config.get<ss_>("user_path")+"/screenshots";
		const ss_ name = client::command_seq::screenshot_name(dir);
		self->m_pending_screenshot = dir+"/"+name;
		lua_pushlstring(L, name.c_str(), name.size());
		return 1;
	}

	// **Files a game hands the user and takes from them** ([FP_EXPORT] 4).
	// The sandbox has no file access of its own, and gets none here: the
	// client picks where a file goes and where one may come from. On
	// native that is <user>/exports, found by the user as the screenshots
	// are; on the web, the browser's download and file picker (the page's
	// buildatFiles, src/client/web/index.html).
	static ss_ exports_dir()
	{
		return g_client_config.get<ss_>("user_path")+"/exports";
	}

	// A name of letters, digits, _ - and ., not hidden, as a file in there
	static ss_ user_file_name(const ss_ &in)
	{
		ss_ out;
		for(char c : in.substr(0, 100))
			out += isalnum((unsigned char)c) || c == '_' || c == '-' ||
					c == '.' ? c : '_';
		while(!out.empty() && out[0] == '.')
			out.erase(0, 1);
		return out.empty() ? "file" : out;
	}

	// save_file(name, data) -> where it went: the path on native, "" for the
	// web's download; or nil and why not. Native never overwrites: a name
	// taken gets _2, _3...
	static int l_save_file(lua_State *L)
	{
		size_t name_len = 0, len = 0;
		const char *name_c = luaL_checklstring(L, 1, &name_len);
		const char *data = luaL_checklstring(L, 2, &len);
		const ss_ name = user_file_name(ss_(name_c, name_len));
		// **A run's worth, not a disk's** ([SECURITY_RUN_1]): a server's
		// script saving in a loop filled the user's disk with no one
		// asking. Not the user's key or click as the clipboard's is: an
		// export is the server's answer, a round trip after the click.
		// simplified: per client run; a run that exports more starts again
		static size_t s_files = 0, s_bytes = 0;
		if(len > MAX_USER_FILE_BYTES || s_files >= 100 ||
				s_bytes + len > 4 * MAX_USER_FILE_BYTES){
			lua_pushnil(L);
			lua_pushstring(L, len > MAX_USER_FILE_BYTES ?
					"the file is over 64 MiB" :
					"100 files or 256 MiB saved already in this run");
			return 2;
		}
		s_files++;
		s_bytes += len;
#ifdef __EMSCRIPTEN__
		EM_ASM({
			if(window.buildatFiles)
				buildatFiles.save(UTF8ToString($0), HEAPU8.slice($1, $1 + $2));
		}, name.c_str(), data, len);
		lua_pushstring(L, "");
		return 1;
#else
		const ss_ dir = exports_dir();
		interface::fs::create_directories(dir);
		const size_t dot = name.find_last_of('.');
		const ss_ stem = dot == ss_::npos ? name : name.substr(0, dot);
		const ss_ ext = dot == ss_::npos ? "" : name.substr(dot);
		ss_ path = dir+"/"+name;
		for(int i = 2; interface::fs::path_exists(path); i++)
			path = dir+"/"+stem+"_"+itos(i)+ext;
		std::ofstream os(path, std::ios::binary);
		os.write(data, len);
		if(!os.good()){
			lua_pushnil(L);
			lua_pushstring(L, ("could not write "+path).c_str());
			return 2;
		}
		lua_pushlstring(L, path.c_str(), path.size());
		return 1;
#endif
	}

	// exported_files() -> the names of the files in <user>/exports; none on
	// the web, which has pick_file()
	static int l_exported_files(lua_State *L)
	{
		lua_newtable(L);
#ifndef __EMSCRIPTEN__
		int i = 1;
		for(const auto &n : interface::fs::list_directory(exports_dir())){
			if(n.is_directory || n.name != user_file_name(n.name))
				continue;
			lua_pushlstring(L, n.name.c_str(), n.name.size());
			lua_rawseti(L, -2, i++);
		}
#endif
		return 1;
	}

	// read_exported(name) -> the bytes of that file in <user>/exports, or
	// nil and why not
	static int l_read_exported(lua_State *L)
	{
		const ss_ name = luaL_checkstring(L, 1);
		const ss_ path = exports_dir()+"/"+name;
		if(name != user_file_name(name) || !interface::fs::path_exists(path)){
			lua_pushnil(L);
			lua_pushstring(L, "no such file");
			return 2;
		}
		if(interface::fs::file_size(path) > MAX_USER_FILE_BYTES){
			lua_pushnil(L);
			lua_pushstring(L, "the file is over 64 MiB");
			return 2;
		}
		std::ifstream is(path, std::ios::binary);
		std::ostringstream data;
		data<<is.rdbuf();
		const ss_ s = data.str();
		lua_pushlstring(L, s.data(), s.size());
		return 1;
	}

	// pick_file([accept]) -> whether a picker opened: the web's file picker,
	// accept as the input element's (".fpplan"). What it picks comes from
	// picked_file(). False on native, which has exported_files().
	static int l_pick_file(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		const char *accept = luaL_optstring(L, 1, "");
		EM_ASM({
			if(window.buildatFiles)
				buildatFiles.pick(UTF8ToString($0));
		}, accept);
		lua_pushboolean(L, 1);
#else
		lua_pushboolean(L, 0);
#endif
		return 1;
	}

	// picked_file() -> name, data once the picked file has been read; nil
	// until then; nil and why not for one that is too big
	static int l_picked_file(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		int len = EM_ASM_INT({
			var p = window.buildatFiles && buildatFiles.picked;
			return p ? p.data.length : -1;
		});
		if(len < 0){
			lua_pushnil(L);
			return 1;
		}
		if((size_t)len > MAX_USER_FILE_BYTES){
			EM_ASM({ buildatFiles.picked = null; });
			lua_pushnil(L);
			lua_pushstring(L, "the file is over 64 MiB");
			return 2;
		}
		ss_ data(len, '\0');
		char *name = (char*)EM_ASM_PTR({
			var p = buildatFiles.picked;
			buildatFiles.picked = null;
			HEAPU8.set(p.data, $0);
			return stringToNewUTF8(p.name);
		}, &data[0]);
		lua_pushstring(L, name);
		free(name);
		lua_pushlstring(L, data.data(), data.size());
		return 2;
#else
		lua_pushnil(L);
		return 1;
#endif
	}

	// dump_meshes([atlas_json]) -> the file name it was saved under, or nil
	// and why not. The optional string is written as <stem>_atlas.json
	// beside the dump: the atlas registry's own account of which resource
	// owns which tile, which the caller has and this does not.
	//
	// Same sandbox rule as take_screenshot(): the caller says when, the
	// client picks <user>/meshdumps and a dated name. Writes the scene's
	// CustomGeometry as one .obj in world space -- the meshes the client
	// already built, not a second voxel dump. For [PATH_TRACE_REF].
	static int l_dump_meshes(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		// Under the node given, else the scene the server replicates: a game
		// with a scene of its own hands over its root
		magic::Node *root = self->m_scene;
		if(lua_isuserdata(L, 2))
			root = (magic::Node*)tolua_tousertype(L, 2, 0);
		if(!root){
			lua_pushnil(L);
			lua_pushstring(L, "no scene");
			return 2;
		}
		// **A run's worth** ([SECURITY_RUN_1]): a whole scene a call, as
		// many calls as a server's script makes in a frame.
		// simplified: per client run, as save_file's
		static int s_dumps = 0;
		if(s_dumps >= 20){
			lua_pushnil(L);
			lua_pushstring(L, "20 mesh dumps made already in this run");
			return 2;
		}
		s_dumps++;

		const ss_ dir = g_client_config.get<ss_>("user_path")+"/meshdumps";
		if(!interface::fs::create_directories(dir)){
			lua_pushnil(L);
			lua_pushstring(L, "cannot create meshdumps");
			return 2;
		}
		char stamp[32] = {};
		const time_t t = time(nullptr);
		struct tm tmv;
#ifdef _WIN32
		localtime_s(&tmv, &t);
#else
		localtime_r(&t, &tmv);
#endif
		strftime(stamp, sizeof stamp, "%Y%m%d_%H%M%S", &tmv);
		// Gzipped as it is written: the raw text of a RANGE=150 dump is
		// ~800 MB and writing it held this thread past the server's
		// 30 s stall limit; through zlib at level 1 it is a sixth of that.
		ss_ name = ss_("meshdump_")+stamp+".obj.gz";
		for(int i = 2; i < 1000 &&
				interface::fs::path_exists(dir+"/"+name); i++)
			name = ss_("meshdump_")+stamp+"_"+itos(i)+".obj.gz";
		const ss_ path = dir+"/"+name;
		// The atlas account the caller hands over, written beside the dump
		// once the textures below are named: its last object is
		// "textures", the read-back file of each atlas texture by address
		const ss_ atlas_json = lua_isstring(L, 1) ? ss_(lua_tostring(L, 1)) : "";

		gzFile f = gzopen(path.c_str(), "wb1");
		if(!f){
			lua_pushnil(L);
			lua_pushstring(L, "cannot write dump");
			return 2;
		}
		// A gzprintf a line is what took a minute on ten million verts,
		// which is past the server's stall limit; a megabyte at a time
		// through gzwrite is seconds
		ss_ buf;
		buf.reserve(1 << 20);
		char line[256];
		auto put = [&](int n){
			if(n > 0)
				buf.append(line, (size_t)n);
			if(buf.size() >= (1 << 20) - 256){
				gzwrite(f, buf.data(), (unsigned)buf.size());
				buf.clear();
			}
		};

		magic::PODVector<magic::Camera*> cams;
		root->GetComponents<magic::Camera>(cams, true);
		if(!cams.Empty() && cams[0]->GetNode()){
			magic::Node *cn = cams[0]->GetNode();
			const magic::Vector3 p = cn->GetWorldPosition();
			const magic::Vector3 d = cn->GetWorldDirection();
			put(snprintf(line, sizeof line, "# camera_pos %g %g %g\n# camera_dir %g %g %g\n",
					p.x_, p.y_, p.z_, d.x_, d.y_, d.z_));
		}

		// The albedo: each batch's diffuse texture, read back once a session
		// and saved beside the dump as meshdump_texN.png, named by usemtl
		// so the render can put it on. The atlas is a handful of textures
		// for a whole world, which is why the read-back is keyed by texture
		// and not by batch or by dump.
		sm_<magic::Texture2D*, ss_> &tex_names = self->m_dumped_textures;
		// What this dump reads back, encoded and written on a thread of its
		// own once the .obj is out: the read-back is the GPU's and quick,
		// the encoding is what took a minute
		sv_<std::pair<ss_, magic::SharedPtr<magic::Image>>> to_write;
		auto material_of = [&](magic::Material *mat) -> ss_ {
			if(!mat)
				return "";
			magic::Texture2D *tex = dynamic_cast<magic::Texture2D*>(
					mat->GetTexture(magic::TU_DIFFUSE));
			if(!tex)
				return "";
			auto it = tex_names.find(tex);
			if(it != tex_names.end())
				return it->second;
			// Named by the session's count, not the dump's, so a texture
			// written for an earlier dump is the same file for this one
			const ss_ stem = "meshdump_tex"+itos(tex_names.size());
			const ss_ png = stem+".png";
			magic::SharedPtr<magic::Image> img = tex->GetImage();
			if(img)
				to_write.push_back(std::make_pair(dir+"/"+png, img));
			// The material maps the pbr shader reads beside the albedo --
			// the atlas's derived normal (spots in alpha) and surface
			// (roughness, spec strength, translucency, spots) -- as
			// <stem>_normal.png and <stem>_spec.png when the material has
			// them. [PT_MATERIALS]
			const struct { magic::TextureUnit unit; const char *suffix; }
					maps[] = {{magic::TU_NORMAL, "_normal"},
					{magic::TU_SPECULAR, "_spec"}};
			for(const auto &m : maps){
				magic::Texture2D *t2 = dynamic_cast<magic::Texture2D*>(
						mat->GetTexture(m.unit));
				magic::SharedPtr<magic::Image> mi = t2 ? t2->GetImage() :
						magic::SharedPtr<magic::Image>();
				if(mi)
					to_write.push_back(std::make_pair(
							dir+"/"+stem+m.suffix+".png", mi));
			}
			tex_names[tex] = png;
			return png;
		};
		auto write_atlas_json = [&](){
			if(atlas_json.empty())
				return;
			ss_ j = atlas_json;
			// Into the top-level object: replace its closing brace
			size_t end = j.rfind('}');
			if(end == ss_::npos)
				return;
			std::ostringstream os;
			os<<", \"textures\": {";
			bool first = true;
			for(const auto &p : tex_names){
				os<<(first ? "\n" : ",\n")<<"\""<<(uintptr_t)p.first<<"\": \""
						<<p.second<<"\"";
				first = false;
			}
			os<<"\n}}\n";
			j = j.substr(0, end) + os.str();
			FILE *af = fopen((dir+"/"+name.substr(0, name.size() - 7)+
					"_atlas.json").c_str(), "w");
			if(af){
				fwrite(j.data(), 1, j.size(), af);
				fclose(af);
			}
		};

		magic::PODVector<magic::CustomGeometry*> geoms;
		root->GetComponents<magic::CustomGeometry>(geoms, true);
		const int64_t t_start = interface::os::time_us();
		int64_t t_tex = 0;
		unsigned vbase = 1;
		unsigned ngeom = 0, nvert = 0, ntri = 0;
		magic::Vector3 eye(0, 0, 0);
		float far_clip = 1e9f; // not "far": a Windows macro
		if(!cams.Empty() && cams[0]->GetNode()){
			eye = cams[0]->GetNode()->GetWorldPosition();
			far_clip = cams[0]->GetFarClip();
		}
		for(unsigned gi = 0; gi < geoms.Size(); gi++){
			magic::CustomGeometry *cg = geoms[gi];
			magic::Node *node = cg->GetNode();
			if(!node)
				continue;
			// The dump is what the picture shows: skip chunks outside the
			// viewing range. +64 is one voxelworld section.
			if((node->GetWorldPosition() - eye).Length() > far_clip + 64.f)
				continue;
			const magic::Matrix3x4 &wt = node->GetWorldTransform();
			magic::Vector<magic::PODVector<magic::CustomGeometryVertex>>
					&batches = cg->GetVertices();
			for(unsigned b = 0; b < batches.Size(); b++){
				const magic::PODVector<magic::CustomGeometryVertex> &vs =
						batches[b];
				if(vs.Size() < 3)
					continue;
				ngeom++;
				magic::Geometry *geom = cg->GetLodGeometry(b, 0);
				magic::VertexBuffer *vb = geom ? geom->GetVertexBuffer(0) : nullptr;
				const bool has_tangent = vb &&
						(vb->GetElementMask() & magic::MASK_TANGENT);
				const int64_t t0 = interface::os::time_us();
				const ss_ mname = material_of(cg->GetMaterial(b));
				t_tex += interface::os::time_us() - t0;
				put(snprintf(line, sizeof line, "o geom_%u_%u\nusemtl %s\n", gi, b,
						mname.c_str()));
				for(unsigned i = 0; i < vs.Size(); i++){
					const magic::Vector3 wp = wt * vs[i].position_;
					// The tint, as the OBJ vertex colour after the position:
					// an albedo multiplier, which is what the shader does
					// with it. It is the 5-6-5 in the tangent's x
					// (pack_tint565 in impl/mesh.cpp) and only when the
					// buffer declares a tangent -- the mesher writes one
					// only for a format with a surface modifier, and for a
					// Luanti world the field is unwritten memory. White
					// otherwise. The vertex colour is the light and stays
					// out: Cycles makes its own; VoxeLibre's palette
					// colours are baked into atlas tiles and never a tint.
					float tr = 1.f, tg = 1.f, tb = 1.f;
					if(has_tangent){
						const unsigned t = (unsigned)(vs[i].tangent_.x_ + 0.5f);
						if(t > 0 && t < 65536){
							tr = (t >> 11) / 31.f;
							tg = ((t >> 5) & 63) / 63.f;
							tb = (t & 31) / 31.f;
						}
					}
					// No vn: the render takes the normal from the winding
					put(snprintf(line, sizeof line, "v %g %g %g %g %g %g\nvt %g %g\n",
							wp.x_, wp.y_, wp.z_, tr, tg, tb,
							vs[i].texCoord_.x_, vs[i].texCoord_.y_));
				}
				for(unsigned i = 0; i + 2 < vs.Size(); i += 3){
					const unsigned a = vbase + i;
					put(snprintf(line, sizeof line, "f %u/%u %u/%u %u/%u\n",
							a, a, a+1, a+1, a+2, a+2));
					ntri++;
				}
				vbase += vs.Size();
				nvert += vs.Size();
			}
		}
		if(!buf.empty())
			gzwrite(f, buf.data(), (unsigned)buf.size());
		gzclose(f);
		write_atlas_json();
		if(!to_write.empty())
			self->queue_textures(to_write);
		log_i(MODULE, "dump_meshes %s: %u geoms, %u verts, %u tris in %.1f s, "
				"%.1f s of it reading textures back; %zu textures being "
				"written behind it",
				cs(name), ngeom, nvert, ntri,
				(interface::os::time_us() - t_start) / 1e6, t_tex / 1e6,
				to_write.size());
		lua_pushlstring(L, name.c_str(), name.size());
		return 1;
	}

	// extension_path(name: string)
	// [EXTENSIONS_SANDBOXED]: the client's own extensions -- the sandbox
	// itself and what needs trust -- are in client/extensions and come
	// first, so that nothing in extensions/ takes one of their names
	static int l_extension_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);
		const ss_ share = g_client_config.get<ss_>("share_path");
		ss_ path = share+"/client/extensions/"+name;
		if(!interface::fs::path_exists(path+"/init.lua"))
			path = share+"/extensions/"+name;
		// One from Aitta; "__" is in no name of the tree's
		const ss_ installed = installed_extension_dir(name);
		if(!installed.empty())
			path = installed;
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
