#!/usr/bin/env bash
# Creates a persistent local code-signing identity so macOS TCC permissions
# (notably Accessibility) survive app rebuilds.
set -euo pipefail

APP_NAME=${APP_NAME:-Lumen}
IDENTITY_NAME=${LOCAL_SIGNING_IDENTITY_NAME:-${APP_NAME} Local Code Signing}
SIGNING_DIR=${LOCAL_SIGNING_DIR:-"$HOME/Library/Application Support/${APP_NAME} Development Signing"}
KEYCHAIN="$SIGNING_DIR/${APP_NAME}CodeSigning.keychain"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
OPENSSL_CONFIG="$SIGNING_DIR/openssl.cnf"

log() { printf '%s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

identity_hash() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") { print $2; exit }'
}

ensure_keychain_is_searchable() {
  local listing path
  local keychains=()
  listing=$(security list-keychains -d user)
  if [[ "$listing" == *"\"$KEYCHAIN\""* ]]; then
    return
  fi

  while IFS= read -r path; do
    path=${path#\"}
    path=${path%\"}
    [[ -n "$path" ]] && keychains+=("$path")
  done < <(printf '%s\n' "$listing" | sed -E 's/^[[:space:]]*//')

  security list-keychains -d user -s "$KEYCHAIN" "${keychains[@]}"
}

create_identity() {
  command -v openssl >/dev/null 2>&1 || fail "openssl is required to create the local signing identity."
  command -v certtool >/dev/null 2>&1 || fail "certtool is required to create the local signing keychain."

  log "==> Creating persistent local signing identity: $IDENTITY_NAME"
  mkdir -p "$SIGNING_DIR"
  chmod 700 "$SIGNING_DIR"

  local password temp_dir private_key csr certificate
  password=$(openssl rand -hex 32)
  printf '%s' "$password" > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"

  cat > "$OPENSSL_CONFIG" <<EOF
[ req ]
distinguished_name = req_dn
prompt = no

[ req_dn ]
CN = $IDENTITY_NAME
O = $APP_NAME Local Development

[ codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  chmod 600 "$OPENSSL_CONFIG"

  temp_dir=$(mktemp -d)
  private_key="$temp_dir/key.rsa"
  csr="$temp_dir/key.csr"
  certificate="$temp_dir/key.crt"
  trap 'rm -rf "${temp_dir:-}"' RETURN

  if openssl version 2>/dev/null | grep -q '^OpenSSL 3'; then
    openssl genrsa -traditional -out "$private_key" 2048 >/dev/null 2>&1
  else
    openssl genrsa -out "$private_key" 2048 >/dev/null 2>&1
  fi
  openssl req -new -key "$private_key" -out "$csr" -config "$OPENSSL_CONFIG" >/dev/null 2>&1
  openssl x509 -req -days 3650 -in "$csr" -signkey "$private_key" \
    -out "$certificate" -extfile "$OPENSSL_CONFIG" -extensions codesign >/dev/null 2>&1

  rm -f "$KEYCHAIN" "$KEYCHAIN-db"
  certtool i "$certificate" k="$KEYCHAIN" r="$private_key" f=1 c p="$password" >/dev/null
  security set-keychain-settings -lut 300 "$KEYCHAIN"
  security unlock-keychain -p "$password" "$KEYCHAIN"
  ensure_keychain_is_searchable
  chmod 600 "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$temp_dir"
  trap - RETURN
}

ensure_identity() {
  local hash=""
  if [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]]; then
    security unlock-keychain -p "$(<"$PASSWORD_FILE")" "$KEYCHAIN" 2>/dev/null || true
    ensure_keychain_is_searchable
    hash=$(identity_hash)
  fi

  if [[ -z "$hash" ]]; then
    create_identity
    hash=$(identity_hash)
  fi

  [[ -n "$hash" ]] || fail "The local signing identity could not be created."
  printf '%s' "$hash"
}

case "${1:---print-env}" in
  --print-env)
    hash=$(ensure_identity)
    printf 'APP_IDENTITY=%s\n' "$(shell_quote "$hash")"
    printf 'APP_KEYCHAIN=%s\n' "$(shell_quote "$KEYCHAIN")"
    printf 'APP_KEYCHAIN_PASSWORD_FILE=%s\n' "$(shell_quote "$PASSWORD_FILE")"
    ;;
  --identity)
    ensure_identity
    printf '\n'
    ;;
  *)
    fail "Usage: $(basename "$0") [--print-env|--identity]"
    ;;
esac
