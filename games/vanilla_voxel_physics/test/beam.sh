#!/bin/bash
# [VOXEL_PHYSICS_SAMPLE]: a beam of dirt on one pillar, the pillar's top
# dug by the client -- the beam comes off as one body and falls. The
# server's body line and where the body node ends up are the reading;
# the log is under local/voxel_physics/.
#
#   GAME=mineclone2 games/vanilla_voxel_physics/test/beam.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
GAME="${GAME:-mineclone2}"
out="$here/local/voxel_physics"
mkdir -p "$out"
save="buildat_test_beam"
cd "$here/Build"
if pgrep -x buildat_server >/dev/null || pgrep -x buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "../user/games/vanilla_voxel_physics/saves/$save"
cat > "$out/fixture.lua" <<'LUA'
-- At the supported floor (y <= -60 holds by rule), so the platform stands
local ORIGIN = {x = 0, y = -61, z = 0}
core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
local function node_named(word)
	local found = {}
	for name, def in pairs(core.registered_nodes) do
		if name:find(word, 1, true) and not name:find("with", 1, true)
				and def.drawtype == "normal" then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found[1]
end
local dirt = nil
core.register_on_mods_loaded(function()
	dirt = node_named("dirt")
end)
core.register_on_joinplayer(function(player)
	local air = core.get_content_id("air")
	local cid = core.get_content_id(dirt)
	local p1 = vector.subtract(ORIGIN, 6)
	local p2 = vector.add(ORIGIN, 8)
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do
		data[i] = air
	end
	-- The platform, the pillar at (2, *, 2) and the beam over it
	for x = -4, 6 do
		for z = -4, 6 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	for y = 1, 3 do
		data[area:index(ORIGIN.x + 2, ORIGIN.y + y, ORIGIN.z + 2)] = cid
	end
	for x = -1, 5 do
		data[area:index(ORIGIN.x + x, ORIGIN.y + 4, ORIGIN.z + 2)] = cid
	end
	vm:set_data(data)
	vm:write_to_map()
	player:set_pos({x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z})
	core.log("action", "beam: stamped with " .. dirt)
end)
core.register_on_dignode(function(pos, node, digger)
	core.log("action", "beam: dug " .. node.name .. " at " ..
			core.pos_to_string(pos))
end)
LUA
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -m ../games/vanilla_voxel_physics -D ../user -P 29780 \
	-l "${LOG_LEVEL:-4}" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/srv.log" &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(pgrep -x buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
delay 20000
look_dir 2 0.5 2
delay 300
event scan_volume 6 t0
mouse_down left
delay 2000
mouse_up left
delay 8000
event scan_volume 6 after
screenshot $out/after.png
look_dir -1 -0.1 -0.3
delay 1000
screenshot $out/body.png
delay 500
quit
CMDS
bin/buildat -s localhost:29780 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" 2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/cli.log"
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "beam:\|voxel_ph" "$out/srv.log" | grep -v "sim: " | sed 's/.*I [a-z_]* *: //' | tail -12
grep "body\|voxel_physics" "$out/cli.log" | sed 's/.*I [a-z_]* *: //' | tail -5
