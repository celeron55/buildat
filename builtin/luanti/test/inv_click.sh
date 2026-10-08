#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [INV_CLICK_PARITY]: the inventory's clicks as official Luanti's, in both
# clients, on VoxeLibre's survival inventory with ten trees in the first
# hotbar slot. The client clicks: the trees picked up (the source drawn
# empty), put in main 10; half of them picked with the right button (the
# source drawn with what is left), one put with the right button, the
# rest put; the five left put in the craft grid; the preview clicked
# twice (crafted, held, crafted onto) and the result put in main 13; the
# preview clicked once more and the inventory closed with Escape, which
# VoxeLibre answers by moving the grid and the held result into the
# inventory. The fixture logs the server's inventory each time it
# changes, which is what is asserted; what was drawn is in the shots, one
# a step, in local/inv_click/<client>/. Needs the Luanti checkout and its server
# binary for luanti_client, as vl_inv.sh does.
#
#   builtin/luanti/test/inv_click.sh [vanilla|ext]   (both by default)
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/inv_click"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti}
which=${1:-both}
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a client or a server is already running"; exit 77
fi
fixture='core.settings:set("creative_mode", "false")
core.settings:set("enable_damage", "false")
local function stacks(inv, list)
	local out = {}
	for i, s in ipairs(inv:get_list(list) or {}) do
		if not s:is_empty() then
			out[#out + 1] = list .. i .. "=" .. s:get_name():gsub(".*:", "") ..
					"x" .. s:get_count()
		end
	end
	return table.concat(out, " ")
end
-- The player inventory each time it changes: the clicks come from the
-- client, and the server answers them with this line
local last, wait = nil, 0
core.register_globalstep(function(dtime)
	wait = wait - dtime
	if wait > 0 then return end
	wait = 0.2
	for _, player in ipairs(core.get_connected_players()) do
		local inv = player:get_inventory()
		local now = stacks(inv, "main") .. " | " .. stacks(inv, "craft") ..
				" | " .. stacks(inv, "craftresult")
		if now ~= last then
			last = now
			core.log("action", "inv_click state: " .. now)
		end
	end
end)
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.set_timeofday(0.5)
	player:get_inventory():add_item("main", "mcl_core:tree 10")
	core.after(8, function()
		core.show_formspec(name, "", player:get_inventory_formspec())
		core.chat_send_player(name, "inv_click: open")
	end)
end)'
# The slots' centres at 1280x720, the same in both clients (vl_inv.sh)
main1="400 579"; main10="400 389"; main11="460 389"; main12="520 389"
main13="580 389"; craft1="700 164"; preview="880 194"
# step: name, then "button x y" clicks separated by ";"
steps=(
	"pick:left $main1"
	"put:left $main10"
	"half:right $main10"
	"one:right $main11"
	"rest:left $main12"
	"grid:left $main10;left $craft1"
	"craft:left $preview"
	"more:left $preview"
	"place:left $main13"
	"held:left $preview"
)
cmds(){ # out-dir
	local s n cs c i=0
	echo "wait_log 240000 chat: inv_click: open"; echo "delay 2000"
	for s in "${steps[@]}"; do
		i=$((i + 1)); n=${s%%:*}
		IFS=';' read -ra cs <<< "${s#*:}"
		for c in "${cs[@]}"; do
			echo "mouse_pos ${c#* }"; echo "delay 300"
			echo "mouse_click ${c%% *}"; echo "delay 1200"
		done
		# Off the slots, so the shot sees the hand and not a tooltip
		echo "mouse_pos 1000 600"; echo "delay 600"
		echo "screenshot $1/s${i}_$n.png"
		echo "event scan"; echo "delay 800"
	done
	echo "keypress Escape"; echo "delay 2000"
	echo quit
}
# What the server holds, in order, after the steps that change it:
# Luanti's answer to the same clicks. A pick changes nothing there. On
# Escape VoxeLibre moves the grid and the held result into the inventory,
# onto matching stacks first.
want="main1=treex10 |  | 
main10=treex10 |  | 
main10=treex9 main11=treex1 |  | 
main10=treex5 main11=treex1 main12=treex4 |  | 
main11=treex1 main12=treex4 | craft1=treex5 | 
main11=treex1 main12=treex4 | craft1=treex4 | craftresult1=woodx4
main11=treex1 main12=treex4 | craft1=treex3 | craftresult1=woodx8
main11=treex1 main12=treex4 main13=woodx8 | craft1=treex3 | 
main11=treex1 main12=treex4 main13=woodx8 | craft1=treex2 | craftresult1=woodx4
main11=treex3 main12=treex4 main13=woodx12 |  | "
check(){ # client server-log
	local got
	got=$(grep -a "inv_click state: " "$2" | sed 's/.*inv_click state: //')
	if [ "$got" != "$want" ]; then
		failed+=("$1: the server's inventory went")
		diff <(echo "$want") <(echo "$got") | sed "s/^/  $1 /"
	fi
}
failed=()

run_vanilla(){
	local o="$out/vanilla" save=buildat_test_inv_click
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
	timeout 240 bin/buildat -s localhost:29797 -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1
	kill -INT "$srv" 2>/dev/null
	for _i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
	check vanilla "$o/srv.log"
}

run_ext(){
	local o="$out/ext" work="$out/ext/world" port=30033
	[ -x "$bin" ] || { echo "SKIP: no Luanti server at $bin"; exit 77; }
	rm -rf "$o"; mkdir -p "$work/worldmods/inv_click"
	printf 'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nworld_name = inv_click\ncreative_mode = false\nenable_damage = false\nserver_announce = false\n' \
		> "$work/world.mt"
	printf '%s\n' "$fixture" > "$work/worldmods/inv_click/init.lua"
	printf 'name = inv_click\n' > "$work/worldmods/inv_click/mod.conf"
	printf 'fixed_map_seed = 1\nenable_damage = false\nmute_sound = true\n' \
		> "$o/luanti.conf"
	check_allow "udp://127.0.0.1:$port"
	( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
		--config "$o/luanti.conf" > "$o/luanti_srv.log" 2>&1 ) &
	local srv=$!
	for _i in $(seq 1 300); do
		grep -q "Server for gameid" "$o/luanti_srv.log" 2>/dev/null && break
		sleep 1
	done
	sleep 3
	cmds "$o" > "$o/cmds.txt"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ic \
		BUILDAT_LUANTI_CONNECT=1 timeout 240 \
		"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1
	kill "$srv" 2>/dev/null
	for _i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
	check ext "$o/luanti_srv.log"
}

[ "$which" = ext ] || run_vanilla
[ "$which" = vanilla ] || run_ext
for f in "${failed[@]}"; do echo "FAIL: $f"; done
[ ${#failed[@]} = 0 ] && echo "inv_click: ok"
