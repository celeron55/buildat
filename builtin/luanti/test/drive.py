#!/usr/bin/env python3
# Buildat: builtin/luanti/test/drive.py
# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#
# [SCAN_DRIVE]: the player commanded from what the scan shows. A loop of
# scan, read, act: `event scan` is written to the client's stdin (a fifo
# drive.sh holds), the block it logs is read off cli.log, the first rule
# whose condition holds writes its commands, and the rule's expectation
# is asserted on the next scan. The rules are the playtest's intent and
# are listed in doc/plan/luanti_module_plan.md under [SCAN_DRIVE]; the
# invariants are the fixture's (fuzz.lua), which runs on the server the
# same as under fuzz.sh.
#
#   drive.py <cli.log> <fifo> <minutes> <out dir> [seed]
#
# Python 3, nothing else. Every turn's rule and every failed expectation
# is a `drive:` line on stdout, which drive.sh keeps beside the logs.
import math
import os
import random
import re
import sys
import time

RES = 8
SCAN_TIMEOUT_S = 10.0
# What a turn spends acting, in seconds, before the next scan
TURN_S = 1.5
# The fixture's own fuzz walk shoots every thirty seconds; every tenth
# turn here is about that
SHOT_EVERY = 10

log = None
fifo = None
out = None
rng = random.Random()
turn = 0
seen = 0        # bytes of the log read so far


def say(s):
    print("drive: " + s, flush=True)


def write(*cmds):
    for c in cmds:
        fifo.write(c + "\n")
    fifo.flush()


def read_block(label):
    """Read cli.log until `scan <label>: done`; the block's lines without
    the label prefix, or None on timeout."""
    global seen
    t0 = time.time()
    buf = ""
    while time.time() - t0 < SCAN_TIMEOUT_S:
        with open(log, "rb") as f:
            f.seek(seen)
            data = f.read()
        if data:
            seen += len(data)
            buf += data.decode("utf-8", "replace")
            m = re.search(r"scan %s: done, \d+ lines" % re.escape(label), buf)
            if m:
                lines = []
                pre = "scan %s: " % label
                for line in buf[:m.end()].splitlines():
                    i = line.find(pre)
                    if i >= 0:
                        lines.append(line[i + len(pre):])
                return lines, time.time() - t0
        time.sleep(0.05)
    return None, time.time() - t0


class State:
    def __init__(self):
        self.pos = None
        self.yaw = self.pitch = self.fov = 0.0
        self.hp = None
        self.wield = ""
        self.hotbar = []     # (index, stack string)
        self.crosshair = None    # (name, x, y, z) or None
        self.bins = {}       # (bx, by) -> dict(kind, name, d, x, y, z, via)
        self.form = None     # formname or None
        self.ui = []         # (kind, x, y, w, h, text, image)
        self.bars = {}       # texture -> (number, total)
        self.chat = None


BIN_RE = re.compile(
    r"bin (\d+),(\d+): (object \S+ |)(\S+)(?: at (-?\d+),(-?\d+),(-?\d+))?"
    r"(?: d=([\d.]+))?(?: via (\S+))?$")
UI_RE = re.compile(
    r"ui\s+(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(?: text \"(.*?)\")?"
    r"(?: image \"(.*?)\")?")


def parse(lines):
    s = State()
    for line in lines:
        m = re.match(r"self at (-?[\d.]+),(-?[\d.]+),(-?[\d.]+) yaw (-?[\d.]+) "
                     r"pitch (-?[\d.]+) fov ([\d.]+) hp (\S+) wield \"(.*?)\""
                     r"(?: hotbar (.*))?$", line)
        if m:
            s.pos = tuple(float(m.group(i)) for i in (1, 2, 3))
            s.yaw, s.pitch, s.fov = (float(m.group(i)) for i in (4, 5, 6))
            s.hp = None if m.group(7) == "?" else float(m.group(7))
            s.wield = m.group(8)
            if m.group(9):
                for part in m.group(9).split(" | "):
                    i, _, stack = part.partition(":")
                    if i.isdigit():
                        s.hotbar.append((int(i), stack))
            continue
        m = re.match(r"crosshair (\S+) at (-?\d+),(-?\d+),(-?\d+)", line)
        if m:
            s.crosshair = (m.group(1),) + tuple(int(m.group(i)) for i in (2, 3, 4))
            continue
        m = BIN_RE.match(line)
        if m:
            b = {"kind": "object" if m.group(3) else "node",
                 "name": m.group(4), "d": float(m.group(8) or 0),
                 "via": (m.group(9) or "").split(",") if m.group(9) else []}
            if m.group(3):
                b["id"] = m.group(3).split()[1]
            if m.group(5):
                b["at"] = tuple(int(m.group(i)) for i in (5, 6, 7))
            s.bins[(int(m.group(1)), int(m.group(2)))] = b
            continue
        m = re.match(r"form \"(.*)\" open", line)
        if m:
            s.form = m.group(1)
            continue
        m = UI_RE.match(line)
        if m:
            s.ui.append((m.group(1), int(m.group(2)), int(m.group(3)),
                         int(m.group(4)), int(m.group(5)), m.group(6),
                         m.group(7)))
            continue
        m = re.match(r"hud statbar \"(.*?)\" (-?[\d.]+)/(-?[\d.]+)", line)
        if m:
            s.bars[m.group(1)] = (float(m.group(2)), float(m.group(3)))
            continue
        m = re.match(r"chat line open, text \"(.*)\"", line)
        if m:
            s.chat = m.group(1)
    if s.hp is None:
        for tex, (n, total) in s.bars.items():
            if "heart" in tex or "health" in tex:
                s.hp = n
    return s


