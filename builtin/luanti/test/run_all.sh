#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Runs every runner of a tier, one at a time, and says what each did
# ([CI_RUNS] (2)). The tier is named in the runner itself, on a
# "# tier:" line near the top:
#
#   quick  needs no downloaded game -- what a push runs
#   full   wants the game media (mineclone2, VoxeLibre)
#   long   the fuzz, the drives, the reference shots
#
#   builtin/luanti/test/run_all.sh quick
#   builtin/luanti/test/run_all.sh full --list
#   ONLY='keys.*|focus' builtin/luanti/test/run_all.sh quick
#
# The exit status is the run's: 0 if every runner passed or skipped, 1 if
# any failed. A runner is never retried -- a check run three times and
# taken at its best is how a real fault becomes a known flake
# ([CI_RUNS] (6)); a known flake is marked "# flaky:" in the runner and
# is run and reported but does not decide the status.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tier="${1:-quick}"
list_only=""
[ "${2:-}" = "--list" ] && list_only=1
out="$here/../../../local/run_all"
mkdir -p "$out"
# **Every runner in the tree, not only this directory's** ([CI_RUNS]:
# "every drive and run on CI"). The harness lives here for historical
# reasons; a check under extensions/ or games/ that names a tier is run
# the same way. A runner is named by its path from the root, so the two
# kinds are told apart in the output and in the log names.
root=$(cd "$here/../../.." && pwd)
runners=""
for f in "$here"/*.sh "$root"/extensions/*/check.sh "$root"/games/*/check.sh; do
	[ -f "$f" ] || continue
	case "$(basename "$f")" in
	lib.sh|contract.sh|fullscreen_gate.sh|run_all.sh) continue;;
	esac
	t=$(sed -n 's/^# tier: *//p' "$f" | head -1)
	[ "$t" = "$tier" ] || continue
	name=${f#"$root"/}
	case "$f" in "$here"/*) name=$(basename "$f");; esac
	[ -n "${ONLY:-}" ] && { echo "$name" | grep -qE "$ONLY" || continue; }
	runners="$runners $name"
done
if [ -n "$list_only" ]; then
	for r in $runners; do echo "$r"; done
	exit 0
fi
pass=0; fail=0; skip=0; flaky=0
failed_names=""
started=$(date +%s)
for name in $runners; do
	printf '%-34s ' "$name"
	log="$out/$(echo "${name%.sh}" | tr / _).log"
	path="$here/$name"
	[ -f "$path" ] || path="$root/$name"
	t0=$(date +%s)
	"$path" > "$log" 2>&1
	rc=$?
	t1=$(date +%s)
	# **A runner's leavings are not the next runner's condition.** Every
	# runner refuses to start while a client or a server is up, and one
	# that exits while its own client is still shutting down makes the
	# next one skip -- seven of the eight skips in the first container
	# run of this tier were that, which reads as "not run here" and is
	# really "run too soon after the last". So: wait for the tree to be
	# quiet, and take down what this tier itself started, which is
	# anything younger than the tier. A client somebody else is using is
	# older than that and is left alone ([CI_RUNS] (6): a flake is
	# quarantined, not papered over -- this is neither, it is the
	# harness cleaning up after itself).
	for w in $(seq 1 30); do
		pgrep -x buildat >/dev/null || pgrep -x buildat_server >/dev/null ||
			break
		sleep 1
	done
	for p in $(pgrep -x buildat) $(pgrep -x buildat_server); do
		age=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
		[ -n "$age" ] || continue
		if [ "$age" -lt "$((t1 - started + 60))" ]; then
			echo "  (the tier's own $p was still up after $name; taken down)" \
				>> "$log"
			kill -9 "$p" 2>/dev/null
		fi
	done
	verdict=$(grep -aE "^(PASS|FAIL|SKIP):" "$log" | tail -1)
	known_flaky=$(grep -c "^# flaky:" "$path")
	case "$rc" in
	0) pass=$((pass + 1)); state=pass ;;
	# 77 is the contract's "could not run"; 2 is what the runners have
	# always used for "a server or client is already up", which is the
	# same thing said the old way
	77|2) skip=$((skip + 1)); state=skip ;;
	*) if [ "$known_flaky" -gt 0 ]; then
			flaky=$((flaky + 1)); state=flaky
		else
			fail=$((fail + 1)); state=FAIL
			failed_names="$failed_names $name"
		fi ;;
	esac
	printf '%-6s %4ss  %s\n' "$state" "$((t1 - t0))" "${verdict:-(no verdict line)}"
done
echo "---"
echo "$pass passed, $fail failed, $skip skipped, $flaky known-flaky, in $(( $(date +%s) - started ))s"
[ -n "$failed_names" ] && echo "failed:$failed_names"
echo "logs in $out"
[ "$fail" -eq 0 ] && echo "PASS: the $tier tier is green" ||
	echo "FAIL: $fail runners of the $tier tier failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
