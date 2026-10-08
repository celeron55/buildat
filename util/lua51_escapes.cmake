# [LUA51_ESCAPES] The string escapes LuaJIT reads and Lua 5.1 (the web
# build's) reads as the letter after the backslash: \u{XXXX}, \xXX and \z.
# A file with one fails the build at its line.
#   cmake -DFILES="a.lua|b.lua" -P util/lua51_escapes.cmake
# simplified: by text, not by the lexer: a long string or a comment with
# such text is refused too
set(BAD "\\\\(u{|x[0-9a-fA-F]|z)")
set(found 0)
string(REPLACE "|" ";" FILES "${FILES}")
foreach(f ${FILES})
	file(READ "${f}" text)
	# A pair of backslashes is one escaped backslash: what is left is a
	# backslash that starts an escape
	string(REPLACE "\\\\" "__" text "${text}")
	if(NOT text MATCHES "${BAD}")
		continue()
	endif()
	# Lines as a list: the list's own separators and brackets out first
	string(REPLACE ";" "_" text "${text}")
	string(REPLACE "[" "_" text "${text}")
	string(REPLACE "]" "_" text "${text}")
	string(REPLACE "\n" ";" lines "${text}")
	set(n 0)
	foreach(line IN LISTS lines)
		math(EXPR n "${n} + 1")
		if(line MATCHES "${BAD}")
			message("${f}:${n}: \\${CMAKE_MATCH_1}... is LuaJIT's escape; "
				"Lua 5.1 (the web client) reads it as the letter. Write the "
				"UTF-8 character itself, or decimal byte escapes (\"\\226\\172\\159\")")
			set(found 1)
		endif()
	endforeach()
endforeach()
if(found)
	message(FATAL_ERROR "LuaJIT-only string escapes in client-side Lua")
endif()