def bin_dir(s, bx, by):
    """The world direction of a bin's centre ray, scan.lua's arithmetic."""
    yr, pr = math.radians(s.yaw), math.radians(s.pitch)
    fwd = (math.sin(yr) * math.cos(pr), -math.sin(pr), math.cos(yr) * math.cos(pr))
    right = (math.cos(yr), 0.0, -math.sin(yr))
    up = (math.sin(yr) * math.sin(pr), math.cos(pr), math.cos(yr) * math.sin(pr))
    tan_v = math.tan(math.radians(s.fov) / 2)
    aspect = 1280 / 720
    sx = ((bx + 0.5) / RES * 2 - 1) * tan_v * aspect
    sy = (1 - (by + 0.5) / RES * 2) * tan_v
    return tuple(fwd[i] + right[i] * sx + up[i] * sy for i in range(3))


def look_at_bin(s, bx, by, level=True):
    d = bin_dir(s, bx, by)
    if level:
        d = (d[0], 0.0, d[2])
    return "look_dir %.3f %.3f %.3f" % d


def look_away(s):
    yaw = s.yaw + rng.uniform(90, 180) * rng.choice((-1, 1))
    yr = math.radians(yaw)
    return "look_dir %.3f 0 %.3f" % (math.sin(yr), math.cos(yr))


def ms(seconds):
    return "delay %d" % int(seconds * 1000)


def walk(seconds, jump=False):
    cmds = ["keydown W"]
    if jump:
        cmds += ["keydown Space", "delay 150", "keyup Space"]
        seconds -= 0.15
    cmds += [ms(max(0.1, seconds)), "keyup W"]
    return cmds


def is_tree(name):
    return "tree" in name or "log" in name


