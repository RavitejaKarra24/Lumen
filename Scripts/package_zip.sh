#!/usr/bin/env bash
# Produce the downloadable Lumen.zip: build, ad-hoc sign, archive with ditto,
# unpack the archive again, and re-verify the signature in the unpacked copy.
#
# The zip is the artifact strangers download, so every check here runs against
# the archive rather than the build directory. A broken archive should fail on
# this machine, not on theirs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/app.env"

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
fi

APP="$ROOT/$APP_NAME.app"
ZIP="$ROOT/$APP_NAME.zip"
VERIFY_DIR=""

cleanup() {
  [[ -n "$VERIFY_DIR" ]] && rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

for tool in ditto codesign plutil lipo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
  }
done

# The download has to run on every Mac that meets the minimum OS version, not
# just the one that built it, so default to a universal binary.
export ARCHES=${ARCHES:-"arm64 x86_64"}

# Ad-hoc rather than the persistent local identity used by install.sh: that
# identity exists only in this machine's keychain and would mean nothing to
# anyone downloading the app.
echo "==> Building and ad-hoc signing $APP_NAME ($ARCHES)"
SIGNING_MODE=adhoc "$ROOT/Scripts/package_app.sh" release

echo "==> Verifying the bundle"
test -x "$APP/Contents/MacOS/$APP_NAME"
test -f "$APP/Contents/Resources/Icon.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP"

# ditto in CPIO-archive mode preserves symlinks, extended attributes, and
# resource forks. The `zip` command drops them, which invalidates the signature
# and produces an app that silently refuses to launch on Apple silicon.
echo "==> Archiving with ditto"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Unpacking the archive and re-verifying"
VERIFY_DIR="$(mktemp -d)"
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_DIR"
UNPACKED="$VERIFY_DIR/$APP_NAME.app"
test -d "$UNPACKED" || {
  echo "ERROR: $ZIP does not contain $APP_NAME.app at its root" >&2
  exit 1
}
test -x "$UNPACKED/Contents/MacOS/$APP_NAME"
plutil -lint "$UNPACKED/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$UNPACKED"

UNPACKED_ARCHES="$(lipo -archs "$UNPACKED/Contents/MacOS/$APP_NAME")"
for arch in $ARCHES; do
  if [[ " $UNPACKED_ARCHES " != *" $arch "* ]]; then
    echo "ERROR: The archived binary is missing $arch (found: $UNPACKED_ARCHES)" >&2
    exit 1
  fi
done

ZIP_SIZE="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"
echo
echo "Created $ZIP"
echo "  version:      ${MARKETING_VERSION:-unknown} (build ${BUILD_NUMBER:-unknown})"
echo "  architectures: $UNPACKED_ARCHES"
echo "  size:         $ZIP_SIZE"
echo
echo "Commit the zip in the same commit as the change it contains, or users"
echo "download old code alongside a new README."
