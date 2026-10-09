#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-09)
# covers: util/serve_latest_release.sh src/client/main.cpp apps/aitta/main/main.cpp
# [AITTA_SERVE]: a local Aitta with tester/pt (apps/minigame) 1.0.0.
#   1. buildat aitta install by name: the newest, @1.0.0 said installed
#      already, an unknown version refused with the versions listed, an
#      unknown package refused.
#   2. The package's web page has the commands.
#   3. serve_latest_release.sh tester/pt with neither AITTA nor an install:
#      refused with the install command.
#   4. With AITTA, from a release made from this tree: installs and serves
#      it as tester.pt (/health); 1.0.1 published, it is installed,
#      compiled and the server restarted onto it, a save under
#      apps/tester.pt kept.
#   5. Restarted without AITTA, 1.0.2 published: stays on 1.0.1.
#
#   util/aitta_serve_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp aitta_serve; t=$CHECK_TMP
b="$here/Build/bin/buildat"
groups=()
trap 'for g in "${groups[@]}"; do kill -- -"$g" 2>/dev/null; done; check_cleanup' EXIT

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
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
mkdir -p "$t/app"
cp -r ../apps/minigame/main ../apps/minigame/launcher "$t/app/"
publish(){
	printf '{"author": "tester", "name": "pt", "version": "%s",
		"engine_api": 1, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a serve check"}\n' "$1" > "$t/app/meta.json"
	# A change, so that each version's compile is real
	echo "// $1" >> "$t/app/main/main.cpp"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1"
	"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/pt" ||
		fail "publish $1"
	sleep 1 # the list's newest is by time, in seconds
}
publish 1.0.0

# 1. By name
d=$("$b" aitta install 127.0.0.1:$P tester/pt "$t/u0" 2>"$t/err") &&
	[ "$d" = "$t/u0/installed/tester/pt/1.0.0" ] && [ -f "$d/main/main.cpp" ] ||
	fail "install by name: $d $(cat "$t/err")"
ls "$t/u0" | grep -q "^\.aitta" && fail "the download left behind"
d=$("$b" aitta install 127.0.0.1:$P tester/pt@1.0.0 "$t/u0" 2>"$t/err") &&
	grep -q "installed already" "$t/err" || fail "installed again: $(cat "$t/err")"
"$b" aitta install 127.0.0.1:$P tester/pt@2.0 "$t/u0" > /dev/null 2>"$t/err" &&
	fail "an unknown version installed"
grep -q "lists no tester/pt@2.0; its versions of tester/pt: 1.0.0" "$t/err" ||
	fail "an unknown version: $(cat "$t/err")"
"$b" aitta install 127.0.0.1:$P tester/nope "$t/u0" > /dev/null 2>"$t/err" &&
	fail "an unknown package installed"
grep -q "lists no tester/nope" "$t/err" || fail "an unknown package: $(cat "$t/err")"
echo "ok: installed by name, by version, refusals"

# 2. The page
curl -s "http://127.0.0.1:$P/p/tester/pt" > "$t/page"
grep -q "bin/buildat aitta install http://127.0.0.1:$P tester/pt " "$t/page" &&
	grep -q "util/serve_latest_release.sh tester/pt " "$t/page" &&
	grep -q "tester/pt@1.0.0" "$t/page" || fail "the page's commands ($t/page)"
echo "ok: the page's commands"

# A release of this tree, served as GitHub's list would be
HP=$((P + 1)) SP=$((P + 2))
r="$t/rel/buildat-0.0.1-check-linux-x86_64-web-precompiled"
mkdir -p "$r/apps"
for e in 3rdparty Build builtin client extensions src VERSION web util; do
	ln -s "$here/$e" "$r/$e"
done
ln -s Build/bin "$r/bin"
tar -C "$t/rel" -czf "$r.tar.gz" "$(basename "$r")"
echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP/$(basename "$r").tar.gz\"}]" \
	> "$t/rel/releases.json"
setsid python3 -m http.server $HP --bind 127.0.0.1 --directory "$t/rel" \
	> "$t/http.log" 2>&1 &
groups+=($!)
serve=(env BUILDAT_SERVE_DIR="$t/serve" POLL_SECONDS=5 UPDATE_MAX_WAIT=60
	RELEASES_URL="http://127.0.0.1:$HP/releases.json"
	"$here/util/serve_latest_release.sh" tester/pt $SP "$t/u1")
slog="$t/serve/server-tester.pt-$SP.log"

# 3. Neither AITTA nor installed
out=$("${serve[@]}" 2>&1)
[ $? = 2 ] && echo "$out" | grep -q "bin/buildat aitta install <Aitta> tester/pt $t/u1" ||
	fail "not refused: $out"
echo "ok: refused with the install command"

# 4. Following the Aitta
setsid env AITTA=127.0.0.1:$P "${serve[@]}" > "$t/serve.log" 2>&1 &
groups+=($!)
wait_for_log "$slog" "Listening at" 300 || fail "1.0.0 did not start ($t/serve.log)"
curl -s -m 5 "http://127.0.0.1:$SP/health" | grep -q . || fail "no /health"
[ -d "$t/u1/installed/tester/pt/1.0.0" ] || fail "not installed by the script"
echo kept > "$t/u1/apps/tester.pt/save.txt"
echo "ok: installed and serving 1.0.0"
publish 1.0.1
wait_for_log "$t/serve.log" "tester/pt 1.0.1 is ready" 300 ||
	fail "no update to 1.0.1 ($t/serve.log)"
for _i in $(seq 60); do
	[ "$(grep -ac "Listening at" "$slog")" -ge 2 ] && break
	sleep 1
done
[ "$(grep -ac "Listening at" "$slog")" -ge 2 ] || fail "1.0.1 did not start ($slog)"
pgrep -f "installed/tester/pt/1.0.1" > /dev/null || fail "not on 1.0.1"
[ "$(cat "$t/u1/apps/tester.pt/save.txt")" = kept ] || fail "the save lost"
echo "ok: 1.0.1 installed, compiled and restarted onto, the save kept"

# 5. Without AITTA
kill -- -"${groups[-1]}"
unset 'groups[-1]'
sleep 3
setsid "${serve[@]}" > "$t/serve2.log" 2>&1 &
groups+=($!)
for _i in $(seq 120); do
	[ "$(grep -ac "Listening at" "$slog")" -ge 3 ] && break
	sleep 1
done
[ "$(grep -ac "Listening at" "$slog")" -ge 3 ] || fail "no start without AITTA ($t/serve2.log)"
publish 1.0.2
sleep 15
[ -d "$t/u1/installed/tester/pt/1.0.2" ] && fail "1.0.2 installed without AITTA"
grep -aq "tester/pt 1.0.2" "$t/serve2.log" && fail "updated without AITTA"
echo "PASS: install by name and version, refusals listing the versions, the page's commands; the script refuses without an install, installs with AITTA, follows 1.0.1 keeping the save, stays without AITTA"
