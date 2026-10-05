#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [UI_PARITY] 1 and 2: the two coordinate systems and the slot pitch,
# against official Luanti. ui_parity.lua shows a legacy form and then a
# real_coordinates one, each with three box[]es and a list whose slots
# listcolors makes magenta; both clients are shot (official Luanti's window
# by `import`, on the desktop, as reference_shots does) and every rectangle
# is put in the form's units, from the red box to the green one, so the
# overall scale -- the engine's business -- cancels out. Each number within
# 0.03 units of official's (a pixel and a half) passes. Shots under
# local/ui_parity/. Needs the Luanti checkout's luanti-refshots and devtest.
#
#   builtin/luanti/test/ui_parity.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/ui_parity"; mkdir -p "$out"
luanti=~/projects/luanti; bin=$luanti/bin/luanti-refshots
W=1024; H=768
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "a client or a Luanti server is already running" >&2; exit 2
fi
rm -f "$out"/*.png

# Official Luanti: its own server and client on devtest, the fixture a worldmod
work="$out/luanti_world"
rm -rf "${work:?}"; mkdir -p "$work/worldmods/ui_parity"
printf 'gameid = devtest\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\ncreative_mode = false\nserver_announce = false\n' > "$work/world.mt"
cp "$me/ui_parity.lua" "$work/worldmods/ui_parity/init.lua"
printf 'name = ui_parity\n' > "$work/worldmods/ui_parity/mod.conf"
printf 'screen_w = %s\nscreen_h = %s\nfullscreen = false\nmute_sound = true\nenable_damage = false\n' \
	$W $H > "$out/luanti.conf"
port=30031
( cd "$luanti" && exec "$bin" --server --world "$work" --port $port \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
for _ in $(seq 120); do grep -q "Server for gameid" "$out/luanti_srv.log" && break; sleep 1; done
( cd "$luanti" && exec "$bin" --go --address 127.0.0.1 --port $port --name uip \
	--config "$out/luanti.conf" > "$out/luanti_cli.log" 2>&1 ) &
cli=$!
trap 'kill $cli $srv 2>/dev/null' EXIT
win=""
for _ in $(seq 40); do
	sleep 1
	win=$(wmctrl -lp | awk -v p="$cli" '$3 == p {print $1; exit}')
	[ -n "$win" ] && break
done
[ -n "$win" ] || { echo "FAIL: no window for official Luanti"; exit 1; }
for f in legacy real items; do
	for _ in $(seq 90); do grep -q "UIP $f" "$out/luanti_srv.log" && break; sleep 1; done
	sleep 2
	import -window "$win" "$out/official_$f.png"
done
kill $cli $srv; wait $cli $srv 2>/dev/null

# buildat: vanilla on devtest, the fixture as BUILDAT_LUANTI_LUA
t=$(mktemp -d); P=29598; pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; rm -rf "${t:?}"' EXIT
mkdir -p "$t/srv/shared/vanilla"
ln -s "$BUILDAT_USER_PATH/shared/vanilla/games" "$t/srv/shared/vanilla/games"
cp "$me/ui_parity.lua" "$t/srv/shared/"
cd "$here/Build"
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=uip BUILDAT_LUANTI_LUA="$t/srv/shared/ui_parity.lua" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$t/srv" -P $P -l 3 \
	> "$out/buildat_srv.log" 2>&1 &
pid=$!
for _ in $(seq 120); do ss -ltn | grep -q ":$P " && break; sleep 1; done
printf "wait_log 90000 the server put the player at\ndelay 6000\nscreenshot $out/buildat_legacy.png\ndelay 8000\nscreenshot $out/buildat_real.png\ndelay 8000\nscreenshot $out/buildat_items.png\nquit\n" > "$t/c"
timeout 150 bin/buildat -s 127.0.0.1:$P -w ${W}x$H -u 1 -l 3 -o sound_mute=1 \
	-c @"$t/c" > "$out/buildat_cli.log" 2>&1

python3 - "$out" <<'PY'
import sys, numpy as np
from PIL import Image
out = sys.argv[1]
def rect(m):
	ys, xs = np.nonzero(m)
	return (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1) if len(xs) else None
def runs(v):
	r, start = [], None
	for i, on in enumerate(list(v) + [False]):
		if on and start is None: start = i
		if not on and start is not None: r.append((start, i)); start = None
	return [x for x in r if x[1] - x[0] > 3]
def measure(path, span, vspan, items):
	# Above the hotbar and the hand; by which channel leads, since a box's
	# colour is drawn blended
	a = np.asarray(Image.open(path).convert("RGB")).astype(int)
	a = a[:int(a.shape[0] * 0.8)]
	r, g, b = a[..., 0], a[..., 1], a[..., 2]
	# The first red block and the last green one: an item's picture may
	# carry either colour
	def block(m, i):
		xs = runs(m.any(axis=0))
		if not xs:
			return None
		x0, x1 = xs[i]
		y0, y1 = runs(m[:, x0:x1].any(axis=1))[i]
		return (x0, y0, x1, y1)
	red = block((r > 120) & (g < 70) & (b < 90), 0)
	green = block((g > 130) & (r < 60) & (b < 60), -1)
	blue = rect((b > 140) & (r < 80) & (g < 80))
	mag = (r > 200) & (g < 60) & (b > 200)
	if not red or not green:
		return None
	ux, uy = (green[0] - red[0]) / span, (green[1] - red[1]) / vspan
	f = lambda q: [(q[0] - red[0]) / ux, (q[1] - red[1]) / uy,
			(q[2] - q[0]) / ux, (q[3] - q[1]) / uy]
	m = {"red": f(red)}
	if blue:
		m["blue"] = f(blue)
	xr, yr = runs(mag.any(axis=0)), runs(mag.any(axis=1))
	if not items:
		m["slots"] = [len(xr)]
	if xr and yr and not items:
		m["slot 1"] = f((xr[0][0], yr[0][0], xr[0][1], yr[0][1]))
		m["slot 8"] = f((xr[-1][0], yr[0][0], xr[-1][1], yr[0][1]))
	if items:
		# [UI_PARITY] 3 to 5, in units from each slot's drawn corner (its
		# magenta about where the form puts it): the picture's extent, the
		# count's white, the wear bar's colour and black
		def inslot(i, q):
			px, py = red[0] + (0.375 + 1.25 * i) * ux, red[1] + uy
			x0, y0 = int(px - 0.1 * ux), int(py - 0.1 * uy)
			x0, y0, x1, y1 = rect(mag[y0:int(py + 1.1 * uy),
					x0:int(px + 1.1 * ux)]) + np.array([x0, y0, x0, y0])
			if q is bar:
				# its bottom quarter, below the pickaxe's dark lines
				y0 = y1 - (y1 - y0) // 4
			r = rect(q[y0:y1, x0:x1])
			return r and [r[0] / ux, r[1] / uy, r[2] / ux, r[3] / uy]
		white = (r > 215) & (g > 215) & (b > 215)
		bar = ((r > 200) & (g > 120) & (b < 60)) | ((r < 30) & (g < 30) & (b < 30))
		m["node picture"] = inslot(0, ~mag)
		m["count 1"] = [0 if inslot(0, white) is None else 1]
		# its right, top and bottom: the font's face and width are the
		# engine's own
		m["count 5"] = [inslot(1, white)[i] for i in (2, 1, 3)]
		m["count 99"] = [inslot(2, white)[i] for i in (2, 1, 3)]
		m["wear bar"] = inslot(3, bar)
		m["flat picture"] = inslot(4, ~mag)
	return m
bad = 0
for form, span, vspan in (("legacy", 7, 5), ("real", 9.75, 6.5),
		("items", 9.75, 2)):
	o = measure("%s/official_%s.png" % (out, form), span, vspan, form == "items")
	b = measure("%s/buildat_%s.png" % (out, form), span, vspan, form == "items")
	if not o or not b:
		print("FAIL: %s: nothing measured in %s" % (form,
				"official's" if not o else "buildat's"))
		bad += 1
		continue
	for k in o:
		ok = o[k] and b.get(k) and len(b[k]) == len(o[k]) and all(abs(x - y) <= 0.03
				for x, y in zip(o[k], b[k]))
		bad += 0 if ok else 1
		print("%s %-7s official %s buildat %s%s" % (form, k,
				" ".join("%.3f" % x for x in (o[k] or [])),
				" ".join("%.3f" % x for x in (b.get(k) or [])), "" if ok else "  <-- differs"))
print("PASS: both coordinate systems, the slot pitch and the stacks as official's" if not bad
		else "FAIL: %d differ" % bad)
sys.exit(1 if bad else 0)
PY
