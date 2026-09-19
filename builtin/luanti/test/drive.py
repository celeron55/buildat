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
#   drive.py <cli.log> <fifo> <minutes> <out dir> [seed] [goal rung]
#
# A run has a goal ([DRIVE_GOAL]): the rung whose product ends it, the
# minutes a ceiling. Met, it writes "drive: GOAL <rung> met at turn N,
# t=S" and quits; the minutes running out first is "GOAL <rung> not met".
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
        self.slots = []      # (list, index, x, y, size, item string), pixels
        self.objects = []    # dict(id, label, at, d, screen, bin): every one on the screen
        self.voxels = {}     # (x, y, z) -> name, the cube the scan carried ("air" for 0)
        self.voxel_names = {}


BIN_RE = re.compile(
    r"bin (\d+),(\d+): (\S+)(?: at (-?\d+),(-?\d+),(-?\d+))?"
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
        m = re.match(r"voxel names (.*)$", line)
        if m:
            for part in m.group(1).split():
                i, _, name = part.partition("=")
                s.voxel_names[int(i)] = name
            continue
        m = re.match(r"voxels y=(-?\d+) z=(-?\d+) x=(-?\d+): (.*)$", line)
        if m:
            y, z, x0 = int(m.group(1)), int(m.group(2)), int(m.group(3))
            for i, tok in enumerate(m.group(4).split()):
                s.voxels[(x0 + i, y, z)] = s.voxel_names.get(int(tok), "air") if tok != "0" else "air"
            continue
        m = re.match(r"object (\S+) (\S+) at (-?[\d.]+),(-?[\d.]+),(-?[\d.]+) d=([\d.]+) "
                     r"screen (-?\d+),(-?\d+) bin (\d+),(\d+)", line)
        if m:
            s.objects.append({"id": m.group(1), "label": m.group(2),
                              "at": tuple(float(m.group(i)) for i in (3, 4, 5)),
                              "d": float(m.group(6)),
                              "screen": (int(m.group(7)), int(m.group(8))),
                              "bin": (int(m.group(9)), int(m.group(10)))})
            continue
        m = BIN_RE.match(line)
        if m:
            b = {"kind": "node", "name": m.group(3), "d": float(m.group(7) or 0),
                 "via": (m.group(8) or "").split(",") if m.group(8) else []}
            if m.group(4):
                b["at"] = tuple(int(m.group(i)) for i in (4, 5, 6))
            s.bins[(int(m.group(1)), int(m.group(2)))] = b
            continue
        m = re.match(r"form \"(.*)\" open", line)
        if m:
            s.form = m.group(1)
            continue
        m = re.match(r"slot \S+?:(\w+):(\d+) at (-?\d+),(-?\d+) size (\d+)x\d+ item \"(.*)\"", line)
        if m:
            s.slots.append((m.group(1), int(m.group(2)), int(m.group(3)),
                            int(m.group(4)), int(m.group(5)), m.group(6)))
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


def look_at_object(s, o, level=True):
    """A look_dir at an object's position from the eye (a node and a half
    over the feet)."""
    ex, ey, ez = s.pos[0], s.pos[1] + 1.5, s.pos[2]
    d = (o["at"][0] - ex, o["at"][1] - ey, o["at"][2] - ez)
    if level:
        d = (d[0], 0.0, d[2])
    if math.hypot(d[0], d[2]) < 0.05:
        return None
    return "look_dir %.3f %.3f %.3f" % d


def tight(s):
    """How many of the near horizon bins hit a node within a node and a
    half: a player hemmed in on every side reads eight of eight."""
    near = [b for (x, y), b in s.bins.items()
            if y in (RES // 2 - 1, RES // 2) and b["kind"] == "node" and b["d"] <= 1.5]
    return len(near)


# The driver's own map of the world: every voxel a scan has said,
# kept across turns and updated from each scan's cube and its rays'
# hits (user, 2026-09-20: a grid of the voxels around the player, from
# which the ones to dig and the ones to keep are picked). Positions are
# node centres.
NOT_SOLID = ("air", "water", "lava", "grass", "fern", "flower", "sapling",
             "vine", "bamboo", "clover", "dandelion", "mushroom", "torch",
             "snow", "seagrass", "kelp", "bush", "leaves_", "sugar")


def update_world(mem, s):
    world = mem.setdefault("world", {})
    world.update(s.voxels)
    for b in s.bins.values():
        if b["kind"] == "node" and "at" in b and b["name"] not in ("nothing", "sky"):
            world[b["at"]] = b["name"]
    return world


def solid_name(name):
    if name is None:
        return True    # unknown is kept as a wall until seen
    return not any(w in name for w in NOT_SOLID)


def solid_at(world, p):
    return solid_name(world.get(p))


def eye_of(s):
    return (s.pos[0], s.pos[1] + 1.5, s.pos[2])


def visible(world, eye, target):
    """Whether a ray from the eye to the target's centre meets no other
    solid voxel first, by the map."""
    d = (target[0] - eye[0], target[1] - eye[1], target[2] - eye[2])
    length = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
    if length < 1e-6:
        return False
    steps = int(length / 0.2) + 1
    seen = set()
    for i in range(1, steps + 1):
        t = min(length, i * 0.2)
        p = (int(math.floor(eye[0] + d[0] / length * t + 0.5)),
             int(math.floor(eye[1] + d[1] / length * t + 0.5)),
             int(math.floor(eye[2] + d[2] / length * t + 0.5)))
        if p == target:
            return True
        if p in seen:
            continue
        seen.add(p)
        if solid_at(world, p) and world.get(p) is not None:
            return False
    return True


def hold_for(name):
    """How long a hold digs it: stone and ore with a pickaxe, dirt, the
    soft rest."""
    base = (name or "").split(":")[-1]
    if "stone" in base or "ore" in base or "cobble" in base or "deepslate" in base:
        return 1800
    if any(w in base for w in ("dirt", "gravel", "sand", "clay", "podzol", "mycelium")):
        return 1100
    return 600


def dig_targets(s, world, targets, pick):
    """The commands that dig the given voxels -- those that are solid and
    visible from the eye -- each aimed at its centre and held by its
    material; and the ones left, solid but not visible."""
    eye = eye_of(s)
    cmds = ["keypress %d" % pick, "delay 150"] if pick else []
    left = []
    for t in targets:
        if not solid_at(world, t):
            continue
        if not visible(world, eye, t):
            left.append(t)
            continue
        d = (t[0] - eye[0], t[1] - eye[1], t[2] - eye[2])
        cmds += ["look_dir %.3f %.3f %.3f" % d, "delay 250", "mouse_down left",
                 "delay %d" % hold_for(world.get(t)), "mouse_up left", "delay 200"]
    return cmds, left


def feet_node(s):
    return (int(math.floor(s.pos[0] + 0.5)), int(math.floor(s.pos[1] + 0.5)),
            int(math.floor(s.pos[2] + 0.5)))


def ahead(s, mem, n=1):
    """The node column n steps along the stair's heading."""
    yr = math.radians(mem["stair_yaw"])
    fx, fz = math.sin(yr), math.cos(yr)
    f = feet_node(s)
    return (f[0] + int(round(fx * n)), f[1], f[2] + int(round(fz * n)))


def make_room(s, pick):
    """Plan B when there is no room to place anything (user, 2026-09-19):
    the eight nodes around the player at feet and head height dug, four
    headings, with the pickaxe if there is one. Plan A is not getting
    into such a space. Aimed at the nodes' centres -- from the eye, a
    node and a half up, the head-height neighbour is level and the
    feet-height one a node down -- so a ray through an empty or grassy
    neighbour goes on to the next node at the same height and never to
    the floor: the floor stays flat and the space traversable (user).
    A short hold, one node's worth."""
    world = s.world
    f = feet_node(s)
    targets = []
    for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
        for dy in (0, 1):
            targets.append((f[0] + dx, f[1] + dy, f[2] + dz))
    cmds, _ = dig_targets(s, world, targets, pick)
    return cmds


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


# Rung 2's crafts in the player's own 2x2 grid ([DRIVE_STORY]): what
# goes in which cell (craft:1 craft:2 / craft:3 craft:4), matched by a
# word in the item's name, and what should come out. VoxeLibre's
# mcl_core recipes: a log makes four planks, two planks over each other
# four sticks, four planks a crafting table.
# The last number is how many of the product the ladder wants before
# the recipe is left alone: enough planks for the sticks and the table
# and a pickaxe's handle later.
# Enough for the table, the wooden pickaxe, a spare table to carry
# underground for the stone one, and the sticks of both.
RECIPES_2X2 = [
    ("planks", {1: "tree"}, "wood", 16),
    ("sticks", {1: "wood", 3: "wood"}, "stick", 6),
    ("table", {1: "wood", 2: "wood", 3: "wood", 4: "wood"}, "crafting_table", 1),
]


def item_is(stack, word):
    name = stack.split(" ")[0]
    return word in name and not name.endswith("sapling")


def count_of(stack):
    return int(stack.split(" ")[1]) if " " in stack else (1 if stack else 0)


def have(s, word, n=1, mem=None):
    """Whether at least n such items are held: in the open form's main
    list, or, out of a form, in the hotbar plus what the last form
    showed of the rest of the main list (mem["main"]), since the hotbar
    is nine of thirty-six slots and a craft's result lands anywhere."""
    if any(sl[0] == "main" for sl in s.slots):
        stacks = [sl[5] for sl in s.slots if sl[0] == "main"]
    else:
        stacks = [st for _, st in s.hotbar]
        if mem is not None:
            stacks += [st for i, st in mem.get("main", []) if i > len(s.hotbar)]
    return sum(count_of(st) for st in stacks if item_is(st, word)) >= n


def click_at(x, y, w, h=None, button="left"):
    """A click at the middle of a rectangle the scan gave, in pixels."""
    h = w if h is None else h
    return ["mouse_pos %d %d" % (x + w // 2, y + h // 2), "delay 120",
            "mouse_click %s" % button, "delay 250"]


def craft_2x2(s, recipe):
    """The clicks for one craft: for each cell, pick up a stack that has
    the item, put one in the cell, put the rest back; then take the
    result and put it in an empty main slot. None when a source is
    missing."""
    name, cells, _, _ = recipe
    by = {(sl[0], sl[1]): sl for sl in s.slots}
    cmds = []
    used = {}
    for cell, word in sorted(cells.items()):
        src = None
        for sl in s.slots:
            if sl[0] == "main" and item_is(sl[5], word):
                count = int(sl[5].split(" ")[1]) if " " in sl[5] else 1
                if count - used.get((sl[0], sl[1]), 0) >= 1:
                    src = sl
                    break
        target = by.get(("craft", cell))
        if src is None or target is None:
            return None
        used[(src[0], src[1])] = used.get((src[0], src[1]), 0) + 1
        cmds += click_at(src[2], src[3], src[4])
        cmds += click_at(target[2], target[3], target[4], button="right")
        cmds += click_at(src[2], src[3], src[4])
    out = by.get(("craftpreview", 1))
    empty = [sl for sl in s.slots if sl[0] == "main" and sl[5] == ""]
    if out is None or not empty:
        return None
    cmds += click_at(out[2], out[3], out[4])
    cmds += click_at(empty[0][2], empty[0][3], empty[0][4])
    return cmds


# Rung 2's other half, at the placed table's 3x3 grid (craft:1..9, three
# a row): the wooden pickaxe. Then rung 3's stone pickaxe, the same shape
# in cobble.
RECIPES_3X3 = [
    ("pick_wood", {1: "wood", 2: "wood", 3: "wood", 5: "stick", 8: "stick"},
     "pick_wood", 1),
    ("pick_stone", {1: "cobble", 2: "cobble", 3: "cobble", 5: "stick", 8: "stick"},
     "pick_stone", 1),
    ("furnace", {1: "cobble", 2: "cobble", 3: "cobble", 4: "cobble", 6: "cobble",
                 7: "cobble", 8: "cobble", 9: "cobble"}, "furnace", 1),
]
# Rung 3's stone: enough cobble for the stone pickaxe and the furnace
COBBLE_WANTED = 11


def wanted_craft_3x3(s, mem=None):
    for r in RECIPES_3X3:
        if have(s, r[2], r[3], mem):
            continue
        need = {}
        for w in r[1].values():
            need[w] = need.get(w, 0) + 1
        if all(have(s, w, n, mem) for w, n in need.items()):
            return r
    return None


def hotbar_slot_of(s, word):
    for i, st in s.hotbar:
        if item_is(st, word):
            return i
    return None


def table_near(s):
    return (s.crosshair is not None and "crafting_table" in s.crosshair[0]) or \
        any("crafting_table" in b["name"] and b["d"] <= 6 for b in s.bins.values())


def wanted_craft(s, mem=None):
    """The lowest recipe whose product is missing and whose sources are
    at hand in the numbers it takes, or None. A placed table in view is
    as good as one held."""
    for r in RECIPES_2X2:
        if have(s, r[2], r[3], mem):
            continue
        if r[2] == "crafting_table" and table_near(s):
            continue
        need = {}
        for w in r[1].values():
            need[w] = need.get(w, 0) + 1
        if all(have(s, w, n, mem) for w, n in need.items()):
            return r
    return None


def stair_step(s, mem, pick, down):
    """One step of a staircase down (or a level tunnel) on the stair's
    heading, by the map: the node ahead at head height and at the feet
    -- and, going down, the one below that -- dug where solid and
    visible, the floor under the step kept; when the three are open,
    a step forward. The expectation: fewer of them solid, or the feet
    moved onto the step."""
    world = s.world
    a = ahead(s, mem)
    targets = [(a[0], a[1] + 1, a[2]), a]
    if down:
        targets.append((a[0], a[1] - 1, a[2]))
    yr = math.radians(mem["stair_yaw"])
    fx, fz = math.sin(yr), math.cos(yr)
    to_dig = [t for t in targets if solid_at(world, t)]
    if not to_dig:
        p0 = s.pos
        cmds = ["look_dir %.3f -0.3 %.3f" % (fx, fz)] + walk(0.6) + ["delay 400"]
        return "stair_walk", cmds, lambda n, p=p0: math.dist(n.pos, p) > 0.6
    cmds, left = dig_targets(s, world, targets, pick)
    if len(cmds) <= 2:
        # Solid but nothing visible from here: closer, and turn to it
        cmds = ["look_dir %.3f -0.5 %.3f" % (fx, fz)] + walk(0.3) + ["delay 300"]
        return "stair_approach", cmds, None
    was = len(to_dig)
    name = "stair_step" if down else "tunnel_step"
    return name, cmds + ["delay 300"], lambda n, w=was, ts=targets: \
        sum(1 for t in ts if solid_at(n.world, t)) < w


# The rules, in priority order. Each is (name, condition, act) where act
# returns the commands and an expectation: a function of the next state
# that says whether what the rule wanted happened, or None.
def rules(s, mem):
    s.world = update_world(mem, s)
    if any(sl[0] == "main" for sl in s.slots):
        mem["main"] = [(sl[1], sl[5]) for sl in s.slots if sl[0] == "main"]
    # form open: the death screen's Respawn, the pause menu's Escape, any
    # other form's Escape
    if s.form is not None:
        # The button is drawn as a BorderImage with a Text in it, so the
        # text's own rectangle is what is clicked
        btn = [u for u in s.ui if u[5] and u[5].lower().startswith("respawn")]
        # Stuck is a form that three Escapes did not close, not one that
        # is being worked in (seven crafts in a row are seven turns)
        if mem.get("closes_in_row", 0) >= 3:
            return "stuck_form", None, None
        if btn:
            _, x, y, w, h, _, _ = btn[0]
            return "respawn", click_at(x, y, w, h) + [ms(TURN_S)], \
                lambda n: n.form is None
        # The player's own inventory: a craft while there is one to do,
        # its expectation the product in a main slot on the next scan
        craft_cells = sum(1 for sl in s.slots if sl[0] == "craft")
        if s.form == "" and craft_cells == 4:
            r = wanted_craft(s, mem)
            if r is not None:
                cmds = craft_2x2(s, r)
                if cmds is not None:
                    return "craft_" + r[0], cmds + ["delay 300"], \
                        lambda n, w=r[2]: have(n, w, 1, mem)
            # A thing wanted in the hand lies past the hotbar: moved to
            # an empty hotbar slot (a pick up and a put down)
            for word in ("crafting_table", "pick_stone", "pick_wood"):
                if hotbar_slot_of(s, word) is not None:
                    continue
                src = [sl for sl in s.slots if sl[0] == "main" and sl[1] > 9 and
                       item_is(sl[5], word)]
                dst = [sl for sl in s.slots if sl[0] == "main" and sl[1] <= 9 and
                       sl[5] == ""]
                if src and dst:
                    cmds = click_at(src[0][2], src[0][3], src[0][4]) + \
                        click_at(dst[0][2], dst[0][3], dst[0][4]) + ["delay 300"]
                    return "to_hotbar_" + word, cmds, \
                        lambda n, w=word: hotbar_slot_of(n, w) is not None
        # The furnace's form: coal into fuel, ore into src, the ingot out
        # of dst; the expectation is what was put showing in the slots
        lists = {sl[0] for sl in s.slots}
        if "fuel" in lists and "src" in lists and "dst" in lists:
            by = {sl[0]: sl for sl in s.slots if sl[0] in ("fuel", "src", "dst")}
            dst = by["dst"]
            if dst[5]:
                empty = [sl for sl in s.slots if sl[0] == "main" and sl[5] == ""]
                if empty:
                    cmds = click_at(dst[2], dst[3], dst[4]) + \
                        click_at(empty[0][2], empty[0][3], empty[0][4]) + ["delay 300"]
                    return "take_ingot", cmds, lambda n: have(n, "ingot", 1, mem)
            cmds = []
            for lst, word in (("fuel", "coal"), ("src", "stone_with_iron")):
                if by[lst][5]:
                    continue
                src = [sl for sl in s.slots if sl[0] == "main" and item_is(sl[5], word)]
                if src:
                    cmds += click_at(src[0][2], src[0][3], src[0][4]) + \
                        click_at(by[lst][2], by[lst][3], by[lst][4])
            if cmds:
                return "feed_furnace", cmds + ["delay 300"], \
                    lambda n: any(sl[0] in ("fuel", "src") and sl[5] for sl in n.slots)
            # Fed: closed, and back in a while for the ingot
            mem["furnace_fed_turn"] = turn
        # The table's form: the 3x3 crafts
        if craft_cells == 9:
            r = wanted_craft_3x3(s, mem)
            if r is not None:
                cmds = craft_2x2(s, r)
                if cmds is not None:
                    return "craft_" + r[0], cmds + ["delay 300"], \
                        lambda n, w=r[2]: have(n, w, 1, mem)
        mem["closes_in_row"] = mem.get("closes_in_row", 0) + 1
        return "close_form", ["keypress Escape", ms(TURN_S)], \
            lambda n: n.form is None
    mem["closes_in_row"] = 0
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

    # an item in view: walk to it, and the hotbar should gain within two
    # turns (the pickup is the game's, at about a node)
    # turns; the expectation is the hotbar up, the item gone, or a node
    # nearer to it. An item not reached in four turns is left alone for
    # a while (a bamboo drop across a thicket, seed 5).
    given_up = mem.setdefault("given_up", {})
    items = [o for o in s.objects if o["label"].startswith("item:") and
             o["d"] <= 10 and given_up.get(o["id"], -99) < turn - 30]
    if items:
        o = min(items, key=lambda o: o["d"])
        tries = mem.setdefault("item_tries", {})
        tries[o["id"]] = tries.get(o["id"], 0) + 1
        if tries[o["id"]] > 4:
            given_up[o["id"]] = turn
            tries[o["id"]] = 0
        else:
            look = look_at_object(s, o)
            if look:
                mem["last_item"] = o["id"]
                before = sum(count_of(st) for _, st in s.hotbar)
                walk_s = min(TURN_S, max(0.3, (o["d"] - 0.5) / 4))
                return "to_item", [look] + walk(walk_s, jump=True), \
                    lambda n, b=before, oid=o["id"], d0=o["d"]: \
                        sum(count_of(st) for _, st in n.hotbar) > b or \
                        all(x["id"] != oid for x in n.objects) or \
                        any(x["id"] == oid and x["d"] < d0 - 1 for x in n.objects)

    # something to craft from what is held: open the inventory, and the
    # form rule above does the craft
    if wanted_craft(s, mem) is not None:
        return "open_inventory", ["keypress I", ms(1.0)], \
            lambda n: n.form is not None
    # Rung 3: stone dug with the pickaxe until there is cobble enough for
    # the stone pickaxe and the furnace; the expectation is the crosshair
    # off that stone
    pick = hotbar_slot_of(s, "pick_stone") or hotbar_slot_of(s, "pick_wood")
    kit = have(s, "crafting_table", 1, mem) and have(s, "stick", 2, mem)
    if pick is not None and kit and not have(s, "cobble", COBBLE_WANTED, mem):
        if s.crosshair and s.crosshair[0].endswith(":stone"):
            was = s.crosshair
            cmds = ["keypress %d" % pick, "delay 150", "mouse_down left",
                    "delay 2500", "mouse_up left", "delay 300"]
            return "dig_stone", cmds, lambda n: n.crosshair != was
        stones = [(x, y) for (x, y), b in s.bins.items()
                  if b["name"].endswith(":stone") and b["d"] <= 4]
        if stones:
            bx, by = min(stones, key=lambda k: s.bins[k]["d"])
            return "to_stone", [look_at_bin(s, bx, by, level=False), ms(0.3)], None
        # No stone in sight on the surface: a staircase down with the
        # pickaxe, one step a turn -- the node ahead at head height, at
        # the feet and the one below that, then a step forward -- on one
        # heading, so that the way back up is a walk and a jump, not a
        # shaft (user, 2026-09-19: straight down makes a vertical shaft
        # the player then has to make its way up). The expectation is
        # the feet lower.
        if not any(b["name"].endswith(":stone") for b in s.bins.values()) and \
                mem.get("no_dig_down_until", 0) <= turn:
            if "stair_yaw" not in mem:
                mem["stair_yaw"] = s.yaw
            name, cmds, exp = stair_step(s, mem, pick, down=True)
            return name, cmds, exp

    # Moving on with nothing more to craft at a table in view and none
    # held: dug back into the inventory, which saves the planks of the
    # next one (a player's tip, 2026-09-19); the pickup is the walk over
    # it, by the item rule
    if wanted_craft_3x3(s, mem) is None and not have(s, "crafting_table", 1, mem):
        if s.crosshair and "crafting_table" in s.crosshair[0]:
            was = s.crosshair
            # A table is hardness 2.5, near four seconds by hand
            cmds = ["mouse_down left", "delay 5000", "mouse_up left", "delay 300"]
            return "take_table", cmds, lambda n: n.crosshair != was
        tables = [(x, y) for (x, y), b in s.bins.items()
                  if "crafting_table" in b["name"] and b["d"] <= 4]
        if tables:
            bx, by = min(tables, key=lambda k: s.bins[k]["d"])
            return "to_table", [look_at_bin(s, bx, by, level=False), ms(0.3)], None

    # Rung 4: ore in view -- coal with any pickaxe, iron with the stone
    # one -- dug until there is a few of each; then the furnace placed and
    # fed through its form (below, among the form rules)
    if pick is not None:
        want = []
        if not have(s, "coal", 4, mem):
            want.append("stone_with_coal")
        if hotbar_slot_of(s, "pick_stone") is not None and not have(s, "iron", 3, mem):
            want.append("stone_with_iron")
        ores = [(x, y) for (x, y), b in s.bins.items()
                if any(w in b["name"] for w in want) and b["d"] <= 10]
        if s.crosshair and any(w in s.crosshair[0] for w in want):
            was = s.crosshair
            cmds = ["keypress %d" % pick, "delay 150", "mouse_down left",
                    "delay 3500", "mouse_up left", "delay 300"]
            return "dig_ore", cmds, lambda n: n.crosshair != was
        if ores:
            # Ore is one stone in three hundred (415 coal and 231 iron
            # among 224k stone within forty nodes of seed 5's spawn), so
            # one seen ten nodes off is walked to, digging the way there
            # with the same three-node step the tunnel uses
            bx, by = min(ores, key=lambda k: s.bins[k]["d"])
            d = s.bins[(bx, by)]["d"]
            if d <= 4:
                return "to_ore", [look_at_bin(s, bx, by, level=False), ms(0.3)], None
            dx, dy, dz = bin_dir(s, bx, by)
            h = math.hypot(dx, dz) or 1e-6
            fx, fz = dx / h, dz / h
            cmds = ["keypress %d" % pick, "delay 150"]
            for ddy in (0.0, -1.0):
                cmds += ["look_dir %.3f %.3f %.3f" % (fx, ddy, fz), "delay 250",
                         "mouse_down left", "delay 1500", "mouse_up left", "delay 200"]
            # Then walked up to the dug step, a whole second: a shorter walk
            # left the player a node behind it, and the next turn's rays
            # went past the step to the floor beyond, so the tunnel ran
            # level at y 8 for good (2026-09-20)
            cmds += ["look_dir %.3f -0.3 %.3f" % (fx, fz)] + walk(1.0) + ["delay 400"]
            return "toward_ore", cmds, None
        # No ore in view and some wanted: mined for. The staircase down to
        # where the ore is -- VoxeLibre's iron is dense at y -62..-23 and
        # none above y 1, coal up to -12 (mcl_mapgen_core/ores.lua) -- so
        # to y -30 or so, then a tunnel on the same heading at that depth,
        # two nodes high, the floor flat, so the walls show ore and the
        # way back is a walk (user: a traversable space). The expectation
        # is the feet moved.
        if want and mem.get("no_dig_stair_until", 0) <= turn and \
                wanted_craft_3x3(s, mem) is None:
            if "stair_yaw" not in mem:
                mem["stair_yaw"] = s.yaw
            name, cmds, exp = stair_step(s, mem, pick, down=s.pos[1] > -30)
            return "mine" if name == "tunnel_step" else name, cmds, exp
        # Iron and coal to smelt, a furnace held: place it as the table is,
        # use it; the form rule feeds it
        if have(s, "iron", 1, mem) and have(s, "coal", 1, mem) and \
                not have(s, "iron_ingot", 1, mem):
            if s.crosshair and "furnace" in s.crosshair[0]:
                return "use_furnace", ["mouse_click right", ms(1.0)], \
                    lambda n: n.form is not None
            furnaces = [(x, y) for (x, y), b in s.bins.items()
                        if "furnace" in b["name"] and b["d"] <= 6]
            fslot = hotbar_slot_of(s, "furnace")
            if furnaces:
                bx, by = min(furnaces, key=lambda k: s.bins[k]["d"])
                d = s.bins[(bx, by)]["d"]
                cmds = [look_at_bin(s, bx, by, level=False)]
                cmds += walk((d - 2.5) / 4) if d > 3.5 else [ms(0.3)]
                return "to_furnace", cmds, None
            if fslot is not None and mem.get("no_place_until", 0) > turn and tight(s) >= 4:
                was = tight(s)
                mem["no_place_until"] = 0
                return "make_room", make_room(s, pick) + ["delay 300"], \
                    lambda n, w=was: tight(n) < w or w == 0
            if fslot is not None:
                yr = math.radians(s.yaw + rng.uniform(-60, 60))
                cmds = ["keypress %d" % fslot, "delay 150",
                        "look_dir %.3f -1.2 %.3f" % (math.sin(yr), math.cos(yr)),
                        "delay 300", "mouse_click right", ms(0.8)]
                return "place_furnace", cmds, lambda n: any(
                    "furnace" in b["name"] for b in n.bins.values())

    # A 3x3 craft wanted: at a table, its form; with a table in hand,
    # place it on the ground ahead; with one past the hotbar, fetch it
    if wanted_craft_3x3(s, mem) is not None:
        if s.crosshair and "crafting_table" in s.crosshair[0]:
            return "use_table", ["mouse_click right", ms(1.0)], \
                lambda n: n.form is not None
        tables = [(x, y) for (x, y), b in s.bins.items()
                  if "crafting_table" in b["name"] and b["d"] <= 6]
        slot = hotbar_slot_of(s, "crafting_table")
        if tables:
            bx, by = min(tables, key=lambda k: s.bins[k]["d"])
            d = s.bins[(bx, by)]["d"]
            cmds = [look_at_bin(s, bx, by, level=False)]
            cmds += walk((d - 2.5) / 4) if d > 3.5 else [ms(0.3)]
            return "to_table", cmds, None
        if slot is not None and mem.get("no_place_until", 0) > turn and tight(s) >= 4:
            # No room where it was tried and walls close on every side:
            # dug around the player (plan B). In the open -- tall grass at
            # the feet took the placement -- another heading is enough.
            pick = hotbar_slot_of(s, "pick_stone") or hotbar_slot_of(s, "pick_wood")
            was = tight(s)
            mem["no_place_until"] = 0
            return "make_room", make_room(s, pick) + ["delay 300"], \
                lambda n, w=was: tight(n) < w or w == 0
        if slot is not None:
            # A little off the last heading each try: the ground ahead
            # may be a slope or the player's own space, which the client
            # refuses
            yr = math.radians(s.yaw + rng.uniform(-60, 60))
            cmds = ["keypress %d" % slot, "delay 150",
                    "look_dir %.3f -1.2 %.3f" % (math.sin(yr), math.cos(yr)),
                    "delay 300", "mouse_click right", ms(0.8)]
            return "place_table", cmds, lambda n: any(
                "crafting_table" in b["name"] for b in n.bins.values())
        if have(s, "crafting_table", 1, mem):
            return "open_inventory", ["keypress I", ms(1.0)], \
                lambda n: n.form is not None

    # a tree in view, while logs are wanted (six cover the ladder's wood)
    trees = [(x, y) for (x, y), b in s.bins.items()
             if b["kind"] == "node" and is_tree(b["name"]) and b["d"] <= 10]
    if have(s, "tree", 8, mem):
        trees = []
    if s.crosshair and is_tree(s.crosshair[0]) and not have(s, "tree", 8, mem):
        cmds = ["mouse_down left", "delay 4000", "mouse_up left", "delay 300"]
        was = s.crosshair
        return "dig_tree", cmds, lambda n: n.crosshair != was
    # A trunk walked at and never reached (473 turns of it in one run: a
    # canopy's logs overhead, a trunk across a stream) is left alone for
    # thirty turns after six tries
    given_up = mem.setdefault("given_up", {})
    trees = [k for k in trees if given_up.get(s.bins[k].get("at"), -99) < turn - 30]
    if trees:
        bx, by = min(trees, key=lambda k: s.bins[k]["d"])
        d = s.bins[(bx, by)]["d"]
        at = s.bins[(bx, by)].get("at")
        tries = mem.setdefault("tree_tries", {})
        tries[at] = tries.get(at, 0) + 1
        if tries[at] > 6:
            given_up[at] = turn
            tries[at] = 0
            return "leave_tree", [look_away(s)] + walk(TURN_S, jump=True), None
        cmds = [look_at_bin(s, bx, by, level=False)]
        if d > 3.5:
            cmds += walk(min(TURN_S, (d - 3) / 4))
        else:
            cmds += [ms(0.3)]
        return "to_tree", cmds, None

    # a mob in view: punch it once and back off
    mobs = [o for o in s.objects if not o["label"].startswith("item:") and
            o["d"] <= 4]
    if mobs and mem.get("punched_turn", -99) < turn - 5:
        o = min(mobs, key=lambda o: o["d"])
        look = look_at_object(s, o, level=False)
        if look:
            mem["punched_turn"] = turn
            cmds = [look, "delay 200", "mouse_click left", "delay 200",
                    "keydown S", ms(0.8), "keyup S"]
            return "punch", cmds, None

    # something to place: a placeable wielded and the crosshair on ground
    if s.crosshair and s.wield and ":" in s.wield and rng.random() < 0.1:
        placeable = not any(w in s.wield for w in ("axe", "pick", "sword", "shovel"))
        if placeable:
            return "place", ["mouse_click right", ms(0.5)], None

    # In water (the feet's bin row is water and the eye is low): out the
    # way the nearest dry ground is, jumping -- the first run spun at a
    # lake's shore for four hundred turns, every look seeing water below
    floor = [b for (x, y), b in s.bins.items() if y == RES - 1]
    wet = sum(1 for b in floor if b["kind"] == "node" and "water" in b["name"])
    if floor and wet >= len(floor) // 2:
        dry = [(x, y) for (x, y), b in s.bins.items()
               if b["kind"] == "node" and "water" not in b["name"] and
               b["d"] < 10 and y >= RES // 2]
        if dry:
            bx, by = min(dry, key=lambda k: s.bins[k]["d"])
            return "out_of_water", [look_at_bin(s, bx, by)] + \
                walk(TURN_S, jump=True), None
        mem["walking"] = 0
        return "turn_in_water", [look_away(s)] + walk(TURN_S, jump=True), None
    # otherwise explore: toward the longest ray, away from a cliff
    horizon = [(x, y) for (x, y) in s.bins if y in (RES // 2, RES // 2 - 1)]
    cliff = all(b["kind"] != "node" for b in floor) if floor else False
    if cliff:
        mem["walking"] = 0
        return "turn_at_edge", [look_away(s), ms(0.3)], None

    def length(k):
        b = s.bins[k]
        return b["d"] if b["kind"] == "node" else 10.5
    bx, by = max(horizon, key=length) if horizon else (RES // 2, RES // 2)
    mem["walking"] = mem.get("walking", 0) + 1
    return "explore", [look_at_bin(s, bx, by)] + walk(TURN_S, jump=rng.random() < 0.3), None


# What each rung's product is, the ladder's own predicate ([DRIVE_STORY])
GOALS = {
    1: lambda s, mem: have(s, "tree", 1, mem),
    2: lambda s, mem: have(s, "pick_wood", 1, mem),
    3: lambda s, mem: have(s, "pick_stone", 1, mem) and have(s, "furnace", 1, mem),
    4: lambda s, mem: have(s, "ingot", 1, mem),
}


def main():
    global log, fifo, out, turn
    log, fifo_path, minutes, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
    if len(sys.argv) > 5:
        rng.seed(int(sys.argv[5]))
    goal = int(sys.argv[6]) if len(sys.argv) > 6 else max(GOALS)
    goal = max(1, min(goal, max(GOALS)))
    t0 = time.time()
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
        s.world = update_world(mem, s)
        if expect is not None:
            held = expect(s)
            if held:
                failed_in_row = 0
            elif expect_name in ("place_table", "place_furnace"):
                # Nor this: no room where it was tried; room is made when
                # hemmed in, another heading otherwise
                say("turn %d: %s found no room" % (turn, expect_name))
                mem["no_place_until"] = turn + 1
            elif expect_name == "make_room":
                say("turn %d: the room did not open" % turn)
            elif expect_name in ("mine", "stair_step", "tunnel_step", "stair_walk"):
                say("turn %d: the tunnel did not advance; elsewhere for five turns" % turn)
                mem["no_dig_stair_until"] = turn + 5
            elif expect_name in ("dig_stair", "stair_approach"):
                # Not a finding either: hanging in vines the dig goes
                # through and the feet stay; somewhere else in ten turns
                say("turn %d: the ground did not give; elsewhere for ten turns" % turn)
                mem["no_dig_down_until"] = turn + 10
            elif expect_name == "to_item":
                # Not a finding: an item out of reach is given up on
                say("turn %d: the item was not reached; given up" % turn)
                mem.setdefault("given_up", {})[mem.get("last_item")] = turn
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
        if any(sl[0] == "main" for sl in s.slots):
            mem["main"] = [(sl[1], sl[5]) for sl in s.slots if sl[0] == "main"]
        if GOALS[goal](s, mem):
            say("GOAL %d met at turn %d, t=%d" % (goal, turn, time.time() - t0))
            break
        name, cmds, expect = rules(s, mem)
        expect_name = name
        if cmds is None:
            say("FAILED %s ([FUZZ_STUCK])" % name)
            break
        say("turn %d rule %s at %.0f,%.0f,%.0f hp %s wield %s" %
            (turn, name, s.pos[0], s.pos[1], s.pos[2], s.hp, s.wield or "-"))
        # On the screen too, for whoever is watching the window
        # ([DRIVE_STATUS]): the rule and the first command that says
        # what it is about
        about = next((c for c in cmds if c.startswith(("look", "mouse_pos", "keypress"))), "")
        write("event status_text turn %d %s %s" % (turn, name, about))
        write(*cmds)
        mem["hp"] = s.hp
        # The commands are timed by their delays; wait about that long so
        # the next scan sees their result
        total = sum(int(c.split()[1]) for c in cmds if c.startswith("delay")) / 1000
        time.sleep(total + 0.2)
    else:
        say("GOAL %d not met in %d turns" % (goal, turn))
    write("delay 500", "quit")
    fifo.close()


def check():
    """drive.py --check: the parser and the rules on a written block."""
    block = """self at 1.5,8.5,-3.2 yaw 90 pitch 0 fov 72 hp 20 wield "mcl_core:apple 3" hotbar 1:mcl_core:apple 3 | 2:
crosshair mcl_core:tree at 3,8,-3
bin 0,0: sky
bin 3,3: mcl_core:tree at 3,8,-3 d=2.5 via mcl_core:leaves
object 12 mobs_mc_zombie.png at 3.0,8.0,-1.0 d=4.2 screen 700,600 bin 4,7
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
    assert s.objects[0]["id"] == "12" and s.objects[0]["bin"] == (4, 7)
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
    # An item on the screen is walked to, and the expectation is the
    # hotbar's count up or the item gone
    it = parse(["self at 10,4,10 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:jungletree 2",
                "object 41 item:mcl_core:jungletree at 12.0,4.2,13.0 d=3.6 screen 700,400 bin 4,4"])
    assert it.objects[0]["label"] == "item:mcl_core:jungletree"
    name, cmds, exp = rules(it, {})
    assert name == "to_item" and cmds[0].startswith("look_dir 2.000 0.000 3.000"), cmds
    assert exp(parse(["self at 10,4,10 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:jungletree 3"]))
    assert not exp(it)
    # Hemmed in with a table to place: room is made
    hemmed = ["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:junglewood 16 | 2:mcl_core:stick 6 | 3:mcl_crafting_table:crafting_table 1 | 4:mcl_tools:pick_wood 1 | 5:mcl_core:cobble 20"]
    hemmed += ["bin %d,%d: mcl_core:stone at 1,0,0 d=0.8" % (x, y) for x in range(8) for y in (3, 4)]
    hm = parse(hemmed)
    assert tight(hm) == 16
    name, cmds, exp = rules(hm, {"no_place_until": 99})
    # sixteen: the ring at the feet and at the head, every voxel unknown
    # and so kept solid until seen
    assert name == "make_room" and cmds.count("mouse_down left") == 16, (name, len(cmds))
    # The scan's cube into the map, and a stair step by it: ahead on the
    # heading (yaw 0: +z) the head node is air, the feet node stone, the one
    # below dirt; only those two are dug, the head one not
    cube = ["self at 10,20.5,10 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_tools:pick_stone 1 | 2:mcl_crafting_table:crafting_table 1 | 3:mcl_core:stick 2",
            "voxel names 1=mcl_core:stone 2=mcl_core:dirt",
            "voxels y=22 z=11 x=9: 0 0 0",
            "voxels y=21 z=11 x=9: 0 1 0",
            "voxels y=20 z=11 x=9: 2 2 2",
            "voxels y=19 z=11 x=9: 1 1 1"]
    cs = parse(cube)
    m = {"stair_yaw": 0.0}
    cs.world = update_world(m, cs)
    assert cs.world[(10, 21, 11)] == "mcl_core:stone" and cs.world[(10, 22, 11)] == "air"
    name, cmds, exp = stair_step(cs, m, 1, down=True)
    # one this turn: the node below is behind the feet node from the eye
    assert name == "stair_step" and cmds.count("mouse_down left") == 1, (name, cmds)
    cs.world[(10, 21, 11)] = "air"
    name, cmds, exp = stair_step(cs, m, 1, down=True)
    assert name == "stair_step" and cmds.count("mouse_down left") == 1 and \
        "delay 1100" in cmds, (name, cmds)   # the dirt's hold
    # dug, the step is walked; the floor under it (y 19) was never a target
    cs.world[(10, 20, 11)] = "air"
    assert stair_step(cs, m, 1, down=True)[0] == "stair_walk"
    assert cs.world[(10, 19, 11)] == "mcl_core:stone"
    # A table in the crosshair with nothing more to craft at it is dug back
    done = parse(["self at 0,0,0 yaw 90 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_tools:pick_wood 1 | 2:mcl_core:stick 6",
                  "crosshair mcl_crafting_table:crafting_table at 1,0,0"])
    assert rules(done, {})[0] == "take_table"
    # With a stone pickaxe and no ore in view the driver mines for it
    mine = parse(["self at 0,-35,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_tools:pick_stone 1 | 2:mcl_core:cobble 20 | 3:mcl_crafting_table:crafting_table 1 | 4:mcl_core:stick 2 | 5:mcl_furnaces:furnace 1"])
    name, cmds, exp = rules(mine, {})
    assert name == "mine" and cmds.count("mouse_down left") == 2, (name, cmds)
    # Ore in the crosshair with a pickaxe is dug
    ore = parse(["self at 0,0,0 yaw 0 pitch 30 fov 72 hp ? wield \"\" hotbar 1:mcl_tools:pick_stone 1 | 2:mcl_core:cobble 20 | 3:mcl_crafting_table:crafting_table 1 | 4:mcl_core:stick 2",
                 "crosshair mcl_core:stone_with_iron at 0,-1,1"])
    assert rules(ore, {})[0] == "dig_ore"
    # The furnace's form is fed coal and ore
    fur = ["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:", "form \"x\" open",
           "slot current_player:main:1 at 0,500 size 48x48 item \"mcl_core:coal_lump 3\"",
           "slot current_player:main:2 at 60,500 size 48x48 item \"mcl_core:stone_with_iron 2\"",
           "slot nodemeta:1,2,3:src:1 at 200,50 size 48x48 item \"\"",
           "slot nodemeta:1,2,3:fuel:1 at 200,150 size 48x48 item \"\"",
           "slot nodemeta:1,2,3:dst:1 at 400,100 size 48x48 item \"\""]
    name, cmds, exp = rules(parse(fur), {})
    assert name == "feed_furnace" and cmds.count("mouse_click left") == 4, (name, cmds)
    # With planks, sticks and a table in the hotbar a pickaxe is wanted:
    # the table is placed, then used, then its 3x3 form crafts
    tab = parse(["self at 0,0,0 yaw 90 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:junglewood 16 | 2:mcl_core:stick 6 | 3:mcl_crafting_table:crafting_table 1"])
    assert wanted_craft_3x3(tab)[0] == "pick_wood"
    name, cmds, exp = rules(tab, {})
    assert name == "place_table" and cmds[0] == "keypress 3", (name, cmds)
    at_table = parse(["self at 0,0,0 yaw 90 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:junglewood 16 | 2:mcl_core:stick 6 | 3:mcl_crafting_table:crafting_table 1",
                      "crosshair mcl_crafting_table:crafting_table at 1,0,0"])
    assert rules(at_table, {})[0] == "use_table"
    grid = ["self at 0,0,0 yaw 90 pitch 0 fov 72 hp ? wield \"\" hotbar 1:", "form \"main\" open",
            "slot current_player:main:1 at 0,500 size 48x48 item \"mcl_core:junglewood 16\"",
            "slot current_player:main:2 at 60,500 size 48x48 item \"mcl_core:stick 6\"",
            "slot current_player:main:4 at 180,500 size 48x48 item \"mcl_crafting_table:crafting_table 1\"",
            "slot current_player:main:3 at 120,500 size 48x48 item \"\"",
            "slot current_player:craftpreview:1 at 600,100 size 48x48 item \"\""]
    grid += ["slot current_player:craft:%d at %d,%d size 48x48 item \"\"" % (i, 200 + (i - 1) % 3 * 60, 50 + (i - 1) // 3 * 60) for i in range(1, 10)]
    name, cmds, exp = rules(parse(grid), {})
    assert name == "craft_pick_wood" and cmds.count("mouse_click right") == 5, (name, cmds)
    # With a pickaxe and stone under the crosshair, the stone is dug
    st = parse(["self at 0,0,0 yaw 0 pitch 30 fov 72 hp ? wield \"\" hotbar 1:mcl_tools:pick_wood 1 | 2:mcl_crafting_table:crafting_table 1 | 3:mcl_core:stick 2",
                "crosshair mcl_core:stone at 0,-1,1"])
    name, cmds, exp = rules(st, {})
    assert name == "dig_stone" and cmds[0] == "keypress 1", (name, cmds)
    # and with none in sight, down through the ground
    name, cmds, exp = rules(parse(["self at 0,5,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_tools:pick_wood 1 | 2:mcl_crafting_table:crafting_table 1 | 3:mcl_core:stick 2"]), {})
    assert name == "stair_step" and cmds.count("mouse_down left") == 3, name
    # A craft: a log in the hotbar wants planks; the form's slots give the
    # clicks, source, cell, source, result, empty slot
    inv = parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:jungletree 4",
                 "form \"\" open",
                 "slot current_player:main:1 at 564,832 size 72x72 item \"mcl_core:jungletree 4\"",
                 "slot current_player:main:2 at 654,832 size 72x72 item \"\"",
                 "slot current_player:craft:1 at 1014,210 size 72x72 item \"\"",
                 "slot current_player:craft:2 at 1104,210 size 72x72 item \"\"",
                 "slot current_player:craft:3 at 1014,300 size 72x72 item \"\"",
                 "slot current_player:craft:4 at 1104,300 size 72x72 item \"\"",
                 "slot current_player:craftpreview:1 at 1284,255 size 72x72 item \"\""])
    assert wanted_craft(inv)[0] == "planks"
    # Two planks make sticks but not a table, which takes four
    two = parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:junglewood 2"])
    assert wanted_craft(two)[0] == "sticks"
    assert wanted_craft(parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:junglewood 2 | 2:mcl_core:stick 6"])) is None
    # and with planks and sticks enough the table is what is wanted
    assert wanted_craft(parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:junglewood 16 | 2:mcl_core:stick 6"]))[0] == "table"
    # What a form showed of the main list past the hotbar counts after it closed
    m = {}
    rules(parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:",
                 "form \"\" open",
                 "slot current_player:main:10 at 0,0 size 48x48 item \"mcl_core:junglewood 4\"",
                 "slot current_player:craft:1 at 0,0 size 48x48 item \"\""]), m)
    assert have(parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:"]), "wood", 4, m)
    name, cmds, exp = rules(inv, {})
    assert name == "craft_planks" and cmds[0] == "mouse_pos 600 868" and \
        "mouse_click right" in cmds, cmds
    assert not exp(inv) and exp(parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:junglewood 4"]))
    assert rules(parse(["self at 0,0,0 yaw 0 pitch 0 fov 72 hp ? wield \"\" hotbar 1:mcl_core:jungletree 4"]), {})[0] == "open_inventory"
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
