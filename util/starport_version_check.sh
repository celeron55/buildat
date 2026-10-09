#!/bin/bash
# tier: full
# cost: 60s (2026-10-09)
# covers: client/extensions/starport/init.lua apps/starport/main/main.cpp util/starport_version_github.py
# [VERSION_CHECK]: a Starport whose version adapter says 0.9.0 carries it
# in /api/list, filtered (a bad platform left out); the launcher shows the
# notice, "Not now" is kept across a restart, a newer version (0.9.1) is
# told again, and "Open" hands the platform's link to the system's opener
# (an xdg-open of this check's own on PATH). The GitHub adapter prints the
# newest release, when GitHub answers.
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_spver.XXXXXX")
SP=29681
export BUILDAT_CONNECT_PORTS="$SP"
pid=
cleanup() {
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$here"

starport() { # version
	[ -n "$pid" ] && kill "$pid" && wait "$pid" 2>/dev/null
	mkdir -p "$tmp/sp/apps/starport"
	cat > "$tmp/sp/apps/starport/version_adapter" <<A
#!/bin/sh
echo "a warning on stderr" >&2
echo '{"version": "$1", "url": "https://example.org/releases",
 "platforms": {"linux": {"url": "https://example.org/linux-$1.tar.gz"},
  "win64": {"url": "http://example.org/insecure"}, "bad name": {"url": "https://x"}}}'
A
	chmod +x "$tmp/sp/apps/starport/version_adapter"
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -P $SP -l 3 \
		>> "$tmp/sp.log" 2>&1 &
	pid=$!
	for _ in $(seq 120); do
		curl -s -m 2 "localhost:$SP/api/list" | grep -q "\"version\":{.*$1" && return
		sleep 1
	done
	fail "/api/list has no version $1 (sp.log)"
}
starport 0.9.0
curl -s -m 10 "localhost:$SP/api/list" | python3 -c '
import json, sys
v = json.load(sys.stdin)["version"]
assert v == {"version": "0.9.0", "url": "https://example.org/releases",
	"platforms": {"linux": {"url": "https://example.org/linux-0.9.0.tar.gz"}}}, v
' || fail "/api/list's version not as filtered"
echo "ok: /api/list carries the adapter's answer, filtered"

mkdir -p "$tmp/cl" "$tmp/bin"
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > "$tmp/cl/starport.json"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP $(date +%s) $(date +%s) > "$tmp/cl/network_addresses.csv"
printf '#!/bin/sh\necho "$@" > %s/opened\n' "$tmp" > "$tmp/bin/xdg-open"
chmod +x "$tmp/bin/xdg-open"
launcher() { # cmds log
	PATH="$tmp/bin:$PATH" BUILDAT_STARPORT_OFFER=1 timeout 120 Build/bin/buildat \
		-o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 4 \
		-o sound_mute=1 -c @"$1" > "$2" 2>&1
}
cat > "$tmp/c1" <<C
wait_log_any 30000 Offering version 0.9.0
delay 1000
screenshot $tmp/notice.png
click Button "Not now"
delay 500
quit
C
launcher "$tmp/c1" "$tmp/cl1.log"
grep -q "Offering version 0.9.0 (https://example.org/linux-0.9.0.tar.gz" "$tmp/cl1.log" ||
	fail "no notice, or not the platform's link ($tmp/cl1.log)"
grep -q '"version_not_now":"0.9.0"' "$tmp/cl/starport.json" ||
	fail "Not now not kept ($tmp/cl1.log)"
echo "ok: the notice with this platform's link; Not now kept"

printf 'delay 12000\nquit\n' > "$tmp/c2"
launcher "$tmp/c2" "$tmp/cl2.log"
grep -q "Offering version" "$tmp/cl2.log" && fail "0.9.0 told again after Not now"
echo "ok: not told again"

starport 0.9.1
cat > "$tmp/c3" <<C
wait_log_any 30000 Offering version 0.9.1
delay 1000
click Button "Open"
wait_log 5000 Version link
delay 1000
quit
C
launcher "$tmp/c3" "$tmp/cl3.log"
[ "$(cat "$tmp/opened" 2>/dev/null)" = "https://example.org/linux-0.9.1.tar.gz" ] ||
	fail "Open did not open the link ($tmp/cl3.log)"
echo "ok: a newer version told again; Open opened its link"

if out=$(timeout 60 util/starport_version_github.py 2>&1); then
	echo "$out" | python3 -c '
import json, re, sys
v = json.load(sys.stdin)
assert re.match(r"^\d+(\.\d+)+$", v["version"]) and v["url"].startswith("https://"), v
' || fail "the GitHub adapter printed $out"
	echo "ok: the GitHub adapter: $(echo "$out" | cut -c1-60)..."
else
	echo "skipped: the GitHub adapter (no answer: $(echo "$out" | tail -1))"
fi
echo "PASS"
