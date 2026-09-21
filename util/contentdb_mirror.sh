#!/bin/bash
# A ContentDB mirror for a test ([FIRST_RUN]): a directory that answers
# the two requests games/vanilla makes -- the game list and a package's
# releases -- as files, and holds the game's zip, so that
#
#   util/contentdb_mirror.sh <dir> <game_dir> <author> <name> <title>
#   (cd <dir> && python3 -m http.server 8765)
#   BUILDAT_CONTENTDB_URL=http://localhost:8765 ...
#
# installs <game_dir> as <name> without the network. http.server ignores
# a query string and serves index.html for a directory, which is what
# makes /api/packages/?type=game... and /api/packages/<a>/<n>/releases/
# plain files. The zip is the game directory zipped, as ContentDB's are.
set -eu
dir="$1"; game="$2"; author="$3"; name="$4"; title="$5"
mkdir -p "$dir/api/packages/$author/$name/releases" "$dir/files"
cat > "$dir/api/packages/index.html" <<JSON
[{"author": "$author", "name": "$name", "title": "$title", "short_description": "a mirror's copy", "thumbnail": ""}]
JSON
cat > "$dir/api/packages/$author/$name/releases/index.html" <<JSON
[{"url": "/files/$name.zip", "title": "mirror"}]
JSON
rm -f "$dir/files/$name.zip"
(cd "$(dirname "$game")" && zip -qr "$dir/files/$name.zip" "$(basename "$game")" -x '*/.git/*')
echo "mirror in $dir: $name.zip $(du -h "$dir/files/$name.zip" | cut -f1)"
