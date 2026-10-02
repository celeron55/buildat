#!/bin/bash
# The game media the full and long tiers want ([CI_RUNS] (4)), fetched
# from ContentDB into <user>/shared/vanilla/games:
#
#   util/media_fetch.sh            install what is missing
#   util/media_fetch.sh --key      print author/name and release id per
#                                  line, which is what a CI cache is
#                                  keyed on: a run that changes nothing
#                                  downloads nothing
#
# Only the games a runner names are here. A game already on disk is left
# alone whatever release it is -- this is a fetch, not an updater.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dest="${BUILDAT_USER_DIR:-$here/user}/shared/vanilla/games"
url="${BUILDAT_CONTENTDB_URL:-https://content.luanti.org}"
# author/name/installed-as. mineclone2 is VoxeLibre, and the runners
# name it by the directory Luanti installs it under
packages="Wuzzy/mineclone2/mineclone2"
key_only=""
[ "${1:-}" = "--key" ] && key_only=1
mkdir -p "$dest"
for p in $packages; do
	author=${p%%/*}; rest=${p#*/}; name=${rest%%/*}; as=${rest##*/}
	rel=$(curl -fsSL "$url/api/packages/$author/$name/releases/" |
		python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["id"] if r else "")')
	if [ -z "$rel" ]; then
		echo "no release for $author/$name at $url" >&2; exit 2
	fi
	if [ -n "$key_only" ]; then
		echo "$author/$name $rel"
		continue
	fi
	if [ -e "$dest/$as/game.conf" ]; then
		echo "$as: already here"
		continue
	fi
	zip=$(mktemp /tmp/buildat_media.XXXXXX.zip)
	curl -fsSL -o "$zip" \
		"$url/packages/$author/$name/releases/$rel/download/"
	# ContentDB's zip has one top directory, whose name is not the
	# package's; the game goes in as the name the runners use
	tmp=$(mktemp -d /tmp/buildat_media.XXXXXX)
	unzip -q "$zip" -d "$tmp"
	mv "$tmp/$(ls "$tmp" | head -1)" "$dest/$as"
	rm -rf "$zip" "$tmp"
	echo "$as: release $rel, $(du -sh "$dest/$as" | cut -f1)"
done
