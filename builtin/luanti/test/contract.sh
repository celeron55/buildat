#!/bin/bash
# Reads every runner under this directory and says which of them cannot
# fail -- the contract in lib.sh, checked statically ([CI_RUNS] (1)).
#
# It is a reading, not a check of behaviour: what it catches is a runner
# that prints FAIL: and still leaves the shell at 0, which is a green
# light with the fault written inside it. Exit 1 if any runner is like
# that, so CI can hold the line once they are all fixed.
#
#   builtin/luanti/test/contract.sh
set -u
cd "$(dirname "$0")"
python3 - <<'PY'
import os, re, sys
bad = []
quiet = []
for name in sorted(f for f in os.listdir(".") if f.endswith(".sh")):
	if name in ("lib.sh", "contract.sh", "fullscreen_gate.sh"):
		continue
	src = open(name, errors="ignore").read()
	if "FAIL:" not in src and "echo FAIL" not in src:
		quiet.append(name)
		continue
	why = []
	# A python block that says FAIL: and never leaves a status behind
	for m in re.finditer(r"python3[^\n]*<<'?(\w+)'?\n(.*?)\n\1\n", src, re.S):
		body = m.group(2)
		if "FAIL:" in body and "sys.exit" not in body:
			why.append("a python block prints FAIL: and does not sys.exit")
	# The shell's own verdict, with no exit anywhere after it
	for m in re.finditer(r'echo\s+"?FAIL[:\s]', src):
		rest = src[m.end():m.end() + 200]
		# exit 1 straight away, a precondition's exit 2, or a status the
		# runner carries to its own exit at the end
		if not any(t in rest for t in ("exit 1", "exit $", "exit 2",
				"status=1", "sys.exit")):
			why.append("a shell FAIL: is not followed by exit 1")
			break
	# And whatever the runner ends with is what its status will be
	lines = [l for l in src.splitlines() if l.strip()]
	last = lines[-1].strip() if lines else ""
	# A runner may end on the line that says it passed, as long as every
	# way of failing before it left through exit 1
	ends_on_verdict = (re.fullmatch(r"\w+", last) or last.startswith("exit ")
			or "verdict_exit" in last or last == "fi"
			or last.endswith("|| exit 1")
			or (("PASS" in last) and ("exit 1" in src)))
	if not ends_on_verdict:
		why.append("the last command is %r, so that is the exit status" % last)
	if why:
		bad.append((name, why))
for name, why in bad:
	print("%s:" % name)
	for w in why:
		print("    %s" % w)
print("%d runners with a verdict, %d that cannot fail, %d with no verdict "
		"at all" % (len(os.listdir(".")) and
		len([f for f in os.listdir(".") if f.endswith(".sh")]) - len(quiet) - 3,
		len(bad), len(quiet)))
print("PASS: every runner's verdict decides its exit status" if not bad
		else "FAIL: %d runners print a verdict their exit status does not carry"
		% len(bad))
sys.exit(1 if bad else 0)
PY
