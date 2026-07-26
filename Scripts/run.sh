#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/app.env"
export APP_NAME BUNDLE_ID MENU_BAR_APP MACOS_MIN_VERSION
# A stable local identity keeps Accessibility permission valid across rebuilds.
export SIGNING_MODE=${SIGNING_MODE:-local}
exec "$ROOT/Scripts/compile_and_run.sh" "$@"
