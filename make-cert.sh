#!/bin/sh
# One-time setup: create a self-signed code-signing certificate named "ClaudeUsageBar".
#
# Why: build.sh otherwise signs ad-hoc, and an ad-hoc identity is a hash of the binary, so
# every rebuild looks like a new app to the Keychain and "Always Allow" does not carry over.
# Signing with a certificate gives the app a stable identity across rebuilds, so macOS asks
# for the Keychain password once, ever.
#
# Expect two prompts: your login password for the keychain partition list (terminal), and a
# system dialog to trust the certificate for code signing.
set -eu
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
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout pass:tmp

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign >/dev/null
echo "Enter your Mac login password so codesign may use the new key without prompting:"
security set-key-partition-list -S apple-tool:,apple: -s "$KEYCHAIN" >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created and trusted certificate \"$NAME\". Now run ./build.sh"
