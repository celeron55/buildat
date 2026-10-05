#!/bin/bash
# A release in one go: bump VERSION, commit it on the development branch
# (whatever is checked out), tag that commit v<version>-<hash>, and push
# the branch to bitbucket (its backup) and to github with the tag, which
# package.yml turns into a prerelease with the archives. The branch is
# released as it is, history and all (user, 2026-10-05). The session
# working in the tree is not disturbed: only VERSION is committed, its
# other changes are left as they are.
#
#   util/release.sh            # patch: 0.3.1 -> 0.3.2
#   util/release.sh minor      # 0.3.1 -> 0.4.0
#   util/release.sh major      # 0.3.1 -> 1.0.0
#   PUSH=0 util/release.sh     # everything but the push
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"
part="${1:-patch}"
# The branch is never named here: a release is of whatever is checked
# out, so renaming the development branch carries through
branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = HEAD ]; then
	echo "detached HEAD; check out the development branch first" >&2; exit 2
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
h=$(git rev-parse --short HEAD)
# package.yml fires on the tag; a hash in it makes a prerelease, and a
# plain v<version> tag placed by hand is the real release
t="v$v-$h"
git tag "$t"
echo "committed version $v on $branch, tagged $t"
if [ "${PUSH:-1}" = 1 ]; then
	git push bitbucket "$branch"
	git push github "$branch" "$t"
fi
