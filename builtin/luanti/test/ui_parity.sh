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
for f in legacy real; do
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
printf "wait_log 90000 the server put the player at\ndelay 6000\nscreenshot $out/buildat_legacy.png\ndelay 8000\nscreenshot $out/buildat_real.png\nquit\n" > "$t/c"
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
def measure(path, span, vspan):
	# Above the hotbar and the hand; by which channel leads, since a box's
	# colour is drawn blended
	a = np.asarray(Image.open(path).convert("RGB")).astype(int)
	a = a[:int(a.shape[0] * 0.8)]
	r, g, b = a[..., 0], a[..., 1], a[..., 2]
	red = rect((r > 120) & (g < 70) & (b < 90))
	green = rect((g > 130) & (r < 60) & (b < 60))
	blue = rect((b > 140) & (r < 80) & (g < 80))
	mag = (r > 200) & (g < 60) & (b > 200)
	if not red or not green or not blue:
		return None
	ux, uy = (green[0] - red[0]) / span, (green[1] - red[1]) / vspan
	f = lambda q: [(q[0] - red[0]) / ux, (q[1] - red[1]) / uy,
			(q[2] - q[0]) / ux, (q[3] - q[1]) / uy]
	m = {"red": f(red), "blue": f(blue)}
	xr, yr = runs(mag.any(axis=0)), runs(mag.any(axis=1))
	m["slots"] = [len(xr)]
	if xr and yr:
		m["slot 1"] = f((xr[0][0], yr[0][0], xr[0][1], yr[0][1]))
		m["slot 8"] = f((xr[-1][0], yr[0][0], xr[-1][1], yr[0][1]))
	return m
bad = 0
for form, span, vspan in (("legacy", 7, 5), ("real", 9.75, 6.5)):
	o = measure("%s/official_%s.png" % (out, form), span, vspan)
	b = measure("%s/buildat_%s.png" % (out, form), span, vspan)
	if not o or not b:
		print("FAIL: %s: nothing measured in %s" % (form,
				"official's" if not o else "buildat's"))
		bad += 1
		continue
	for k in o:
		ok = k in b and len(b[k]) == len(o[k]) and all(abs(x - y) <= 0.03
				for x, y in zip(o[k], b[k]))
		bad += 0 if ok else 1
		print("%s %-7s official %s buildat %s%s" % (form, k,
				" ".join("%.3f" % x for x in o[k]),
				" ".join("%.3f" % x for x in b.get(k, [])), "" if ok else "  <-- differs"))
print("PASS: both coordinate systems and the slot pitch as official's" if not bad
		else "FAIL: %d differ" % bad)
sys.exit(1 if bad else 0)
PY
