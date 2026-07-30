#!/usr/bin/env bash
# Build, bundle, and sign Lumen without requiring an Xcode project.
set -euo pipefail

CONF=${1:-release}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/app.env"

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
  BUILD_NUMBER=${BUILD_NUMBER:-1}
fi

for tool in swift lipo codesign plutil xattr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
  }
done

ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  ARCH_LIST=("$(uname -m)")
fi

# Newer standalone toolchains can use Swift Build when the native engine is
# unavailable. Older toolchains simply omit this optional flag.
BUILD_SYSTEM_ARGS=()
if [[ -n ${SWIFT_BUILD_SYSTEM:-} ]]; then
  BUILD_SYSTEM_ARGS=(--build-system "$SWIFT_BUILD_SYSTEM")
elif swift build --help 2>/dev/null | grep -q "swiftbuild"; then
  BUILD_SYSTEM_ARGS=(--build-system swiftbuild)
fi

ARCH_ARGS=()
for arch in "${ARCH_LIST[@]}"; do
  ARCH_ARGS+=(--arch "$arch")
done

# Pass every architecture to a single invocation so SwiftPM emits one universal
# binary. Building each architecture in its own invocation does not work: both
# builds resolve to the same bin path, so the second overwrites the first.
swift build "${BUILD_SYSTEM_ARGS[@]}" -c "$CONF" "${ARCH_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_SYSTEM_ARGS[@]}" -c "$CONF" "${ARCH_ARGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
  echo "ERROR: Missing $APP_NAME build at $BINARY" >&2
  exit 1
fi
BUNDLE_SEARCH_DIRS=("$BIN_DIR")

APP="$ROOT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

actual_arches="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
for arch in "${ARCH_LIST[@]}"; do
  if [[ " $actual_arches " != *" $arch "* ]]; then
    echo "ERROR: App binary is missing $arch (found: $actual_arches)" >&2
    exit 1
  fi
done

LSUI_VALUE=false
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE=true
fi
BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

copy_resource_bundle() {
  local source="$1"
  local name destination identifier
  name="$(basename "$source")"
  destination="$APP/Contents/Resources/$name"

  if [[ -f "$source/Contents/Info.plist" ]]; then
    cp -R "$source" "$destination"
    return
  fi

  # SwiftPM's native and Swift Build engines can emit flat resource bundles.
  # Turn those into a standard macOS bundle before signing the outer app.
  mkdir -p "$destination/Contents/Resources"
  if [[ -d "$source/Resources" ]]; then
    cp -R "$source/Resources/." "$destination/Contents/Resources/"
  else
    cp -R "$source/." "$destination/Contents/Resources/"
  fi
  identifier="${BUNDLE_ID}.resources.${name%.bundle}"
  cat > "$destination/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>${identifier}</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
</dict></plist>
PLIST
}

for search_dir in "${BUNDLE_SEARCH_DIRS[@]}"; do
  shopt -s nullglob
  bundles=("$search_dir"/*.bundle)
  shopt -u nullglob
  for bundle in "${bundles[@]}"; do
    copy_resource_bundle "$bundle"
  done
done

"$ROOT/Scripts/build_icon.sh" "$APP/Contents/Resources/Icon.icns"

# Embed frameworks if a future package dependency produces one.
for search_dir in "${BUNDLE_SEARCH_DIRS[@]}"; do
  shopt -s nullglob
  frameworks=("$search_dir"/*.framework)
  shopt -u nullglob
  if [[ ${#frameworks[@]} -gt 0 ]]; then
    cp -R "${frameworks[@]}" "$APP/Contents/Frameworks/"
    chmod -R a+rX "$APP/Contents/Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"
    break
  fi
done

# Extended attributes and AppleDouble files invalidate code sealing.
chmod -R u+w "$APP"
xattr -cr "$APP"
find "$APP" -name '._*' -delete

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
DEFAULT_ENTITLEMENTS="$ENTITLEMENTS_DIR/${APP_NAME}.entitlements"
mkdir -p "$ENTITLEMENTS_DIR"
APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  cat > "$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>
PLIST
fi

case "${SIGNING_MODE:-local}" in
  local)
    # A persistent local identity keeps the Accessibility approval stable across
    # rebuilds without requiring an Apple Developer certificate.
    eval "$(APP_NAME="$APP_NAME" "$ROOT/Scripts/setup_local_signing.sh" --print-env)"
    security unlock-keychain -p "$(<"$APP_KEYCHAIN_PASSWORD_FILE")" "$APP_KEYCHAIN"
    CODESIGN_ARGS=(--force --sign "$APP_IDENTITY" --keychain "$APP_KEYCHAIN")
    ;;
  adhoc)
    CODESIGN_ARGS=(--force --sign - --timestamp=none)
    ;;
  identity)
    if [[ -z ${APP_IDENTITY:-} ]]; then
      echo "ERROR: APP_IDENTITY is required when SIGNING_MODE=identity" >&2
      exit 1
    fi
    CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
    if [[ -n ${APP_KEYCHAIN:-} ]]; then
      CODESIGN_ARGS+=(--keychain "$APP_KEYCHAIN")
    fi
    ;;
  *)
    echo "ERROR: Unknown SIGNING_MODE '${SIGNING_MODE}' (expected local, adhoc, or identity)" >&2
    exit 1
    ;;
esac

sign_frameworks() {
  local framework executable
  for framework in "$APP/Contents/Frameworks/"*.framework; do
    [[ -d "$framework" ]] || continue
    while IFS= read -r -d '' executable; do
      codesign "${CODESIGN_ARGS[@]}" "$executable"
    done < <(find "$framework" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$framework"
  done
}

sign_resource_bundles() {
  local bundle
  while IFS= read -r -d '' bundle; do
    codesign "${CODESIGN_ARGS[@]}" "$bundle"
  done < <(find "$APP/Contents/Resources" -type d -name '*.bundle' -prune -print0)
}

sign_frameworks
sign_resource_bundles
codesign "${CODESIGN_ARGS[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Created $APP"
codesign -dr - "$APP" 2>&1 | tail -1
