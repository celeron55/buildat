# SPDX-License-Identifier: Apache-2.0 OR MIT
"""[NEW_WORLD_FORM]: the new-world screen driven -- a name already taken
leaves it standing with what was typed, a seed pasted with Ctrl+V lands in
the name field, and the mapgen picked is the one written into world.mt."""
import os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import menu_drive
from menu_drive import Screen, click, type_into

log, fifo, saves = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
def say(s):
    print(s, flush=True)
def read_block(label):
    global seen
    t0 = time.time()
    while time.time() - t0 < 60:
        buf = open(log, "rb").read()
        m = re.search((r"scan %s: done, \d+ lines" % label).encode(), buf[seen:])
        if m:
            data = buf[seen:seen + m.end()].decode("utf-8", "replace")
            seen += m.end()
            pre = "scan %s: " % label
            out = []
            for line in data.splitlines():
                i = line.find(pre)
                if i >= 0:
                    out.append(line[i + len(pre):])
            return out
        time.sleep(0.3)
    return None

GAME = "mineclone2"
phase = 0
notes = {}
n = 0
t0 = time.time()
while time.time() - t0 < 600:
    n += 1
    label = "n%d" % n
    write("event scan 8 %s" % label)
    lines = read_block(label)
    if lines is None:
        say("FAIL: no scan block (phase %d)" % phase); write("quit"); sys.exit(1)
    s = Screen(lines)
    name = s.name or ""
    if phase >= 3:
        break
    if name.endswith("boot") or name.endswith("local_game"):
        e = s.find(menu_drive.TITLES.get(GAME, GAME), "Text")
        if e: click(write, e)
    elif "vanilla menu: saves" in name:
        e = s.find("New world", "Text") or s.find("New save", "Text")
        if e: click(write, e)
    elif "which game?" in name:
        e = s.find(GAME, "Text")
        if e:
            click(write, e)
        elif s.edits():
            type_into(write, s.edits()[0], GAME)
            write("keypress Return", "delay 300")
    elif "New save, playing" in name:
        edits = s.edits()
        if len(edits) < 2:
            say("FAIL: the name screen has %d fields" % len(edits))
            write("quit"); sys.exit(1)
        if phase == 0:
            # A name that is already taken, and a seed beside it
            type_into(write, edits[0], "taken")
            type_into(write, edits[1], "2845188330406634615")
            e = s.find("Create and play", "Text")
            click(write, e)
            phase = 1
            write("delay 2500")
        elif phase == 1:
            # The screen has to be this one still, with an error line on
            # it and both fields as they were
            err = [e[5] for e in s.ui if e[0] == "Text" and
                   "already a save" in e[5]]
            notes["error"] = err[0] if err else ""
            notes["name"] = edits[0][5]
            notes["seed"] = edits[1][5]
            say('after the refused create: error %r, name %r, seed %r' % (
                notes["error"], notes["name"], notes["seed"]))
            # The seed selected and copied, then pasted into the name: the
            # fields do Ctrl+C and Ctrl+V themselves once they are told to
            click(write, edits[1])
            write("keypress End", "keydown Left Shift", "keypress Home",
                  "keyup Left Shift", "delay 200",
                  "keydown Left Ctrl", "keypress C", "keyup Left Ctrl",
                  "delay 200")
            click(write, edits[0])
            write("keypress End", *(["keypress Backspace"] * 40))
            write("keydown Left Ctrl", "keypress V", "keyup Left Ctrl",
                  "delay 400")
            phase = 2
        elif phase == 2:
            notes["pasted"] = edits[0][5]
            say("Ctrl+V put %r in the name field" % notes["pasted"])
            type_into(write, edits[0], "mgtest")
            e = s.find("mapgen valleys", "Text")
            if e is None:
                say("FAIL: no mapgen row on the screen")
                write("quit"); sys.exit(1)
            click(write, e)
            write("delay 300")
            e = s.find("Create and play", "Text")
            click(write, e)
            phase = 3
            break
    elif name.endswith("show_message_dialog"):
        said = " ".join(e[5] for e in s.ui if e[0] == "Text" and e[5] not in ("", "Ok"))
        say("FAIL: a dialog took the screen away: %s" % said)
        write("quit"); sys.exit(1)
    write("delay 1200")

# The world is being made; world.mt is written before it is loaded
mt = os.path.join(saves, "mgtest", "luanti", "world.mt")
for _ in range(120):
    if os.path.exists(mt):
        break
    time.sleep(1)
write("delay 500", "quit")
text = open(mt).read() if os.path.exists(mt) else ""
mg = re.search(r"^mg_name\s*=\s*(\S+)", text, re.M)
say("world.mt says mg_name = %s" % (mg.group(1) if mg else "nothing"))
ok = (notes.get("error") and notes.get("name") == "taken" and
      notes.get("seed") == "2845188330406634615" and
      notes.get("pasted") == "2845188330406634615" and
      mg and mg.group(1) == "valleys")
say("PASS: the screen stood, the paste landed and the mapgen was written"
    if ok else "FAIL: %r" % notes)
sys.exit(0 if ok else 1)
