#!/bin/bash
# A release in one go: bump VERSION, commit it on luanti-module, and run
# util/squash_push.sh from a throwaway worktree -- the squashed branch and
# its v<version>-<hash> tag pushed, which package.yml turns into a
# prerelease with the archives ([SQUASH_RELEASE]). The main tree's session
# is not disturbed: only VERSION is committed there, its other changes are
# left as they are, and the squash is made elsewhere.
#
#   util/release.sh            # patch: 0.3.1 -> 0.3.2
#   util/release.sh minor      # 0.3.1 -> 0.4.0
#   util/release.sh major      # 0.3.1 -> 1.0.0
#   PUSH=0 util/release.sh     # everything but the push
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"
part="${1:-patch}"
if [ "$(git rev-parse --abbrev-ref HEAD)" != "luanti-module" ]; then
	echo "run this in the tree that has luanti-module checked out" >&2; exit 2
fi
if ! git diff --quiet HEAD -- VERSION; then
	echo "VERSION has uncommitted changes; commit or revert them first" >&2; exit 2
fi
IFS=. read -r ma mi pa < VERSION
case "$part" in
	major) ma=$((ma + 1)); mi=0; pa=0 ;;
	minor) mi=$((mi + 1)); pa=0 ;;
	patch) pa=$((pa + 1)) ;;
	*) echo "usage: util/release.sh [major|minor|patch]" >&2; exit 2 ;;
esac
v="$ma.$mi.$pa"
echo "$v" > VERSION
# Only this file, whatever else is in flight in the tree
git commit -q -m "version: $v" -- VERSION
echo "committed version $v on luanti-module ($(git rev-parse --short HEAD))"

wt=$(mktemp -d "${TMPDIR:-/tmp}/buildat_release.XXXXXX")
trap 'git worktree remove --force "$wt" 2>/dev/null || true' EXIT
git worktree add -q --detach "$wt" luanti-module
(cd "$wt" && PUSH="${PUSH:-1}" util/squash_push.sh)