# The rules, in priority order. Each is (name, condition, act) where act
# returns the commands and an expectation: a function of the next state
# that says whether what the rule wanted happened, or None.
def rules(s, mem):
    # form open: the death screen's Respawn, the pause menu's Escape, any
    # other form's Escape
    if s.form is not None:
        btn = [u for u in s.ui if u[0] == "Button" and u[5] and
               u[5].lower().startswith("respawn")]
        mem["form_turns"] = mem.get("form_turns", 0) + 1
        if mem["form_turns"] > 2:
            return "stuck_form", None, None
        if btn:
            _, x, y, w, h, _, _ = btn[0]
            cmds = ["mouse_pos %d %d" % (x + w // 2, y + h // 2),
                    "delay 100", "mouse_click left", ms(TURN_S)]
            return "respawn", cmds, lambda n: n.form is None
        return "close_form", ["keypress Escape", ms(TURN_S)], \
            lambda n: n.form is None
    mem["form_turns"] = 0
    if s.chat is not None:
        return "close_chat", ["keypress Escape", ms(TURN_S)], \
            lambda n: n.chat is None

    # stuck: no two nodes moved in five walking turns
    hist = mem.setdefault("pos", [])
    if s.pos:
        hist.append(s.pos)
        del hist[:-5]
    if len(hist) == 5 and mem.get("walking", 0) >= 5:
        dx = hist[-1][0] - hist[0][0]
        dz = hist[-1][2] - hist[0][2]
        if math.hypot(dx, dz) < 2:
            mem["stuck"] = mem.get("stuck", 0) + 1
            hist.clear()
            if mem["stuck"] >= 3:
                return "stuck_thrice", None, None
            return "unstick", [look_away(s)] + walk(TURN_S, jump=True), None
    else:
        mem["stuck"] = 0

    # falling or drowning: hp down and liquid below
    below = [b for (x, y), b in s.bins.items() if y >= RES - 2]
    liquid_below = any(b["kind"] == "node" and "water" in b["name"] for b in below)
    if s.hp is not None and mem.get("hp") is not None and s.hp < mem["hp"] \
            and liquid_below:
        ground = [(x, y) for (x, y), b in s.bins.items()
                  if b["kind"] == "node" and "water" not in b["name"] and
                  b["d"] < 10 and y >= RES // 2]
        if ground:
            bx, by = min(ground, key=lambda k: s.bins[k]["d"])
            return "out_of_water", [look_at_bin(s, bx, by)] + \
                walk(TURN_S, jump=True), None

    # hungry: a bar under half and food on the hotbar
    for tex, (n, total) in s.bars.items():
        if ("hunger" in tex or "bread" in tex or "food" in tex) and total > 0 \
                and n < total / 2:
            food = [(i, st) for i, st in s.hotbar if
                    any(w in st for w in ("bread", "apple", "food", "carrot", "potato"))]
            if food:
                i = food[0][0]
                cmds = ["keypress %d" % i, "delay 200", "mouse_down right",
                        "delay 2500", "mouse_up right", "delay 300"]
                return "eat", cmds, lambda nx, tex=tex, n=n: \
                    tex in nx.bars and nx.bars[tex][0] > n

    # a tree in view
    trees = [(x, y) for (x, y), b in s.bins.items()
             if b["kind"] == "node" and is_tree(b["name"]) and b["d"] <= 10]
    if s.crosshair and is_tree(s.crosshair[0]):
        cmds = ["mouse_down left", "delay 4000", "mouse_up left", "delay 300"]
        was = s.crosshair
        return "dig_tree", cmds, lambda n: n.crosshair != was
    if trees:
        bx, by = min(trees, key=lambda k: s.bins[k]["d"])
        d = s.bins[(bx, by)]["d"]
        cmds = [look_at_bin(s, bx, by, level=False)]
        if d > 3.5:
            cmds += walk(min(TURN_S, (d - 3) / 4))
        else:
            cmds += [ms(0.3)]
        return "to_tree", cmds, None

    # a mob in view: punch it once and back off
    mobs = [(x, y) for (x, y), b in s.bins.items() if b["kind"] == "object"]
    if mobs and mem.get("punched_turn", -99) < turn - 5:
        bx, by = min(mobs, key=lambda k: s.bins[k]["d"])
        mem["punched_turn"] = turn
        cmds = [look_at_bin(s, bx, by, level=False), "delay 200",
                "mouse_click left", "delay 200", "keydown S", ms(0.8), "keyup S"]
        return "punch", cmds, None

    # something to place: a placeable wielded and the crosshair on ground
    if s.crosshair and s.wield and ":" in s.wield and rng.random() < 0.1:
        placeable = not any(w in s.wield for w in ("axe", "pick", "sword", "shovel"))
        if placeable:
            return "place", ["mouse_click right", ms(0.5)], None

    # otherwise explore: toward the longest ray, away from a cliff or water
    horizon = [(x, y) for (x, y) in s.bins if y in (RES // 2, RES // 2 - 1)]
    floor = [b for (x, y), b in s.bins.items() if y == RES - 1]
    cliff = all(b["kind"] != "node" or "water" in b["name"] for b in floor) \
        if floor else False
    if cliff:
        mem["walking"] = 0
        return "turn_at_edge", [look_away(s), ms(0.3)], None

    def length(k):
        b = s.bins[k]
        return b["d"] if b["kind"] == "node" else 10.5
    bx, by = max(horizon, key=length) if horizon else (RES // 2, RES // 2)
    mem["walking"] = mem.get("walking", 0) + 1
    return "explore", [look_at_bin(s, bx, by)] + walk(TURN_S, jump=rng.random() < 0.3), None


def main():
    global log, fifo, out, turn
    log, fifo_path, minutes, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
    if len(sys.argv) > 5:
        rng.seed(int(sys.argv[5]))
    fifo = open(fifo_path, "w")
    mem = {}
    expect = None
    expect_name = None
    failed_in_row = 0
    end = time.time() + minutes * 60
    slow = 0
    # The client is up when its log names the window; the first scan can
    # then wait for the world
    while time.time() < end:
        turn += 1
        label = "d%d" % turn
        if turn % SHOT_EVERY == 1:
            write("screenshot %s/%s.png" % (out, label))
        write("event scan %d %s" % (RES, label))
        lines, took = read_block(label)
        if lines is None:
            say("turn %d: no scan block in %.1f s" % (turn, took))
            slow += 1
            if slow >= 3:
                say("FAILED scan: three turns without a scan block")
                break
            time.sleep(1)
            continue
        if took > 1.0:
            say("turn %d: the scan took %.2f s ([FRAME_PEAK])" % (turn, took))
        slow = 0
        s = parse(lines)
        if expect is not None:
            held = expect(s)
            if held:
                failed_in_row = 0
            else:
                failed_in_row += 1
                say("turn %d: %s's expectation did not hold (%d in a row)" %
                    (turn, expect_name, failed_in_row))
                if failed_in_row >= 2:
                    say("FAILED %s: its expectation failed twice in a row" % expect_name)
                    failed_in_row = 0
            expect = None
        if s.pos is None:
            say("turn %d: no self line; waiting" % turn)
            time.sleep(1)
            continue
        name, cmds, expect = rules(s, mem)
        expect_name = name
        if cmds is None:
            say("FAILED %s ([FUZZ_STUCK])" % name)
            break
        say("turn %d rule %s at %.0f,%.0f,%.0f hp %s wield %s" %
            (turn, name, s.pos[0], s.pos[1], s.pos[2], s.hp, s.wield or "-"))
        write(*cmds)
        mem["hp"] = s.hp
        # The commands are timed by their delays; wait about that long so
        # the next scan sees their result
        total = sum(int(c.split()[1]) for c in cmds if c.startswith("delay")) / 1000
        time.sleep(total + 0.2)
    write("delay 500", "quit")
    fifo.close()


def check():
    """drive.py --check: the parser and the rules on a written block."""
    block = """self at 1.5,8.5,-3.2 yaw 90 pitch 0 fov 72 hp 20 wield "mcl_core:apple 3" hotbar 1:mcl_core:apple 3 | 2:
crosshair mcl_core:tree at 3,8,-3
bin 0,0: sky
bin 3,3: mcl_core:tree at 3,8,-3 d=2.5 via mcl_core:leaves
bin 4,7: object 12 mobs_mc_zombie.png d=4.2
bin 7,7: nothing
hud statbar "hunger.png" 6/20
no form open
done, 8 lines""".splitlines()
    s = parse(block)
    assert s.pos == (1.5, 8.5, -3.2) and s.yaw == 90 and s.fov == 72
    assert s.hp == 20 and s.wield == "mcl_core:apple 3"
    assert s.hotbar == [(1, "mcl_core:apple 3"), (2, "")], s.hotbar
    assert s.crosshair == ("mcl_core:tree", 3, 8, -3)
    assert s.bins[(3, 3)]["via"] == ["mcl_core:leaves"] and s.bins[(3, 3)]["d"] == 2.5
    assert s.bins[(4, 7)]["kind"] == "object" and s.bins[(4, 7)]["id"] == "12"
    assert s.bins[(0, 0)]["name"] == "sky" and s.bins[(7, 7)]["name"] == "nothing"
    assert s.bars["hunger.png"] == (6, 20) and s.form is None
    # Hungry with food on the hotbar eats before it digs
    name, cmds, exp = rules(s, {})
    assert name == "eat", name
    # Fed, the crosshair on the trunk digs
    s.bars["hunger.png"] = (20, 20)
    name, cmds, exp = rules(s, {})
    assert name == "dig_tree" and cmds[0] == "mouse_down left", name
    # A form with a Respawn button is clicked at its middle
    form = parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\"",
                  "form \"__builtin:death\" open",
                  "ui   Button at 500,300 size 100x40 text \"Respawn\""])
    name, cmds, exp = rules(form, {})
    assert name == "respawn" and cmds[0] == "mouse_pos 550 320", cmds
    # The centre bin's ray is near the view direction (half a bin off it)
    d = bin_dir(s, RES // 2, RES // 2)
    assert abs(d[0] - 1) < 0.15 and abs(d[2]) < 0.25, d
    print("drive.py: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        check()
        sys.exit(0)
    if len(sys.argv) < 5:
        sys.exit("drive.py <cli.log> <fifo> <minutes> <out dir> [seed]")
    main()
