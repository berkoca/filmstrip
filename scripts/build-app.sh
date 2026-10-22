#!/bin/bash
# Builds Filmstrip.app into ./build.
#
#   scripts/build-app.sh            release build for this Mac
#   scripts/build-app.sh debug      debug build
#   UNIVERSAL=1 scripts/build-app.sh   Apple silicon + Intel (needs full Xcode)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Signing: SIGN_IDENTITY if set, otherwise the "Filmstrip Development" certificate made by
# scripts/setup-signing.sh, otherwise ad hoc. macOS ties the Accessibility permission to
# the signature, and an ad-hoc signature changes with every build, so with ad-hoc signing
# you have to grant the permission again after each rebuild. Run setup-signing.sh once to
# avoid that.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

# Quit a running copy first, so it puts parked windows back before its binary is replaced.
# ("Strip" was this project's working name; a copy from back then is quit too.)
for NAME in Filmstrip Strip; do
  if pgrep -x "$NAME" >/dev/null; then
    echo "Quitting the running $NAME…"
    pkill -TERM -x "$NAME" || true
    sleep 1
  fi
done

APP="build/Filmstrip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Filmstrip" "$APP/Contents/MacOS/Filmstrip"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # "Strip Development" is the certificate's name from the project's working-name days.
  for CERT in "Filmstrip Development" "Strip Development"; do
    if security find-certificate -c "$CERT" >/dev/null 2>&1; then
      IDENTITY="$CERT"
      break
    fi
  done
fi
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with \"$IDENTITY\""
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "Signing ad hoc (run scripts/setup-signing.sh once to keep the Accessibility permission across rebuilds)"
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
