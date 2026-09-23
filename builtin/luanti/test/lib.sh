# The contract every runner under builtin/luanti/test/ keeps, so that a
# machine can read the result and not only a person ([CI_RUNS] (1)).
#
#   exit 0   the check passed
#   exit 1   the check failed
#   exit 77  the check could not run at all -- media that is not there, a
#            server already up, a game that is not installed
#
# and a last line beginning PASS:, FAIL: or SKIP: saying which.
#
# **The trap this is for**: a runner that prints its verdict and then goes
# on to list its pictures or grep its log exits with *that* command's
# status, which is a green light with the fault written inside it. Nine
# runners did (2026-09-22). So the verdict's status is kept the moment it
# is made and the runner exits by it:
#
#   python3 - "$out" <<'PY'
#   ...
#   PY
#   verdict_keep
#   ls "$out"/*.png            # whatever else the run wants to print
#   verdict_exit
#
# verdict_keep has to be the very next line after the command that made
# the verdict, since it reads $?.
SKIP=77

verdict_keep()
{
	verdict_rc=$?
	return 0
}

verdict_exit()
{
	exit "${verdict_rc:-0}"
}

# For a runner whose verdict is a shell test rather than a python block
verdict_set()
{
	verdict_rc=$1
}
