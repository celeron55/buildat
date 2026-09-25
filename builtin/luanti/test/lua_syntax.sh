#!/bin/bash
# **Every Lua file in the tree parses** -- the cheapest coverage there
# is, and the only thing at all that reads most of them: thirteen games'
# `client_lua` is started by no check ([SMOKE_PICK]'s coverage map,
# 2026-09-25), so a file broken by a bulk edit -- a sed over fifteen
# games, say -- sat there until somebody started that game by hand.
#
#   builtin/luanti/test/lua_syntax.sh
#
# **What it is not**: a check that the code works. It parses, nothing
# more. And it parses with the desk's own Lua, which is 5.4 here while
# the client runs LuaJIT (5.1), so a file using 5.3's `//` or `goto`
# passes this and fails there; what this catches is the broken file, not
# the wrong dialect.
#
# tier: quick
# cost: 3s
# always: yes
#
# **No covers line, and always run.** A shallow check that names half
# the tree would win every "cheapest runner that covers this file" race
# and push the deep ones out ([SMOKE_PICK]'s greedy pick): asked for a
# change under games/, it answered "the syntax check, 3 s" instead of
# the runner that starts the game. So it competes for nothing and runs
# anyway, which is what a check costing under a second is for.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
. "$here/builtin/luanti/test/lib.sh"
cd "$here"
if ! command -v luac >/dev/null 2>&1; then
	echo "SKIP: no luac to parse with" >&2; exit 2
fi
n=0
bad=0
for f in $(git ls-files '*.lua' | grep -v "^3rdparty/"); do
	n=$((n + 1))
	if ! out=$(luac -p "$f" 2>&1); then
		bad=$((bad + 1))
		echo "$out"
	fi
done
echo "$n Lua files in the tree, $bad of them broken"
if [ "$bad" -gt 0 ]; then
	echo "FAIL: a Lua file does not parse"
	exit 1
fi
echo "PASS: every Lua file in the tree parses"
exit 0
# vim: set noet ts=4 sw=4:
