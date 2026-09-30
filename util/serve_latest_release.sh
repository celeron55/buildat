#!/bin/bash
# Runs a game on the newest GitHub release's Linux web-precompiled archive,
# and moves to each newer release as it appears. For a testing server in a
# terminal (a GNU screen): it stays in the foreground, the server's output
# is its own, and Ctrl+C stops both.
#
#   util/serve_latest_release.sh <game> <port> <user dir> [server options...]
#   util/serve_latest_release.sh floorplanner 29500 ~/buildat-user -T 127.0.0.1
#
# The user directory holds the saves and accounts. Every version uses it
# (-D), and it can be one a server used before. The rest is under
# BUILDAT_SERVE_DIR (default ~/buildat-serve):
#   versions/<archive>/  each release, unpacked
#   current              the version running
#   server.log           the server's output, also on the terminal
# A new release is downloaded and unpacked, the running server is stopped
# with SIGTERM (a game saves on it), and the new one started. Every version
# but that one and the one before it is deleted.
#
# **A rollback** is by hand, with this script stopped: run the version
# before from its directory,
#   cd ~/buildat-serve/versions/<the one before>
#   bin/buildat_server -m games/<game> -P <port> -D <user dir>
# Started again, this script goes back to the newest release. A game whose
# saves carry a schema version (the floorplanner) refuses a save that a
# newer version wrote.
#
# Environment: POLL_SECONDS (300), GITHUB_REPO (celeron55/buildat),
# GITHUB_TOKEN (optional; unauthenticated, GitHub allows 60 asks an hour).
# Needs bash, curl and tar.
set -u

if [ $# -lt 3 ]; then
	grep '^#   util/' "$0" | sed 's/^# *//' >&2
	exit 2
fi
game=$1
port=$2
mkdir -p "$3" || exit 1
user_dir=$(cd "$3" && pwd)
shift 3
server_args=("$@")

base=${BUILDAT_SERVE_DIR:-$HOME/buildat-serve}
poll=${POLL_SECONDS:-300}
repo=${GITHUB_REPO:-celeron55/buildat}
asset_re='linux-x86_64-web-precompiled\.tar\.gz'

mkdir -p "$base/versions"
cd "$base" || exit 1

say(){ echo "[serve $(date '+%F %T')] $*"; }

# The newest release's archive URL, or nothing. Releases come newest
# first, and one still being built has no archive yet: the first URL
# found is the newest there is.
latest_url(){
	local auth=()
	[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL --max-time 60 "${auth[@]}" \
			"https://api.github.com/repos/$repo/releases?per_page=10" |
		grep -o '"browser_download_url": *"[^"]*"' |
		sed 's/.*"\(http[^"]*\)"$/\1/' |
		grep -E "$asset_re" | head -n 1
}

# Downloads and unpacks a release into versions/<name>; its name, or
# nothing when it could not
install(){
	local url=$1
	local name
	name=$(basename "$url" .tar.gz)
	if [ -x "versions/$name/bin/buildat_server" ]; then
		echo "$name"
		return
	fi
	local tmp="versions/.download-$name"
	rm -rf "$tmp" "$tmp.tar.gz"
	say "downloading $name" >&2
	if ! curl -fL --retry 3 --max-time 1800 -o "$tmp.tar.gz" "$url" >&2; then
		say "download failed" >&2
		rm -f "$tmp.tar.gz"
		return
	fi
	mkdir -p "$tmp"
	if ! tar -C "$tmp" -xzf "$tmp.tar.gz"; then
		say "the archive would not unpack" >&2
		rm -rf "$tmp" "$tmp.tar.gz"
		return
	fi
	rm -f "$tmp.tar.gz"
	# The archive has one directory at the top
	local top
	top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)
	if [ -z "$top" ] || [ ! -x "$top/bin/buildat_server" ]; then
		say "no bin/buildat_server in the archive" >&2
		rm -rf "$tmp"
		return
	fi
	rm -rf "versions/$name"
	mv "$top" "versions/$name"
	rm -rf "$tmp"
	echo "$name"
}

# Every version but the current one and the newest other, which is kept
# for a rollback
prune(){
	local keep_prev
	keep_prev=$(ls -1 versions | grep -v '^\.' | grep -vx "$current" |
			sort -V | tail -n 1)
	local v
	for v in $(ls -1 versions | grep -v '^\.'); do
		if [ "$v" != "$current" ] && [ "$v" != "$keep_prev" ]; then
			say "deleting the old version $v"
			rm -rf "versions/$v"
		fi
	done
}

pid=""
start(){
	local dir="$base/versions/$current"
	if [ ! -d "$dir/games/$game" ]; then
		say "$current has no games/$game"
		return 1
	fi
	say "starting $current: games/$game on port $port, user $user_dir"
	echo "$current" > "$base/current"
	(cd "$dir" && exec bin/buildat_server -m "games/$game" -P "$port" \
			-D "$user_dir" "${server_args[@]}") \
			> >(tee -a "$base/server.log") 2>&1 &
	pid=$!
}

stop(){
	[ -z "$pid" ] && return
	if kill -0 "$pid" 2>/dev/null; then
		say "stopping the server"
		kill -TERM "$pid" 2>/dev/null
		local i
		for i in $(seq 60); do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.5
		done
		if kill -0 "$pid" 2>/dev/null; then
			say "the server did not stop in 30 s; killing it"
			kill -KILL "$pid" 2>/dev/null
		fi
	fi
	wait "$pid" 2>/dev/null
	pid=""
}

trap 'stop; say "stopped"; exit 0' INT TERM

# What ran last, else the newest there is
current=""
if [ -f current ] && [ -d "versions/$(cat current)" ]; then
	current=$(cat current)
else
	current=$(ls -1 versions | grep -v '^\.' | sort -V | tail -n 1)
fi

# A version that would not start is not tried again until another comes
broken=""
next_poll=0
while true; do
	now=$(date +%s)
	if [ "$now" -ge "$next_poll" ]; then
		next_poll=$((now + poll))
		url=$(latest_url)
		if [ -z "$url" ]; then
			say "could not read the releases of $repo; keeping ${current:-nothing}"
		elif [ "$(basename "$url" .tar.gz)" != "$current" ]; then
			name=$(install "$url")
			if [ -n "$name" ]; then
				say "new version: $name"
				stop
				current=$name
				start
				prune
			fi
		fi
	fi
	if [ -n "$current" ] && [ "$broken" != "$current" ] &&
			{ [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }; then
		if [ -n "$pid" ]; then
			wait "$pid" 2>/dev/null
			say "the server exited ($?); starting it again in 10 s"
			pid=""
			sleep 10
		fi
		start || broken=$current
	fi
	sleep 5
done
