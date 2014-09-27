#!/bin/sh
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "guard_launcher.sh: If you wish to debug buildat_client, run $DIR/buildat_client.bin directly"
LD_PRELOAD="$DIR/../lib/libbuildat_guard.so" "$DIR/buildat_client.bin" $@
