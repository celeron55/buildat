# SPDX-License-Identifier: Apache-2.0 OR MIT
# Sourced by the runners that toggle F11.
#
# **F11 takes the whole screen and the keyboard focus of whatever X
# session the run is on, which on this desk is the user's own** (user,
# 2026-09-22: "Could you please not fullscreen the thing. I'm trying to
# use this Xorg session"). So a fullscreen toggle is off unless it is
# asked for, and asking for it means having somewhere to put it:
#
#   FULLSCREEN=1 builtin/luanti/test/viewkeys.sh        # takes this screen
#   DISPLAY=:2 FULLSCREEN=1 builtin/luanti/test/...     # a server of its own
#
# A nested server is the right home for it (Xephyr :2 -screen 1280x720,
# or a second Xorg on another VT); neither Xephyr nor Xvfb is installed
# here, which is why the default is to skip rather than to nest.
#
# What the fault being checked ([BOX_PLAYTEST_3] (1), the black world
# across a screen mode change) needs is the Windows box in any case: it
# has never reproduced on this desk, so skipping the toggle here costs
# the run nothing it was going to find.
fullscreen_wanted()
{
	[ -n "${FULLSCREEN:-}" ]
}

# Prints the F11 lines for a client command file, or nothing
fullscreen_toggle()
{
	if fullscreen_wanted; then
		echo "keypress F11"
		echo "delay ${1:-4000}"
	fi
}

# The whole fullscreen half of a command file: two toggles and a picture
# after each, into the directory named. Nothing at all when it is not
# asked for, so the checks that read those pictures skip themselves.
fullscreen_section()
{
	fullscreen_wanted || return 0
	echo "keypress F11"
	echo "delay 4000"
	echo "screenshot $1/fullscreen.png"
	echo "keypress F11"
	echo "delay 4000"
	echo "screenshot $1/after_f11.png"
}
