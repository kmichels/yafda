#!/bin/bash
# Creates a self-signed code-signing certificate "WhisperFlow Dev" in the
# login keychain, so rebuilds keep the same signature and macOS permission
# grants (Accessibility) survive. Idempotent.
#
# The name is two renames out of date (WhisperFlow -> Murmur -> Mutter) and
# must stay that way: the cert leaf forms half the TCC designated requirement,
# so reissuing it under a current name would drop every permission grant.
set -euo pipefail

NAME="WhisperFlow Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Signing identity '$NAME' already exists."
    exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -config cert.cnf

openssl pkcs12 -export -legacy -out identity.p12 \
    -inkey key.pem -in cert.pem -passout pass:whisperflow 2>/dev/null \
 || openssl pkcs12 -export -out identity.p12 \
    -inkey key.pem -in cert.pem -passout pass:whisperflow

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import identity.p12 -k "$KEYCHAIN" -P whisperflow \
    -T /usr/bin/codesign -T /usr/bin/security

# Mark the certificate trusted for code signing (may show an auth prompt).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" cert.pem

echo "Created signing identity '$NAME'."
