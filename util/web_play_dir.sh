#!/bin/bash
# [WEB_ID_TRUST] (d): the web client as a directory with no game of its
# own, to be served from one fixed origin (play.buildat.org): its page
# starts on the launch menu instead of connecting to the page's own host.
# Needs web/ from util/build_web.sh.
#   util/web_play_dir.sh <out_dir>
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: util/web_play_dir.sh <out_dir>}
mkdir -p "$out"
cp "$here"/web/buildat.{js,wasm,data} "$out/"
sed "s|^\tvar server = host + ':' + port;$|\tvar server = null;|" \
	"$here/web/index.html" > "$out/index.html"
grep -q "var server = null;" "$out/index.html" ||
	{ echo "web/index.html has no server line to replace"; exit 1; }
