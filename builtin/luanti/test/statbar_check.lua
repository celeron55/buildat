-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [UI_PARITY] 10: a statbar's icons as Luanti's drawStatbar() places them --
-- the background only over what the value leaves of the maximum, a half
-- icon's other half beside it.
--
--   luajit builtin/luanti/test/statbar_check.lua
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local M = dofile(here .. "/../../../extensions/luanti_client/res/hud.lua")
local function run(n, item, dir)
	local e = {size = {0, 0}, dir = dir, pos = {0, 0}, align = {0, 0},
			offset = {0, 0}, number = n, item = item}
	local t = {}
	for _, i in ipairs(M.statbar_icons(e, 100, 100, 10, 10, true)) do
		t[#t + 1] = string.format("%s%g,%g %gx%g [%g,%g,%g,%g]",
				i.bg and "bg " or "", i.x, i.y, i.w, i.h,
				i.src[1], i.src[2], i.src[3], i.src[4])
	end
	return table.concat(t, "; ")
end
local cases = {
	{3, 6, 0, "0,0 10x10 [0,0,1,1]; 10,0 5x10 [0,0,0.5,1]; " ..
			"bg 15,0 5x10 [0.5,0,1,1]; bg 20,0 10x10 [0,0,1,1]"},
	{4, 7, 0, "0,0 10x10 [0,0,1,1]; 10,0 10x10 [0,0,1,1]; " ..
			"bg 20,0 10x10 [0,0,1,1]; bg 30,0 5x10 [0,0,0.5,1]"},
	{3, 6, 1, "0,0 10x10 [0,0,1,1]; -5,0 5x10 [0.5,0,1,1]; " ..
			"bg -10,0 5x10 [0,0,0.5,1]; bg -20,0 10x10 [0,0,1,1]"},
	{3, 4, 3, "0,0 10x10 [0,0,1,1]; 0,-5 10x5 [0,0.5,1,1]; " ..
			"bg 0,-10 10x5 [0,0,1,0.5]"},
}
for _, c in ipairs(cases) do
	local got = run(c[1], c[2], c[3])
	assert(got == c[4], ("number %d item %d dir %d:\n  got  %s\n  want %s")
			:format(c[1], c[2], c[3], got, c[4]))
end
print("PASS: statbar icons as Luanti's drawStatbar()")
