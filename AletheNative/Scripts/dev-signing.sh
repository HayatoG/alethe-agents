#!/usr/bin/env bash
# Prints the code-signing identity local builds should use.
#
# Local builds sign with ONE stable self-signed identity so the designated requirement never
# changes between builds; otherwise macOS treats every build as a new app and Keychain items
# prompt again (the first native attempt was blocked by those prompts).
#
#   Scripts/dev-signing.sh            -> prints the identity name, or "-" (ad hoc) if missing
#   Scripts/dev-signing.sh --create   -> creates the identity in the login keychain (asks for
#                                        your password to trust it for code signing)
set -euo pipefail
IDENTITY="${ALETHE_SIGN_IDENTITY:-Alethe Dev Signing}"

has_identity() {
  security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""
}

if [[ "${1:-}" == "--create" ]]; then
  if has_identity; then echo "Identity already exists: $IDENTITY"; exit 0; fi
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:alethe >/dev/null 2>&1
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P alethe -T /usr/bin/codesign
  security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
  echo "Created identity: $IDENTITY"
  exit 0
fi

if has_identity; then
  echo "$IDENTITY"
else
  echo "warning: signing identity '$IDENTITY' not found; building ad hoc (no hardened runtime)." >&2
  echo "         run Scripts/dev-signing.sh --create once to set it up." >&2
  echo "-"
fi
