-- Buildat: builtin/luanti/lua/translations.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What a game ships in locale/*.tr, read for the one language in force.
--
-- Luanti marks a translatable string where it is written -- core.translate()
-- wraps it in \27(T@domain) ... \27(E) -- and the marker travels in every
-- string that reaches a client: chat, an item's description, a HUD line, a
-- formspec. **The lookup belongs at the far end**, because in Luanti two
-- players can be reading different languages, so this side reads the files
-- and hands them over and the client's own strip site does the rest.
--
-- simplified: one language for the whole server, from core.settings' own
-- "language" or the environment, where Luanti asks each client. A client
-- language preference is what would change that, and it would change this
-- file by one packet field. And no plural forms: Luanti's \27(T@d@n) carries
-- a number for languages with several, and a .tr file can hold one entry per
-- form; what is here takes the singular. VoxeLibre's 1828 files use none.

-- What a .tr file escapes, which is Luanti's own rule: "@=" is an equals
-- sign and "@n" is a newline, and **every other @x is left alone** -- "@1"
-- and the rest are the argument placeholders and have to survive.
local function unescape(s)
	local out = {}
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "@" and i < #s then
			local n = s:sub(i + 1, i + 1)
			if n == "=" then
				out[#out + 1] = "="
			elseif n == "n" then
				out[#out + 1] = "\n"
			else
				out[#out + 1] = "@" .. n
			end
			i = i + 2
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- Where the key ends: the first "=" that is not escaped
local function split_at_equals(line)
	local i = 1
	while i <= #line do
		local c = line:sub(i, i)
		if c == "@" then
			i = i + 2
		elseif c == "=" then
			return line:sub(1, i - 1), line:sub(i + 1)
		else
			i = i + 1
		end
	end
	return nil
end

-- One file's worth, into out[domain][key] = value. The domain is the
-- file's own "# textdomain:" line, because that is what the marker in a
-- string names; the file name is only a fallback for a file that forgot.
local function read_tr(out, data, fallback_domain)
	local domain = fallback_domain
	local n = 0
	for line in (data .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		local named = line:match("^#%s*textdomain:%s*(.-)%s*$")
		if named then
			domain = named
		elseif line ~= "" and line:sub(1, 1) ~= "#" then
			local key, value = split_at_equals(line)
			if key then
				out[domain] = out[domain] or {}
				out[domain][unescape(key)] = unescape(value)
				n = n + 1
			end
		end
	end
	return n
end

-- Which language, most specific first: "fi_FI" before "fi". Luanti asks the
-- client; this asks the settings and then the environment the server was
-- started in, which on a launcher's own world is the same person.
-- Languages whose scripts the shipped fonts have no glyphs for
local UNDRAWABLE = {zh = true, ja = true, ko = true, ar = true, he = true,
		th = true, el = true, hi = true, ka = true, hy = true, fa = true,
		ur = true, bn = true, ta = true, my = true, km = true, lo = true}

local function languages()
	local want = core.settings:get("language")
	if want == nil or want == "" then
		want = (os and os.getenv and os.getenv("LANG")) or ""
	end
	-- "fi_FI.UTF-8" is a locale name and "fi_FI" is what a file is called
	want = tostring(want):gsub("[.@].*$", "")
	if want == "" or want == "C" or want == "POSIX" then
		return {}
	end
	-- Prefer English over a language the client's fonts cannot draw: a
	-- mod translated into missing glyphs is worse off than one left
	-- alone. The fonts shipped cover Latin-1, Latin Extended and
	-- Cyrillic and nothing else, so these scripts render as nothing;
	-- see [TRANSLATION_FONT] in doc/plan/master_plan.md, which is where
	-- widening the font would lift this.
	local short0 = want:match("^(%a+)") or want
	if UNDRAWABLE[short0:lower()] then
		core.log("action", "translations: " .. want .. " is asked for and " ..
				"the client's fonts have no glyphs for it; English instead")
		return {}
	end
	local out = {want}
	local short = want:match("^(%a+)")
	if short and short ~= want then
		out[#out + 1] = short
	end
	return out
end

-- Every locale directory a game has: its own and one per mod
local function locale_dirs()
	local out = {core.get_game_info().path .. "/locale"}
	for _, name in ipairs(core.get_modnames() or {}) do
		local path = core.get_modpath(name)
		if path then
			out[#out + 1] = path .. "/locale"
		end
	end
	return out
end

-- core.__translations() -> {domain, key, value, domain, key, value, ...}
--
-- Flat because that is what the packet is, and because a game's whole
-- translation for one language is a few thousand strings at most -- the
-- files for every other language are never read.
function core.__translations()
	local langs = languages()
	if #langs == 0 then
		return {}
	end
	local by_domain = {}
	local files, entries = 0, 0
	for _, dir in ipairs(locale_dirs()) do
		for _, file in ipairs(core.get_dir_list(dir, false) or {}) do
			-- <anything>.<language>.tr, and the language has to be one of
			-- the ones asked for
			local stem, lang = file:match("^(.*)%.([%w_]+)%.tr$")
			if stem then
				for _, want in ipairs(langs) do
					if lang == want then
						local data = core.__read_file(dir .. "/" .. file)
						if data then
							entries = entries + read_tr(by_domain, data, stem)
							files = files + 1
						end
						break
					end
				end
			end
		end
	end
	local flat = {}
	for domain, strings in pairs(by_domain) do
		for key, value in pairs(strings) do
			flat[#flat + 1] = domain
			flat[#flat + 1] = key
			flat[#flat + 1] = value
		end
	end
	core.log("action", "translations: " .. entries .. " strings in " ..
			files .. " files for " .. table.concat(langs, ", "))
	return flat
end

do
	-- The escapes, which are the part of a .tr file that is easy to get
	-- wrong: an equals sign and a newline are written with an @, and every
	-- other @ is an argument placeholder that has to come out untouched.
	assert(unescape("a@=b") == "a=b", "tr: @= is an equals sign")
	assert(unescape("a@nb") == "a\nb", "tr: @n is a newline")
	assert(unescape("@1 Wool") == "@1 Wool", "tr: @1 is a placeholder")
	assert(unescape("end@") == "end@", "tr: a trailing @ is itself")

	local key, value = split_at_equals("Stone=Kivi")
	assert(key == "Stone" and value == "Kivi", "tr: the first equals splits")
	key, value = split_at_equals("a@=b=c")
	assert(key == "a@=b" and value == "c", "tr: an escaped equals does not")
	assert(split_at_equals("no equals here") == nil,
			"tr: a line without one is not a translation")

	local out = {}
	local n = read_tr(out, "# textdomain: mymod\n# a comment\n\n" ..
			"Stone=Kivi\n@1 Wool=@1 villaa\n", "wrong")
	assert(n == 2 and out.mymod, "tr: the header names the domain")
	assert(out.mymod["Stone"] == "Kivi" and
			out.mymod["@1 Wool"] == "@1 villaa", "tr: the strings")
	assert(out.wrong == nil, "tr: the file name is only a fallback")
end
-- vim: set noet ts=4 sw=4:
