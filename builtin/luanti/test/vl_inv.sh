#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [VL_INV_PARITY]: VoxeLibre's survival inventory and the forms it opens,
# in both clients, beside official Luanti's own
# (local/luanti_inventory_reference/, the user's): the inventory, the
# recipe book, help, the achievements and their second entry. A fixture
# shows each form as its button would -- the inventory as the inventory
# key's form -- six seconds apart, and the client shoots each. The shots
# land in local/vl_inv/<client>/, each beside its reference in
# local/vl_inv/side_<n>.png (reference left, vanilla, luanti_client);
# what to compare is the eye's, so this asserts only that every form
# was shot. Needs the Luanti checkout and its server binary for
# luanti_client, as ext_hotbar.sh does.
#
#   builtin/luanti/test/vl_inv.sh [vanilla|ext]   (both by default)
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/vl_inv"; mkdir -p "$out"
ref="$here/local/luanti_inventory_reference"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
which=${1:-both}
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null ||
		pgrep -x luanti-refshots >/dev/null; then
	echo "SKIP: a client or a server is already running"; exit 77
fi
fixture='core.settings:set("creative_mode", "false")
core.settings:set("enable_damage", "false")
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.set_timeofday(0.5)
	player:get_inventory():add_item("main", "mcl_core:tree")
	local steps = {
		function() core.show_formspec(name, "",
				player:get_inventory_formspec()) end,
		function() mcl_craftguide.show(name) end,
		function() doc.show_doc(name) end,
		function() awards.show_to(name, name, 1, false) end,
		function() awards.show_to(name, name, 2, false) end,
		function() core.close_formspec(name, "") end,
	}
	for i, f in ipairs(steps) do
		core.after(10 + 6 * (i - 1), function()
			f()
			core.chat_send_player(name, "vl_inv: step " .. i)
		end)
	end
end)'
# The client shoots two seconds into each step, which the fixture says in
# chat: neither the server's timers nor a client's join line keep time
# with the other end
cmds(){ # out-dir
	for i in 1 2 3 4 5; do
		echo "wait_log 240000 chat: vl_inv: step $i"
		echo "delay 2000"; echo "screenshot $1/s$i.png"
	done
	echo quit
}

run_vanilla(){
	local o="$out/vanilla" save=buildat_test_vl_inv
	rm -rf "$o"; mkdir -p "$o"
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
	printf '%s\n' "$fixture" > "$o/fixture.lua"
	cd "$here/Build"
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$o/fixture.lua" \
		start_server "$o/srv.log" "Mods loaded" 400 29797 \
		bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
		{ echo "FAIL: the server did not start"; exit 1; }
	local srv=$SERVER_PID
	cmds "$o" > "$o/cmds.txt"
	timeout 180 bin/buildat -s localhost:29797 -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1
	kill -INT "$srv" 2>/dev/null
	for _i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
}

run_ext(){
	local o="$out/ext" work="$out/ext/world" port=30031
	[ -x "$bin" ] || { echo "SKIP: no Luanti server at $bin"; exit 77; }
	rm -rf "$o"; mkdir -p "$work/worldmods/vl_inv"
	printf 'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nworld_name = vl_inv\ncreative_mode = false\nenable_damage = false\nserver_announce = false\n' \
		> "$work/world.mt"
	printf '%s\n' "$fixture" > "$work/worldmods/vl_inv/init.lua"
	printf 'name = vl_inv\n' > "$work/worldmods/vl_inv/mod.conf"
	printf 'fixed_map_seed = 1\nenable_damage = false\nmute_sound = true\n' \
		> "$o/luanti.conf"
	check_allow "udp://127.0.0.1:$port"
	( cd "$luanti" && "$bin" --server --world "$work" --port "$port" \
		--config "$o/luanti.conf" > "$o/luanti_srv.log" 2>&1 ) &
	for _i in $(seq 1 300); do
		grep -q "Server for gameid" "$o/luanti_srv.log" 2>/dev/null && break
		sleep 1
	done
	sleep 3
	local srv
	srv=$(pgrep -x luanti-refshots | head -1)
	[ -n "$srv" ] || { echo "FAIL: the Luanti server did not come up"; exit 1; }
	cmds "$o" > "$o/cmds.txt"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=vi \
		BUILDAT_LUANTI_CONNECT=1 timeout 240 \
		"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1
	kill "$srv" 2>/dev/null
	for _i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
}

[ "$which" = ext ] || run_vanilla
[ "$which" = vanilla ] || run_ext
python3 - "$out" "$ref" <<'PY'
import os, sys
from PIL import Image
out, ref = sys.argv[1], sys.argv[2]
missing = []
for n in range(1, 6):
    row = [Image.open("%s/screenshot_%d.png" % (ref, n)).convert("RGB")
            .resize((1280, 720))]
    for c in ("vanilla", "ext"):
        p = "%s/%s/s%d.png" % (out, c, n)
        if os.path.exists(p):
            row.append(Image.open(p).convert("RGB").resize((1280, 720)))
        elif os.path.isdir("%s/%s" % (out, c)):
            missing.append(p)
    side = Image.new("RGB", (1280 * len(row), 720))
    for i, im in enumerate(row):
        side.paste(im, (1280 * i, 0))
    side.save("%s/side_%d.png" % (out, n))
if missing:
    print("FAIL: not shot: " + ", ".join(missing))
    sys.exit(1)
print("PASS: the five forms shot, beside the reference in " + out)
PY
