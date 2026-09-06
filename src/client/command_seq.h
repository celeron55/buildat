// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace Urho3D {
	class Graphics;
	class Input;
}

namespace client
{
namespace command_seq
{
	enum class Type
	{
		Delay,
		Screenshot,
		KeyDown,
		KeyUp,
		KeyPress,
		MousePos,
		MouseMove,
		MouseDown,
		MouseUp,
		MouseClick,
		MouseWheel,
		Text,
		Quit,
	};

	struct Command
	{
		Type type;
		int64_t n = 0;
		int x = 0;
		int y = 0;
		ss_ s;
	};

	// One command per line. Empty lines and '#' comments are ignored.
	bool parse(const ss_ &text, sv_<Command> *out, ss_ *error);

	ss_ dump_command(const Command &c);

	// Drop real mouse and keyboard events while a sequence runs, so that
	// neither can perturb it and so that typing aimed at another window is
	// not swallowed by the client raising itself. Injected events still get
	// through, as do escape and alt+tab.
	void inhibit_real_input(bool enable);

	// Feed Urho3D the one mouse motion it drops after a mouse state change,
	// so that the next injected mouse_move is not the one that gets eaten.
	void absorb_mouse_move_suppression(Urho3D::Input *input);

	void raise_window(Urho3D::Graphics *graphics);
	bool inject_key(Urho3D::Input *input, const ss_ &name, bool down,
			bool up_too, ss_ *error);
	bool inject_mouse_button(Urho3D::Input *input, int sdl_button, bool down,
			bool up_too, ss_ *error);
	bool inject_mouse_pos(Urho3D::Input *input, int x, int y, ss_ *error);
	bool inject_mouse_move(Urho3D::Input *input, int dx, int dy, ss_ *error);
	bool inject_mouse_wheel(Urho3D::Input *input, int delta, ss_ *error);
	bool inject_text(Urho3D::Input *input, const ss_ &text, ss_ *error);
	bool save_screenshot(Urho3D::Graphics *graphics, const ss_ &path,
			ss_ *error);
}
}
// vim: set noet ts=4 sw=4:
