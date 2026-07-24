#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export APP_NAME=Lumen
export BUNDLE_ID=com.lumen.app
export MENU_BAR_APP=0
# A stable local identity keeps Accessibility permission valid across rebuilds.
export SIGNING_MODE=${SIGNING_MODE:-local}
exec "$ROOT/Scripts/compile_and_run.sh" "$@"
