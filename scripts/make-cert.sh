#!/bin/sh
# Optional local-development setup: create a self-signed "ClaudeUsageBar" identity.
# Normal builds use ad-hoc signing. This identity is not a Developer ID certificate
# and is not needed for the app's current Claude authentication method.
#
# Expect two prompts: your login password for the keychain partition list (terminal), and a
# system dialog to trust the certificate for code signing.
set -eu
umask 077
NAME=ClaudeUsageBar
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Certificate \"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $NAME
[ext]
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
export CERT_PASSWORD="$(openssl rand -hex 24)"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout env:CERT_PASSWORD

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
echo "Enter your Mac login password so codesign may use the new key without prompting:"
security set-key-partition-list -S apple-tool:,apple: -s "$KEYCHAIN" >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created and trusted certificate \"$NAME\"."
echo "Build from the repository root with MR_USAGE_SIGN_IDENTITY=\"$NAME\" ./scripts/build.sh"
