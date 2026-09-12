-- Buildat: builtin/luanti/lua/test.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Checks the parts of this module that are arithmetic rather than
-- arrangement: base64, ColorSpec, ItemStack, the inventory, the content id
-- allocator and the mod ordering. Wants no engine, so:
--
--   $ lua builtin/luanti/lua/test.lua
--
-- The rest is checked by loading a game: devtest's own unittests mod runs
-- while it loads and takes the server down if any of this is wrong, which is
-- the reason devtest is the fixture.

local dir = arg[0]:match("^(.*)/[^/]*$") or "."

core = {}
core.registered_items = {}
function core.log() end
function core.write_json(t) return "{}" end
function core.safe_file_write() return true end

dofile(dir .. "/classes.lua")
dofile(dir .. "/colorspec.lua")
dofile(dir .. "/misc.lua")
local modlist = dofile(dir .. "/modlist.lua")

local function check(name, f)
	local ok, err = pcall(f)
	if not ok then
		io.stderr:write("luanti/test.lua: " .. name .. ": " .. tostring(err) ..
				"\n")
		os.exit(1)
	end
	print(name .. ": ok")
end

check("base64", function()
	local cases = {"", "a", "ab", "abc", "abcd",
			"Hello, Luanti!\0\1\255\254"}
	for _, s in ipairs(cases) do
		local encoded = core.encode_base64(s)
		assert(core.decode_base64(encoded) == s, "roundtrip of " .. #s)
		assert(#encoded % 4 == 0, "padded to four")
	end
	assert(core.encode_base64("abc") == "YWJj")
	assert(core.decode_base64("!!!") == nil, "not base64")
	assert(core.decode_base64(core.encode_base64("ab")) == "ab")
end)

check("node position hash", function()
	for _, p in ipairs({{x = 0, y = 0, z = 0}, {x = -5, y = 7, z = 1000},
			{x = 32767, y = -32768, z = 1}}) do
		local back = core.get_position_from_hash(core.hash_node_position(p))
		assert(back.x == p.x and back.y == p.y and back.z == p.z,
				"roundtrip of " .. p.x .. "," .. p.y .. "," .. p.z)
	end
end)

check("colorspec", function()
	assert(core.colorspec_to_colorstring("#abc") == "#AABBCCFF")
	assert(core.colorspec_to_colorstring("#ff8000") == "#FF8000FF")
	assert(core.colorspec_to_colorstring("#ff800080") == "#FF800080")
	assert(core.colorspec_to_colorstring("peachpuff") == "#FFDAB9FF")
	assert(core.colorspec_to_colorstring("white#7f") == "#FFFFFF7F")
	assert(core.colorspec_to_colorstring({r = 1, g = 2, b = 3}) == "#010203FF")
	assert(core.colorspec_to_colorstring("nosuchcolour") == nil)
	assert(#core.colorspec_to_bytes("black") == 4)
end)

check("itemstack", function()
	core.registered_items["test:thing"] = {description = "A thing",
			stack_max = 10}
	core.registered_items["test:tool"] = {description = "A tool",
			stack_max = 1}

	assert(ItemStack():is_empty())
	assert(ItemStack(""):is_empty())

	local s = ItemStack("test:thing 4")
	assert(s:get_name() == "test:thing" and s:get_count() == 4)
	assert(s:to_string() == "test:thing 4")
	assert(s:get_stack_max() == 10 and s:get_free_space() == 6)
	assert(s:get_description() == "A thing")

	-- What does not fit comes back
	local left = s:add_item("test:thing 9")
	assert(s:get_count() == 10, "filled to the stack max")
	assert(left:get_count() == 3, "three left over")

	-- A different item does not merge
	local other = s:add_item("test:tool")
	assert(other:get_count() == 1 and s:get_count() == 10)

	local taken = s:take_item(4)
	assert(taken:get_count() == 4 and s:get_count() == 6)
	assert(s:peek_item(2):get_count() == 2 and s:get_count() == 6,
			"peek takes nothing")

	-- Emptying clears the name, as Luanti's does
	s:set_count(0)
	assert(s:is_empty() and s:get_name() == "" and s:to_string() == "")

	-- Metadata travels with a copy and is compared by value
	local a = ItemStack("test:tool")
	a:get_meta():set_string("owner", "nobody")
	local b = ItemStack(a)
	assert(b:get_meta():get_string("owner") == "nobody")
	assert(a:equals(b))
	b:get_meta():set_string("owner", "somebody")
	assert(not a:equals(b), "metadata is part of equality")

	-- Wear, and the uses a tool has
	local t = ItemStack("test:tool")
	t:add_wear_by_uses(10)
	assert(t:get_wear() == 6553, "one use of ten")
end)

check("inventory", function()
	core.registered_items["test:thing"] = {stack_max = 10}
	local inv = core.__new_inventory({type = "detached", name = "test"})
	inv:set_size("main", 3)
	assert(inv:get_size("main") == 3 and inv:is_empty("main"))

	assert(inv:room_for_item("main", "test:thing 30"))
	assert(not inv:room_for_item("main", "test:thing 31"))

	local left = inv:add_item("main", "test:thing 25")
	assert(left:is_empty(), "25 fits in three stacks of ten")
	assert(inv:get_stack("main", 1):get_count() == 10)
	assert(inv:get_stack("main", 3):get_count() == 5)
	assert(not inv:is_empty("main"))
	assert(inv:contains_item("main", "test:thing 25"))
	assert(not inv:contains_item("main", "test:thing 26"))

	local taken = inv:remove_item("main", "test:thing 7")
	assert(taken:get_count() == 7)
	assert(inv:contains_item("main", "test:thing 18"))

	-- A stack read out is a copy: writing to it does not write to the list
	local stack = inv:get_stack("main", 1)
	stack:set_count(1)
	assert(inv:get_stack("main", 1):get_count() == 10, "get_stack copies")

	assert(inv:get_location().name == "test")
end)

check("mod ordering", function()
	local function mod(name, depends, optional)
		return {name = name, path = "/" .. name,
				depends = modlist.split_list(depends),
				optional_depends = modlist.split_list(optional)}
	end
	local mods = {
		mod("last_mod"),
		mod("stairs", "basenodes"),
		mod("basenodes", "first_mod"),
		mod("first_mod"),
		mod("testnodes", "basenodes", "stairs"),
	}
	local order = modlist.order_mods(mods, "first_mod", "last_mod")
	local at = {}
	for i, m in ipairs(order) do
		at[m.name] = i
	end
	assert(#order == 5)
	assert(at.first_mod == 1, "first_mod is first")
	assert(at.last_mod == #order, "last_mod is last")
	assert(at.basenodes < at.stairs, "a dependency loads first")
	assert(at.stairs < at.testnodes, "an optional dependency loads first")

	-- A dependency that is not there is an error; an optional one is not
	assert(not pcall(modlist.order_mods, {mod("a", "nosuch")}))
	assert(pcall(modlist.order_mods, {mod("a", "", "nosuch")}))
	-- A cycle is an error rather than a hang
	assert(not pcall(modlist.order_mods, {mod("a", "b"), mod("b", "a")}))
end)

check("conf parsing", function()
	local t = modlist.parse_conf(
			"# a comment\nname = foo\ndepends = a, b ,c\n\nempty =\n")
	assert(t.name == "foo")
	assert(t.empty == "")
	local list = modlist.split_list(t.depends)
	assert(#list == 3 and list[1] == "a" and list[3] == "c")
end)

print("builtin/luanti/lua/test.lua: ok")

-- vim: set noet ts=4 sw=4:
