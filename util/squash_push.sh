#!/bin/bash
# [SQUASHED_BRANCH]: luanti-module's tree as one commit on top of master,
# on a branch named for the version and the source hash, pushed to github.
# No history crosses: the branch is master plus one diff, and doc/plan/ --
# which narrates the history -- is left out of it. A new branch per
# release; nothing is reset or force-pushed.
#
#   util/squash_push.sh            # from a clean checkout of luanti-module
#   PUSH=0 util/squash_push.sh     # make the branch, do not push
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"
src=luanti-module
# On the branch, or detached at its tip -- util/release.sh runs this in a
# throwaway worktree so the main tree's session is not disturbed
if [ "$(git rev-parse --abbrev-ref HEAD)" != "$src" ] &&
		[ "$(git rev-parse HEAD)" != "$(git rev-parse "$src")" ]; then
	echo "run this on $src, or detached at its tip" >&2; exit 2
fi
if ! git diff --quiet HEAD; then
	echo "the tree has uncommitted changes; a squash is of a commit" >&2; exit 2
fi
v=$(tr -d '[:space:]' < VERSION)
h=$(git rev-parse --short "$src")
b="luanti-module-squashed-$v-$h"
if git show-ref --verify --quiet "refs/heads/$b"; then
	echo "$b exists already; bump VERSION or commit first" >&2; exit 2
fi
git branch "$b" master
git checkout -q "$b"
# The tree, not the history: everything luanti-module has, on master's tip,
# and nothing master had that luanti-module has not
git rm -r -q .
git checkout "$src" -- .
git rm -r -q --cached doc/plan && rm -rf doc/plan
# The README's bullet pointing at the plans (three lines, the two
# continuation lines indented) goes with them
sed -i '/doc\/plan\/master_plan.md/{N;N;d}' README.md
git add -A
git commit -q -m "luanti-module at $h, $(date +%F), version $v"
# And a tag on it, v<version>-<hash>: package.yml fires on the tag and
# makes a prerelease with the archives ([SQUASH_RELEASE]); a plain
# v<version> tag placed by hand on a squash is the real release
t="v$v-$h"
git tag -f "$t"
echo "made $b, tagged $t"
if [ "${PUSH:-1}" = 1 ]; then
	git push github "$b" "$t"
fi
# Back to the branch, or to the tip it was detached at (release.sh's worktree)
if git show-ref --verify --quiet "refs/heads/$src" &&
		git worktree list --porcelain | grep -q "^branch refs/heads/$src$"; then
	git checkout -q --detach "$src"
else
	git checkout -q "$src"
fi
