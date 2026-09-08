// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "client/command_seq.h"
#include "core/log.h"
#include "interface/fs.h"
#include <c55/string_util.h>
#include <Graphics.h>
#include <Image.h>
#include <Input.h>
#include <FileSystem.h>
#include <SDL/SDL.h>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <climits>
#define MODULE "cmdseq"
namespace magic = Urho3D;

namespace client {
namespace command_seq {

static ss_ trim_copy(const ss_ &s)
{
	return c55::trim(s);
}

static bool parse_i64(const ss_ &s, int64_t *out)
{
	if(s.empty())
		return false;
	errno = 0;
	char *end = nullptr;
	long long v = strtoll(s.c_str(), &end, 10);
	if(errno || end == s.c_str() || *end != '\0')
		return false;
	*out = (int64_t)v;
	return true;
}

static bool parse_int(const ss_ &s, int *out)
{
	int64_t v = 0;
	if(!parse_i64(s, &v))
		return false;
	if(v < (int64_t)INT_MIN || v > (int64_t)INT_MAX)
		return false;
	*out = (int)v;
	return true;
}

static void split_cmd(const ss_ &line, ss_ *cmd, ss_ *rest)
{
	size_t i = 0;
	while(i < line.size() && (line[i] == ' ' || line[i] == '\t'))
		i++;
	size_t j = i;
	while(j < line.size() && line[j] != ' ' && line[j] != '\t')
		j++;
	*cmd = line.substr(i, j - i);
	size_t k = j;
	while(k < line.size() && (line[k] == ' ' || line[k] == '\t'))
		k++;
	*rest = line.substr(k);
}

static bool parse_button(const ss_ &s, int *sdl_button, ss_ *error)
{
	ss_ t;
	t.reserve(s.size());
	for(char c : s)
		t.push_back((char)tolower((unsigned char)c));
	if(t == "left" || t == "l" || t == "1" || t == "lmb"){
		*sdl_button = SDL_BUTTON_LEFT;
		return true;
	}
	if(t == "middle" || t == "m" || t == "2" || t == "mmb"){
		*sdl_button = SDL_BUTTON_MIDDLE;
		return true;
	}
	if(t == "right" || t == "r" || t == "3" || t == "rmb"){
		*sdl_button = SDL_BUTTON_RIGHT;
		return true;
	}
	if(t == "x1" || t == "4"){
		*sdl_button = SDL_BUTTON_X1;
		return true;
	}
	if(t == "x2" || t == "5"){
		*sdl_button = SDL_BUTTON_X2;
		return true;
	}
	*error = "Unknown mouse button \""+s+"\" (left, middle, right)";
	return false;
}

static bool parse_xy(const ss_ &rest, int *x, int *y, ss_ *error)
{
	c55::Strfnd f(rest);
	ss_ xs = trim_copy(f.next(" "));
	ss_ ys = trim_copy(f.next(""));
	if(xs.empty() || ys.empty() || !parse_int(xs, x) || !parse_int(ys, y)){
		*error = "Expected two integers";
		return false;
	}
	return true;
}

static bool parse_body(const ss_ &text, sv_<Command> *out, ss_ *error)
{
	out->clear();
	int line_no = 0;
	size_t i = 0;
	while(i <= text.size()){
		size_t nl = text.find('\n', i);
		ss_ line;
		if(nl == ss_::npos){
			line = text.substr(i);
			i = text.size() + 1;
		} else {
			line = text.substr(i, nl - i);
			i = nl + 1;
		}
		line_no++;
		if(!line.empty() && line.back() == '\r')
			line.pop_back();
		line = trim_copy(line);
		if(line.empty() || line[0] == '#')
			continue;

		ss_ cmd;
		ss_ rest;
		split_cmd(line, &cmd, &rest);

		auto fail = [&](const ss_ &msg){
			*error = "line "+itos(line_no)+": "+msg;
			out->clear();
			return false;
		};

		Command c;
		if(cmd == "delay"){
			c.type = Type::Delay;
			if(!parse_i64(rest, &c.n) || c.n < 0)
				return fail("delay <ms> (non-negative integer)");
		} else if(cmd == "screenshot"){
			c.type = Type::Screenshot;
			c.s = rest;
			if(c.s.empty())
				return fail("screenshot <path>");
		} else if(cmd == "keydown"){
			c.type = Type::KeyDown;
			c.s = rest;
			if(c.s.empty())
				return fail("keydown <key>");
		} else if(cmd == "keyup"){
			c.type = Type::KeyUp;
			c.s = rest;
			if(c.s.empty())
				return fail("keyup <key>");
		} else if(cmd == "keypress"){
			c.type = Type::KeyPress;
			c.s = rest;
			if(c.s.empty())
				return fail("keypress <key>");
		} else if(cmd == "mouse_pos"){
			c.type = Type::MousePos;
			if(!parse_xy(rest, &c.x, &c.y, error))
				return fail(*error);
		} else if(cmd == "mouse_move"){
			c.type = Type::MouseMove;
			if(!parse_xy(rest, &c.x, &c.y, error))
				return fail(*error);
		} else if(cmd == "mouse_down"){
			c.type = Type::MouseDown;
			if(!parse_button(rest, &c.x, error))
				return fail(*error);
		} else if(cmd == "mouse_up"){
			c.type = Type::MouseUp;
			if(!parse_button(rest, &c.x, error))
				return fail(*error);
		} else if(cmd == "mouse_click"){
			c.type = Type::MouseClick;
			if(!parse_button(rest, &c.x, error))
				return fail(*error);
		} else if(cmd == "mouse_wheel"){
			c.type = Type::MouseWheel;
			if(!parse_i64(rest, &c.n))
				return fail("mouse_wheel <delta>");
		} else if(cmd == "text"){
			c.type = Type::Text;
			c.s = rest;
			if(c.s.empty())
				return fail("text <string>");
		} else if(cmd == "quit"){
			c.type = Type::Quit;
			if(!rest.empty())
				return fail("quit takes no arguments");
		} else {
			return fail("unknown command \""+cmd+"\"");
		}
		out->push_back(c);
	}
	return true;
}

static void self_check()
{
	sv_<Command> cs;
	ss_ err;
	const char *sample =
			"# comment\n"
			"delay 100\n"
			"keydown W\n"
			"keyup W\n"
			"keypress Space\n"
			"mouse_pos 10 20\n"
			"mouse_move -1 2\n"
			"mouse_down left\n"
			"mouse_up left\n"
			"mouse_click right\n"
			"mouse_wheel 3\n"
			"text hello\n"
			"screenshot /tmp/x.png\n"
			"quit\n";
	if(!parse_body(sample, &cs, &err))
		throw Exception(ss_()+"command_seq self_check parse: "+err);
	if(cs.size() != 13)
		throw Exception("command_seq self_check count "+itos(cs.size()));
	if(cs[0].type != Type::Delay || cs[0].n != 100)
		throw Exception("command_seq self_check delay");
	if(cs[5].type != Type::MouseMove || cs[5].x != -1 || cs[5].y != 2)
		throw Exception("command_seq self_check mouse_move");
	if(cs[6].x != SDL_BUTTON_LEFT || cs[8].x != SDL_BUTTON_RIGHT)
		throw Exception("command_seq self_check buttons");
	if(!parse_body("nope 1\n", &cs, &err) && err.find("unknown command") != ss_::npos)
		return;
	throw Exception("command_seq self_check unknown command");
}

bool parse(const ss_ &text, sv_<Command> *out, ss_ *error)
{
	self_check();
	return parse_body(text, out, error);
}

static ss_ button_name(int sdl_button)
{
	if(sdl_button == SDL_BUTTON_LEFT)
		return "left";
	if(sdl_button == SDL_BUTTON_MIDDLE)
		return "middle";
	if(sdl_button == SDL_BUTTON_RIGHT)
		return "right";
	if(sdl_button == SDL_BUTTON_X1)
		return "x1";
	if(sdl_button == SDL_BUTTON_X2)
		return "x2";
	return itos(sdl_button);
}

ss_ dump_command(const Command &c)
{
	switch(c.type){
	case Type::Delay:
		return "delay "+itos(c.n);
	case Type::Screenshot:
		return "screenshot "+c.s;
	case Type::KeyDown:
		return "keydown "+c.s;
	case Type::KeyUp:
		return "keyup "+c.s;
	case Type::KeyPress:
		return "keypress "+c.s;
	case Type::MousePos:
		return "mouse_pos "+itos(c.x)+" "+itos(c.y);
	case Type::MouseMove:
		return "mouse_move "+itos(c.x)+" "+itos(c.y);
	case Type::MouseDown:
		return "mouse_down "+button_name(c.x);
	case Type::MouseUp:
		return "mouse_up "+button_name(c.x);
	case Type::MouseClick:
		return "mouse_click "+button_name(c.x);
	case Type::MouseWheel:
		return "mouse_wheel "+itos(c.n);
	case Type::Text:
		return "text "+c.s;
	case Type::Quit:
		return "quit";
	}
	return "?";
}

static const char *key_alias(const ss_ &name)
{
	ss_ t;
	t.reserve(name.size());
	for(char c : name)
		t.push_back((char)tolower((unsigned char)c));
	if(t == "enter")
		return "Return";
	if(t == "esc")
		return "Escape";
	if(t == "ctrl")
		return "Left Ctrl";
	if(t == "shift")
		return "Left Shift";
	if(t == "alt")
		return "Left Alt";
	if(t == "super" || t == "gui" || t == "win")
		return "Left GUI";
	return nullptr;
}

static int key_from_name(magic::Input *input, const ss_ &name)
{
	int key = input->GetKeyFromName(name.c_str());
	if(key != 0)
		return key;
	const char *alias = key_alias(name);
	if(alias)
		key = input->GetKeyFromName(alias);
	return key;
}

static Uint32 window_id(magic::Input *input)
{
	magic::Graphics *g = input->GetSubsystem<magic::Graphics>();
	SDL_Window *w = g ? g->GetWindow() : nullptr;
	return w ? SDL_GetWindowID(w) : 0;
}

// Marks the mouse events this file pushes, so that the event filter can tell
// them apart from whatever the real mouse is doing. Urho3D does not read the
// "which" field of mouse events, so it is free for this.
static const Uint32 INJECTED_MOUSE_ID = 0x42554944; // "BUID"

static SDL_EventFilter g_prev_filter = nullptr;
static void *g_prev_filter_userdata = nullptr;
static bool g_input_inhibited = false;
// SDL_PushEvent runs the event filter in the pushing thread, before it returns,
// so a flag held across a push is enough to tell our own events apart from
// whatever the real keyboard is doing. Keyboard events have no free field to
// mark the way mouse events do.
static bool g_injecting_keys = false;

// Left through even while a sequence runs: escape, so that a run can be
// abandoned, and alt+tab, so that the window can be left if it grabbed the
// real mouse.
static bool always_allowed_key(SDL_Keycode sym)
{
	return sym == SDLK_ESCAPE || sym == SDLK_TAB ||
			sym == SDLK_LALT || sym == SDLK_RALT;
}

static int SDLCALL input_inhibit_filter(void *userdata, SDL_Event *e)
{
	Uint32 which = 0;
	switch(e->type){
	case SDL_KEYDOWN:
	case SDL_KEYUP:
		if(!g_injecting_keys && !always_allowed_key(e->key.keysym.sym))
			return 0; // The real keyboard; the sequence owns input
		if(g_prev_filter)
			return g_prev_filter(g_prev_filter_userdata, e);
		return 1;
	case SDL_TEXTINPUT:
	case SDL_TEXTEDITING:
		if(!g_injecting_keys)
			return 0;
		if(g_prev_filter)
			return g_prev_filter(g_prev_filter_userdata, e);
		return 1;
	case SDL_MOUSEMOTION: which = e->motion.which; break;
	case SDL_MOUSEBUTTONDOWN:
	case SDL_MOUSEBUTTONUP: which = e->button.which; break;
	case SDL_MOUSEWHEEL: which = e->wheel.which; break;
	default:
		// Not an input event; leave it to whoever was filtering before us
		if(g_prev_filter)
			return g_prev_filter(g_prev_filter_userdata, e);
		return 1;
	}
	if(which != INJECTED_MOUSE_ID)
		return 0; // A real mouse moved or clicked; the sequence owns input
	if(g_prev_filter)
		return g_prev_filter(g_prev_filter_userdata, e);
	return 1;
}

// The window is not grabbed during a sequence, so the physical mouse sits on
// the same display and its motion would otherwise land in GetMouseMove along
// with the injected motion, which makes a run unreproducible. The keyboard is
// worse than that: the window raises itself, so typing meant for another
// window lands in the client and perturbs the run in both places.
void inhibit_real_input(bool enable)
{
	if(enable == g_input_inhibited)
		return;
	if(enable){
		SDL_GetEventFilter(&g_prev_filter, &g_prev_filter_userdata);
		SDL_SetEventFilter(input_inhibit_filter, nullptr);
	} else {
		SDL_SetEventFilter(g_prev_filter, g_prev_filter_userdata);
		g_prev_filter = nullptr;
		g_prev_filter_userdata = nullptr;
	}
	g_input_inhibited = enable;
}

// Urho3D calls SuppressNextMouseMove() whenever mouse visibility, mode or
// grab actually changes, which makes it drop the next mouse motion it sees --
// including an injected one, so a mouse_move issued after the game toggled the
// mouse would silently do nothing. Feed it one pixel of motion to swallow
// instead. It is dropped by definition, so it moves nothing.
void absorb_mouse_move_suppression(magic::Input *input)
{
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = SDL_MOUSEMOTION;
	e.motion.windowID = window_id(input);
	e.motion.which = INJECTED_MOUSE_ID;
	e.motion.xrel = 1;
	e.motion.yrel = 0;
	SDL_PushEvent(&e);
}

// The window has to be mapped for the GL context to render what a screenshot
// reads, but it is deliberately not raised and not given input focus: a
// sequence can then run beside whatever the user is doing without the window
// jumping in front of it at every injected key. Urho3D drops key and mouse
// events while it has no focus, so the sequence forces the focus flag
// instead; see Input::SetForceInputFocus.
void show_window(magic::Graphics *graphics, magic::Input *input)
{
	if(graphics){
		SDL_Window *w = graphics->GetWindow();
		if(w)
			SDL_ShowWindow(w);
	}
	if(input)
		input->SetForceInputFocus(true);
}

void release_forced_focus(magic::Input *input)
{
	if(input)
		input->SetForceInputFocus(false);
}

static bool push_key(magic::Input *input, int key, bool down, ss_ *error)
{
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
	e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
	e.key.repeat = 0;
	e.key.windowID = window_id(input);
	e.key.keysym.sym = key;
	e.key.keysym.scancode = SDL_GetScancodeFromKey((SDL_Keycode)key);
	g_injecting_keys = true;
	int r = SDL_PushEvent(&e);
	g_injecting_keys = false;
	if(r != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

bool inject_key(magic::Input *input, const ss_ &name, bool down, bool up_too,
		ss_ *error)
{
	int key = key_from_name(input, name);
	if(key == 0){
		*error = "Unknown key \""+name+"\"";
		return false;
	}
	if(!push_key(input, key, down, error))
		return false;
	if(up_too && !push_key(input, key, false, error))
		return false;
	return true;
}

static bool push_mouse_button(magic::Input *input, int sdl_button, bool down,
		ss_ *error)
{
	magic::IntVector2 p = input->GetMousePosition();
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
	e.button.windowID = window_id(input);
	e.button.button = (Uint8)sdl_button;
	e.button.state = down ? SDL_PRESSED : SDL_RELEASED;
	e.button.clicks = 1;
	e.button.which = INJECTED_MOUSE_ID;
	e.button.x = p.x_;
	e.button.y = p.y_;
	if(SDL_PushEvent(&e) != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

bool inject_mouse_button(magic::Input *input, int sdl_button, bool down,
		bool up_too, ss_ *error)
{
	if(!push_mouse_button(input, sdl_button, down, error))
		return false;
	if(up_too && !push_mouse_button(input, sdl_button, false, error))
		return false;
	return true;
}

bool inject_mouse_pos(magic::Input *input, int x, int y, ss_ *error)
{
	magic::IntVector2 old = input->GetMousePosition();
	input->SetMousePosition(magic::IntVector2(x, y));
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = SDL_MOUSEMOTION;
	e.motion.windowID = window_id(input);
	e.motion.which = INJECTED_MOUSE_ID;
	e.motion.x = x;
	e.motion.y = y;
	e.motion.xrel = x - old.x_;
	e.motion.yrel = y - old.y_;
	if(SDL_PushEvent(&e) != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

bool inject_mouse_move(magic::Input *input, int dx, int dy, ss_ *error)
{
	// Relative only. No warp: captured look has no persistent cursor position.
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = SDL_MOUSEMOTION;
	e.motion.windowID = window_id(input);
	e.motion.which = INJECTED_MOUSE_ID;
	e.motion.xrel = dx;
	e.motion.yrel = dy;
	if(SDL_PushEvent(&e) != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

bool inject_mouse_wheel(magic::Input *input, int delta, ss_ *error)
{
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = SDL_MOUSEWHEEL;
	e.wheel.windowID = window_id(input);
	e.wheel.which = INJECTED_MOUSE_ID;
	e.wheel.y = delta;
	if(SDL_PushEvent(&e) != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

bool inject_text(magic::Input *input, const ss_ &text, ss_ *error)
{
	size_t i = 0;
	while(i < text.size()){
		SDL_Event e;
		memset(&e, 0, sizeof(e));
		e.type = SDL_TEXTINPUT;
		e.text.windowID = window_id(input);
		size_t n = text.size() - i;
		if(n > sizeof(e.text.text) - 1)
			n = sizeof(e.text.text) - 1;
		memcpy(e.text.text, text.c_str() + i, n);
		e.text.text[n] = 0;
		g_injecting_keys = true;
		int r = SDL_PushEvent(&e);
		g_injecting_keys = false;
		if(r != 1){
			*error = "SDL_PushEvent failed";
			return false;
		}
		i += n;
	}
	return true;
}

bool save_screenshot(magic::Graphics *graphics, const ss_ &path, ss_ *error)
{
	if(!graphics){
		*error = "Graphics not available";
		return false;
	}
	magic::Image img(graphics->GetContext());
	if(!graphics->TakeScreenShot(img)){
		*error = "TakeScreenShot failed";
		return false;
	}
	ss_ abs = interface::fs::get_absolute_path(path);
	ss_ parent = interface::fs::strip_file_name(abs);
	if(!parent.empty() && !interface::fs::create_directories(parent)){
		*error = "Failed to create directory \""+parent+"\"";
		return false;
	}
	magic::FileSystem *fs = graphics->GetSubsystem<magic::FileSystem>();
	if(fs && !parent.empty())
		fs->RegisterPath(parent.c_str());
	if(!img.SavePNG(abs.c_str())){
		*error = "Failed to write \""+abs+"\"";
		return false;
	}
	log_i(MODULE, "Wrote screenshot %s", cs(abs));
	return true;
}

}
}
// vim: set noet ts=4 sw=4:
