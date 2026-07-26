#!/usr/bin/env bash
# Build Lumen locally, install it for the current user, then launch it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/app.env"
INSTALL_ROOT="$HOME/Applications"
INSTALL_APP="$INSTALL_ROOT/$APP_NAME.app"
STAGING_APP="$INSTALL_ROOT/.${APP_NAME}.install.$$.app"

cleanup() {
  rm -rf "$STAGING_APP"
}
trap cleanup EXIT

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "ERROR: Xcode Command Line Tools are required." >&2
  echo "Install them with: xcode-select --install" >&2
  exit 1
fi

for tool in codesign plutil iconutil ditto open; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
  }
done

mkdir -p "$INSTALL_ROOT"
echo "==> Building and signing $APP_NAME"
SIGNING_MODE="${SIGNING_MODE:-local}" "$ROOT/Scripts/package_app.sh" release

SOURCE_APP="$ROOT/$APP_NAME.app"
test -x "$SOURCE_APP/Contents/MacOS/$APP_NAME"
plutil -lint "$SOURCE_APP/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"

rm -rf "$STAGING_APP"
ditto "$SOURCE_APP" "$STAGING_APP"
# This affects only the app just built on this Mac; it never changes Gatekeeper
# globally or touches unrelated downloads.
xattr -dr com.apple.quarantine "$STAGING_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [[ -d "$INSTALL_APP" ]]; then
  echo "==> Stopping the installed copy"
  pkill -f "$INSTALL_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

rm -rf "$INSTALL_APP"
mv "$STAGING_APP" "$INSTALL_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALL_APP"

echo "==> Installed $APP_NAME at $INSTALL_APP"
open "$INSTALL_APP"
echo "Opened $APP_NAME. Grant Accessibility in System Settings when prompted."
