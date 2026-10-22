#!/bin/bash
# One-time setup: creates a self-signed "Filmstrip Development" code signing certificate in
# your login keychain. build-app.sh signs with it automatically, so the Accessibility
# permission stays valid across rebuilds (with ad-hoc signing macOS forgets it every build).
#
# macOS asks for your login password once, to trust the certificate for code signing.
set -euo pipefail

NAME="Filmstrip Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # Apple's LibreSSL: its .p12 files import cleanly with `security`

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/strip.p12" -passout pass:strip

security import "$WORK/strip.p12" -k "$KEYCHAIN" -P strip -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS will ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "Done. Now run scripts/build-app.sh, then give Filmstrip Accessibility access one last time:"
echo "remove the old Filmstrip entry with the minus button, add build/Filmstrip.app again."
