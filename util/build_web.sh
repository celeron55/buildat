#!/bin/bash
# Build the web client ([WEB_CLIENT] in doc/plan/web_client_plan.md) into
# web/, where the server serves it from by default. Needs emsdk: EMSDK, or
# ~/emsdk, with the version doc/plan/web_client_plan.md names activated.
# util/build_web.sh [make arguments]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMSDK=${EMSDK:-$HOME/emsdk}
source "$EMSDK/emsdk_env.sh" > /dev/null
mkdir -p "$ROOT/Build-web"
cd "$ROOT/Build-web"
emcmake cmake "$ROOT" -DCMAKE_BUILD_TYPE=Release
make -j$(nproc) "$@"
ls -la "$ROOT/web"
