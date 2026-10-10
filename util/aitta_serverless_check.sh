#!/bin/bash
# tier: full
# cost: ~30 s (2026-10-10)
# covers: apps/aitta/main/main.cpp src/client/main.cpp
# [AITTA_SERVERLESS] [AITTA_LUA51]: a local Aitta with play_url set.
#   1. A "serverless": true release with a goto in its client_lua, and one
#      with a \x escape, are refused with the file and line.
#   2. The goto in a release that is not serverless: listed, with a
#      warning naming the file and line.
#   3. A clean serverless release is listed; the list's ?serverless=1
#      has it and not the other.
#   4. The list page: its box says "runs in the browser" and links
#      <play_url>/#run=tester/sl, the other's neither; its package page
#      links it under the heading and under Install.
#
#   util/aitta_serverless_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp aitta_serverless; t=$CHECK_TMP
b="$here/Build/bin/buildat"
trap check_cleanup EXIT

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'delay 8000\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0,\"play_url\":\"https://play.example/\"}}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"

# publish <name> <version> <serverless> <extra client_lua line>
publish(){
	rm -rf "$t/app"; mkdir -p "$t/app"
	cp -r ../apps/minigame/main ../apps/minigame/launcher "$t/app/"
	printf 'local a = 1\n%s\n' "$4" > "$t/app/main/client_lua/extra.lua"
	printf '{"author": "tester", "name": "%s", "version": "%s", "serverless": %s,
		"engine_api": 1, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a serverless check"}\n' "$1" "$2" "$3" > "$t/app/meta.json"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1 $2"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/pub.out" 2>&1
}

# 1.
publish sl 1.0.0 true 'goto x'
grep -q "main/client_lua/extra.lua:2:" "$t/pub.out" && ! grep -q "listed:" "$t/pub.out" ||
	fail "goto in a serverless release: $(cat "$t/pub.out")"
publish sl 1.0.0 true 'local s = "\x41"'
grep -q "main/client_lua/extra.lua:2: \\\\x is LuaJIT's escape" "$t/pub.out" &&
	! grep -q "listed:" "$t/pub.out" ||
	fail "\\x in a serverless release: $(cat "$t/pub.out")"
echo "ok: a serverless release that the web cannot load is refused"

# 2.
publish other 1.0.0 false 'goto x'
grep -q "listed: tester/other/1.0.0" "$t/pub.out" &&
	grep -q "^warning: " "$t/pub.out" &&
	grep -q "^main/client_lua/extra.lua:2:" "$t/pub.out" ||
	fail "goto in a release with a server: $(cat "$t/pub.out")"
echo "ok: in one with a server, listed with a warning"

# 3.
publish sl 1.0.0 true '-- clean'
grep -q "listed: tester/sl/1.0.0" "$t/pub.out" && ! grep -q warning "$t/pub.out" ||
	fail "a clean serverless release: $(cat "$t/pub.out")"
curl -s "http://127.0.0.1:$P/api/aitta/list?serverless=1" > "$t/list"
grep -q '"name": *"sl"' "$t/list" && ! grep -q '"name": *"other"' "$t/list" ||
	fail "?serverless=1: $(cat "$t/list")"
echo "ok: listed; ?serverless=1 has it alone"

# 4.
curl -s "http://127.0.0.1:$P/" > "$t/front"
python3 - "$t/front" <<'EOF' || fail "the list page ($t/front)"
import sys
s = open(sys.argv[1]).read()
boxes = {b.split("</a>")[0].split(">")[-1]: b for b in s.split('<div class="box">')[1:]}
sl, other = boxes["tester/sl"], boxes["tester/other"]
link = 'href="https://play.example/#run=tester/sl">Play in the browser</a>'
assert "runs in the browser" in sl and link in sl, sl
assert "runs in the browser" not in other and "Play in the browser" not in other, other
EOF
curl -s "http://127.0.0.1:$P/p/tester/sl" > "$t/page"
python3 - "$t/page" <<'EOF' || fail "the package page ($t/page)"
import sys
s = open(sys.argv[1]).read()
link = 'href="https://play.example/#run=tester/sl">Play in the browser</a>'
h, i = s.index("</h1>"), s.index("<h2>Install</h2>")
assert s.find(link, h) < s.index('<div class="box">'), "not under the heading"
assert s.find(link, i) < s.index("<details>", i), "not first under Install"
EOF
curl -s "http://127.0.0.1:$P/p/tester/other" | grep -q "Play in the browser" &&
	fail "a link on the package with a server"
echo "ok: the pages' links"
echo "PASS"
