# SPDX-License-Identifier: Apache-2.0 OR MIT
"""The driver's menu rules ([FIRST_RUN]): from the launch menu to a world
through buildat's own screens, by scan, find-by-text, click and type.

drive.py calls run() before its world rules when the client was started
with no server (MENU_RUN=world in drive.sh). Each screen is known by the
name the scan gives (`menu "<stack element>: <desc>"`), and the rule for
it is one click or one field; a screen that does not change inside its
timeout, or a screen nobody has a rule for, is the failure line.

Two modes (user, 2026-09-21): "world" -- the game is installed and the
run makes a new world in it; "full" -- empty user and cache directories
and ContentDB installs the game first. simplified: full's ContentDB
screens (find VoxeLibre, install, wait for the download) are the next
rung; until then full runs as world.
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "util"))
import uidrive  # noqa: E402

UI_RE = uidrive.UI_RE

SCREEN_TIMEOUT_S = 90
# A wait -- a compile of every module on empty paths, a download -- may
# take longer, and the still-pair check is what watches it move
WAIT_TIMEOUT_S = 600
# The rule held through the run ([FIRST_RUN]): a shot every this many
# seconds, and each must differ from the last unless the screen is
# waiting for input
STILL_EVERY_S = 4.0
# The grid's titles for the game ids the rules name
TITLES = {"mineclone2": "VoxeLibre", "minetest_game": "Minetest Game"}
SETTLE_S = 1.2


class Screen:
    def __init__(self, lines):
        self.name = None
        self.ui = []        # (kind, x, y, w, h, text)
        self.focus = None   # (kind, x, y, w, h, text)
        self.world = False
        for line in lines:
            m = re.match(r'menu "(.*)"$', line)
            if m:
                self.name = m.group(1)
                continue
            if line.startswith("self at "):
                self.world = True
                continue
            m = UI_RE.match(line)
            if m and m.group(8) is None:
                self.ui.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)), m.group(6) or ""))
                continue
            m = re.match(r"focus (\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+) text \"(.*)\"$", line)
            if m:
                self.focus = (m.group(1), int(m.group(2)), int(m.group(3)),
                              int(m.group(4)), int(m.group(5)), m.group(6))

    def find(self, word, kind=None):
        """The first element whose text contains word (case-insensitive)."""
        w = word.lower()
        for e in self.ui:
            if kind and e[0] != kind:
                continue
            if w in e[5].lower() and e[3] > 0 and e[4] > 0:
                return e
        return None

    def edits(self):
        return [e for e in self.ui if e[0] == "LineEdit" and e[3] > 0]

    def waits_for_input(self):
        """A field to fill or a button to press is on the screen: it may
        sit still. A wait -- a compile, a download, a connect -- has
        neither and must move."""
        if self.focus is not None and self.focus[0] == "LineEdit":
            return True
        return any(e[0] in ("Button", "LineEdit") and e[3] > 0 for e in self.ui)


# What in a log is a failure the user would have seen or felt, checked
# after every scan over the client's log and the local server's (user,
# 2026-09-21): an error line from any module (the log's own level column,
# " E " after the timestamp, so a mod's chatter at info does not count),
# a crash, a disconnect not asked for. The words are for what the level
# misses.
LOG_BAD = re.compile(
    rb"^\S+ \d+ [\d:.]+ E |Unhandled page fault|Segmentation fault|"
    rb"Disconnected from server|the server closed the connection|"
    rb"Command sequence failed|Build failed|error in |traceback", re.I)
# Lines the pattern would take and should not
LOG_OK = re.compile(rb"error_icon|error_screenshot|is a stub")


class LogWatch:
    """Tails the client's log and, once it names one, the local
    server's; the first bad line ends the run."""
    def __init__(self, cli_log, say):
        self.say = say
        self.logs = {cli_log: 0}   # path -> bytes read

    def check(self):
        for path in list(self.logs):
            try:
                with open(path, "rb") as f:
                    f.seek(self.logs[path])
                    data = f.read()
            except OSError:
                continue
            self.logs[path] += len(data)
            for line in data.splitlines():
                m = re.search(rb"server log: (\S+)", line)
                if m and m.group(1).decode() not in self.logs:
                    self.logs[m.group(1).decode()] = 0
                if LOG_BAD.search(line) and not LOG_OK.search(line):
                    self.say("FAILED log: %s: %s" % (
                        os.path.basename(path), line.decode("utf-8", "replace").strip()[:200]))
                    return False
        return True


class Still:
    """The still-pair check: shots STILL_EVERY_S apart into out/, each
    compared with the last as bytes (the same pixels give the same
    file)."""
    def __init__(self, write, say, out):
        self.write, self.say, self.out = write, say, out
        self.n = 0
        self.last = None       # (path, screen name, time)
        self.pending = None    # a shot asked for, read on the next check
        self.t_shot = 0.0
        self.t_change = time.time()

    def check(self, screen):
        """Called once per scan; returns False when a still pair failed."""
        now = time.time()
        if self.pending is not None:
            path, name, t = self.pending
            self.pending = None
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                data = None
            if data is not None:
                same = self.last is not None and self.last[0] == data
                self.say("still %d at %.0f s on %s: %s%s" % (
                    self.n, t - self.t_change, name, "same" if same else "changed",
                    " (waiting for input)" if same and screen.waits_for_input() else ""))
                if same:
                    if not screen.waits_for_input():
                        self.say("FAILED still: the screen %s did not change between %.0f s and %.0f s"
                                 % (name, self.last[2] - self.t_change, t - self.t_change))
                        return False
                else:
                    self.t_change = t
                self.last = (data, name, t)
        if self.out and now - self.t_shot >= STILL_EVERY_S:
            self.n += 1
            path = os.path.join(self.out, "still%d.png" % self.n)
            self.write("screenshot %s" % path)
            self.pending = (path, screen.name, now)
            self.t_shot = now
        return True


def centre(e):
    return e[1] + e[3] // 2, e[2] + e[4] // 2


def click(write, e):
    x, y = centre(e)
    write("mouse_pos %d %d" % (x, y), "delay 150", "mouse_click left", "delay 150")


def type_into(write, e, text):
    click(write, e)
    # What the field held goes first; the fields here are short
    write(*(["keypress End"] + ["keypress Backspace"] * 40))
    if text:
        write("text " + text)
    write("delay 150")


def run(write, read_block, say, seed, game="mineclone2", save_name="menu_run", mode="world", out=None, cli_log=None):
    """Drive from wherever the client is to a world; True when the world's
    scan answers, False with a FAILED line said otherwise."""
    t_screen = time.time()
    last_name = None
    n = 0
    still = Still(write, say, out)
    watch = LogWatch(cli_log, say) if cli_log else None
    searched = False
    installed = False
    while True:
        n += 1
        label = "m%d" % n
        write("event scan 8 %s" % label)
        lines, took = read_block(label)
        if watch and not watch.check():
            return False
        if lines is None:
            say("FAILED menu: no scan block on screen %s" % last_name)
            return False
        s = Screen(lines)
        if not still.check(s):
            return False
        if s.world:
            over = [l for l in lines if l.startswith("menu screen ")]
            if over:
                say("FAILED menu: %s" % over[0])
                return False
            say("menu: the world answered after %d screens" % n)
            return True
        if s.name != last_name:
            say("menu: screen %s" % (s.name or "?"))
            last_name = s.name
            t_screen = time.time()
        name = s.name or ""
        waiting = name.endswith("starting_local_server") or name.endswith("waiting") \
            or name.endswith("stopping_old_server") or "game is running" in name
        limit = WAIT_TIMEOUT_S if waiting else SCREEN_TIMEOUT_S
        if s.name == last_name and time.time() - t_screen > limit:
            say("FAILED menu: screen %s did not change in %d s" % (s.name, limit))
            return False
        acted = False
        if name.endswith("boot") or name.endswith("local_game"):
            # The launcher's grid ([LAUNCH_GRID]): a tile per Luanti game
            # by its title, or ContentDB's when the game is not there yet
            e = s.find(TITLES.get(game, game), "Text")
            if e is None:
                e = s.find("ContentDB", "Text")
            if e is None:
                say("FAILED menu: neither %s nor ContentDB on the grid" % game)
                return False
            click(write, e)
            acted = True
        elif waiting:
            pass  # the still-pair check is what watches it
        elif "vanilla menu: ContentDB" in name:
            # The game's Install row, or the search for it first; once
            # installed, back to the saves list, whose rules make the world
            # The game's row: its title text, and the Install button on
            # the same line ([CONTENTDB_LIST])
            e = s.find(TITLES.get(game, game), "Text")
            if e is not None:
                same_row = [b for b in s.ui if b[0] == "Text" and b[5] == "Install"
                            and abs(b[2] - e[2]) < 60 and b[3] > 0]
                e = same_row[0] if same_row else None
            if installed:
                e = s.find("< back", "Text")
                if e:
                    click(write, e)
                    acted = True
            elif e:
                click(write, e)
                installed = True
                acted = True
            elif s.edits() and not searched:
                type_into(write, s.edits()[0], TITLES.get(game, game))
                e = s.find("Search", "Text")
                if e:
                    click(write, e)
                searched = True
                acted = True
            else:
                say("FAILED menu: %s is not in ContentDB's list" % game)
                return False
        elif name.endswith("show_message_dialog"):
            # A dialog is the run's failure line, whatever it says (user,
            # 2026-09-21): the first run has no step that asks a question,
            # so a dialog is an error or a failure the user saw, and
            # pressing Ok and trying again is not a pass
            said = " ".join(e[5] for e in s.ui if e[0] == "Text" and e[5] not in ("", "Ok"))
            say("FAILED menu: a dialog: %s" % said)
            return False
        elif "vanilla menu: saves" in name:
            # "New world..." when a game's tile opened the list, "New
            # save..." from the plain menu
            e = s.find("New world", "Text") or s.find("New save", "Text")
            if e:
                click(write, e)
                acted = True
        elif "which game?" in name:
            e = s.find(game, "Text")
            if e:
                click(write, e)
                acted = True
            elif s.edits() and s.focus is not None and s.focus[5] != game:
                # A long list is paged; its filter field narrows it
                type_into(write, s.edits()[0], game)
                write("keypress Return", "delay 300")
                acted = True
            else:
                say("FAILED menu: the game %s is not in the list" % game)
                return False
        elif "New save, playing" in name:
            edits = s.edits()
            if len(edits) >= 2:
                type_into(write, edits[0], save_name)
                type_into(write, edits[1], str(seed))
                e = s.find("Create and play", "Text")
                if e:
                    click(write, e)
                    acted = True
        else:
            say("FAILED menu: no rule for screen %s" % name)
            return False
        write("delay %d" % int(SETTLE_S * 1000))
        if acted:
            t_screen = time.time()
