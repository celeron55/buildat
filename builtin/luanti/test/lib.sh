# SPDX-License-Identifier: Apache-2.0 OR MIT
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

# The checks' own user and cache paths, and check_pgrep/check_pkill
. "$(dirname "${BASH_SOURCE[0]}")/../../../util/check_paths.sh"

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

# **A run that has stopped saying anything is over** (user, 2026-09-24:
# a check "ran for 4 minutes and wasn't progressing"). A wedged client,
# or a drive whose waits are all sitting out their timeouts, otherwise
# burns minutes of a check that has already failed -- and the whole
# point of a tier is that a failure is read soon.
#
#   run_client 60 "$out/cli.log" timeout 600 bin/buildat ... -c @cmds
#
# The command's output goes to the log, raw; a caller that wants the
# colour codes out runs sed -i over it afterwards, as it did over the
# pipe. The watcher takes the run down as soon as the log has not grown
# for <stall> seconds. A driven client says something at least every ten
# seconds -- every command it runs, and a heartbeat while a wait_log
# waits -- so quiet means stuck.
#
# The status is the command's, or 125 when the watchdog took it down.
run_client()
{
	local stall=$1 log=$2
	shift 2
	: > "$log"
	"$@" > "$log" 2>&1 &
	local pid=$! last=0 quiet=0 size=0
	while kill -0 "$pid" 2>/dev/null; do
		sleep 5
		size=$(wc -c < "$log" 2>/dev/null || echo 0)
		if [ "${size:-0}" -gt "$last" ]; then
			last=$size
			quiet=0
			continue
		fi
		quiet=$((quiet + 5))
		[ "$quiet" -lt "$stall" ] && continue
		echo "run_client: nothing logged for ${stall}s; taken down" >> "$log"
		# The child too: the command is usually "timeout ... bin/buildat",
		# and killing timeout outright leaves the client behind
		pkill -9 -P "$pid" 2>/dev/null
		kill -9 "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
		return 125
	done
	wait "$pid"
}

# **The last drive's client is not this drive's condition.** A check
# that runs several clients in a row starts the next one while the last
# is still shutting down: it holds a port, and it answers -- or stops --
# the server this run just started, which reads as "the screen never
# opened". Waits for the tree to go quiet, up to <seconds> (30 by
# default); 1 if it never did.
wait_quiet()
{
	local s=${1:-30} i=0
	while check_pgrep buildat >/dev/null || check_pgrep buildat_server >/dev/null; do
		i=$((i + 1))
		if [ "$i" -ge "$s" ]; then
			echo "wait_quiet: a client or server is still up after ${s}s" >&2
			return 1
		fi
		sleep 1
	done
	return 0
}
