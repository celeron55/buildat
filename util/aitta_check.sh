#!/bin/bash
# tier: quick
# cost: 2s (2026-10-03)
# covers: src/impl/aitta.cpp src/interface/aitta.h src/client/main.cpp
# [AITTA_MVP] step 1: an app packed and signed, installed, and the installs
# that must be refused -- a byte changed, another key, an engine API this
# engine does not have, a name that is a path, a home Hearth that is not an
# address, a changelog not in it; the signing deterministic.
#
#   util/aitta_check.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }

mkdir -p "$t/app/main" "$t/user"
echo 'int x;' > "$t/app/main/main.cpp"
mkdir "$t/app/.git" && echo x > "$t/app/.git/HEAD"
manifest(){ # version engine_api name
	printf '{"author": "tester", "name": "%s", "version": "%s",
		"engine_api": %s, "license_code": "MIT",
		"license_media": "CC0-1.0", "description": "a check"}\n' \
		"${3:-demo}" "$1" "$2" > "$t/app/meta.json"
}

"$b" aitta keygen "$t/key" > "$t/pub" || fail "keygen"
"$b" aitta keygen "$t/key" 2>/dev/null && fail "keygen overwrote a key"
"$b" aitta keygen "$t/key2" > /dev/null || fail "keygen 2"

manifest 1.0 1
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out") || fail "pack"
[ "$zip" = "$t/out/tester-demo-1.0.zip" ] || fail "pack wrote $zip"
grep -q "$(cat "$t/pub")" "$t/out/tester-demo-1.0.sig" || fail "the .sig has another key"
dir=$("$b" aitta install "$zip" "$t/user") || fail "install"
# Signing is deterministic (RFC 6979): the same archive, the same signature
"$b" aitta pack "$t/app" "$t/key" "$t/again" > /dev/null || fail "pack again"
cmp -s "$zip" "$t/again/tester-demo-1.0.zip" || fail "the same app packed differently"
cmp -s "$t/out/tester-demo-1.0.sig" "$t/again/tester-demo-1.0.sig" ||
	fail "the same archive signed differently"
[ -f "$dir/main/main.cpp" ] && [ -f "$dir/meta.json" ] || fail "installed files missing in $dir"
[ -e "$dir/.git" ] && fail ".git was packed"
"$b" aitta install "$zip" "$t/user" 2>/dev/null && fail "installed the same version twice"

# A byte changed in the archive
manifest 1.1 1
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out") || fail "pack 1.1"
cp "$zip" "$t/tampered.zip"; cp "${zip%.zip}.sig" "$t/tampered.sig"
printf 'X' | dd of="$t/tampered.zip" bs=1 seek=40 conv=notrunc 2>/dev/null
"$b" aitta install "$t/tampered.zip" "$t/user" 2>/dev/null && fail "a tampered archive installed"
# The .sig's hash rewritten to the tampered archive's: the signature fails
h=$(sha256sum "$t/tampered.zip" | cut -d' ' -f1)
sed -i "s/\"sha256\": *\"[0-9a-f]*\"/\"sha256\":\"$h\"/" "$t/tampered.sig"
"$b" aitta install "$t/tampered.zip" "$t/user" 2>/dev/null && fail "a re-hashed tampered archive installed"
"$b" aitta install "$zip" "$t/user" > /dev/null || fail "install 1.1 beside 1.0"

# Another author's key for the same author/name
manifest 1.2 1
zip=$("$b" aitta pack "$t/app" "$t/key2" "$t/out") || fail "pack 1.2"
"$b" aitta install "$zip" "$t/user" 2>/dev/null && fail "installed under another key"

# An engine API this engine does not have; a name that is a path
manifest 1.3 999
"$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null && fail "packed engine API 999"
manifest 1.4 1 "../evil"
"$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null && fail "packed a name with a path"

# The optional home Hearth and changelog: an address, and a file that is there
extra(){ # fields
	manifest 1.5 1
	sed -i "s|\"description\"|$1, \"description\"|" "$t/app/meta.json"
}
extra '"home_hearth": "forum.example", "changelog": "CHANGELOG.md"'
"$b" aitta pack "$t/app" "$t/key" "$t/out" 2>&1 | grep -q '"home_hearth": an http' ||
	fail "a home Hearth that is not an address"
extra '"home_hearth": "https://forum.example", "changelog": "../CHANGELOG.md"'
"$b" aitta pack "$t/app" "$t/key" "$t/out" 2>&1 | grep -q '"changelog": a path' ||
	fail "a changelog outside the archive"
extra '"home_hearth": "https://forum.example", "changelog": "CHANGELOG.md"'
"$b" aitta pack "$t/app" "$t/key" "$t/out" 2>&1 | grep -q 'is not there' ||
	fail "a changelog that is not there"
echo "1.5: the fields" > "$t/app/CHANGELOG.md"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out") || fail "pack with the fields"
"$b" aitta install "$zip" "$t/user" > /dev/null || fail "install with the fields"

[ -z "$(ls -A "$t/user/installed" | grep incoming)" ] || fail "an .incoming directory was left"
echo "PASS: packed, signed and installed; tampering, another key, a newer engine API and a path name refused"
