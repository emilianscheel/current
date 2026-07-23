#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
ASSEMBLE_ONLY=false
if [[ "${1:-}" == "--assemble-only" ]]; then ASSEMBLE_ONLY=true; shift; fi
if (( $# > 0 )); then print -u2 "Usage: $0 [--assemble-only]"; exit 64; fi

if [[ "$(uname -m)" != "arm64" ]]; then
  print -u2 "Current requires Apple silicon (arm64)."
  exit 1
fi

OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( OS_MAJOR < 26 )); then
  print -u2 "Current requires macOS 26 or newer."
  exit 1
fi

command -v swift >/dev/null || { print -u2 "Swift is required."; exit 1; }
command -v codesign >/dev/null || { print -u2 "codesign is required."; exit 1; }

CHIP_NAME="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip:/{print $2; exit}')"
if [[ ! "$CHIP_NAME" =~ 'Apple M([0-9]+)' ]] || (( match[1] < 3 )); then
  print -u2 "Current requires an Apple M3 or newer chip (found: ${CHIP_NAME:-unknown})."
  exit 1
fi
MEMORY_BYTES="$(sysctl -n hw.memsize)"
if (( MEMORY_BYTES < 17179869184 )); then
  print -u2 "Current requires at least 16 GiB of unified memory."
  exit 1
fi

USER_NAME="$(id -un)"
USER_HOME_DIR="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
[[ -n "$USER_HOME_DIR" && "$USER_HOME_DIR" == /* ]] || { print -u2 "Could not resolve the user home directory."; exit 1; }
INSTALL_DIR="$USER_HOME_DIR/Applications"
INSTALL_APP="$INSTALL_DIR/Current.app"
PREVIOUS_APP="$INSTALL_DIR/Current.previous.app"
STAGE_APP="$PROJECT_DIR/.build/Current.app-staging"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
KEYCHAIN_PATH="$(security default-keychain -d user | tr -d '"')"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swiftpm-module-cache"

find_identity() {
  local apple local_identity
  # Use the certificate's unique SHA-1 identity instead of its display name.
  # Keychain can contain multiple Apple Development certificates with the same
  # label, which makes `codesign --sign "Apple Development: …"` ambiguous.
  apple="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2; exit}')"
  if [[ -n "$apple" ]]; then print -r -- "$apple"; return; fi
  local_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Current Local Development"/{print $2; exit}')"
  print -r -- "$local_identity"
}

create_local_identity() {
  local certificate_dir certificate_password
  certificate_dir="$(mktemp -d "${TMPDIR%/}/current-signing.XXXXXX")"
  certificate_password="$(uuidgen)"
  trap '[[ -n "${certificate_dir:-}" ]] && rm -rf "$certificate_dir"' EXIT
  print "No Apple Development identity found. Creating the persistent Current Local Development identity…"
  openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -subj "/CN=Current Local Development/O=Current Local Development/OU=Local Code Signing" \
    -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" \
    -keyout "$certificate_dir/key.pem" -out "$certificate_dir/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export -legacy -inkey "$certificate_dir/key.pem" -in "$certificate_dir/cert.pem" \
    -out "$certificate_dir/identity.p12" -passout "pass:$certificate_password" >/dev/null 2>&1
  security import "$certificate_dir/identity.p12" -k "$KEYCHAIN_PATH" -P "$certificate_password" -T /usr/bin/codesign >/dev/null
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN_PATH" "$certificate_dir/cert.pem"
}

if $ASSEMBLE_ONLY; then
  SIGNING_IDENTITY="-"
else
  SIGNING_IDENTITY="$(find_identity)"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    create_local_identity
    SIGNING_IDENTITY="$(find_identity)"
  fi
  [[ -n "$SIGNING_IDENTITY" ]] || { print -u2 "Unable to create a valid code-signing identity. Open Keychain Access and trust Current Local Development for code signing."; exit 1; }
fi
print "Signing with identity: $SIGNING_IDENTITY"

print "Running tests…"
swift test --disable-sandbox
print "Building release binaries…"
swift build --disable-sandbox -c release --arch arm64
BIN_DIR="$(swift build --disable-sandbox -c release --arch arm64 --show-bin-path)"

print "Creating the app icon from icon.png…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/.build/AppIcon.icns"

rm -rf "$STAGE_APP"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Helpers" "$STAGE_APP/Contents/Resources"
cp Packaging/Info.plist "$STAGE_APP/Contents/Info.plist"
cp "$BIN_DIR/Current" "$STAGE_APP/Contents/MacOS/Current"
cp "$BIN_DIR/CurrentRelauncher" "$STAGE_APP/Contents/Helpers/CurrentRelauncher"
cp "$PROJECT_DIR/.build/AppIcon.icns" "$STAGE_APP/Contents/Resources/AppIcon.icns"
cp Sources/Current/Resources/model-manifest.json Sources/Current/Resources/Privacy.md Licenses/NOTICE.md "$STAGE_APP/Contents/Resources/"
for resource_bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$resource_bundle" "$STAGE_APP/Contents/Resources/"; done

codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN_PATH" --sign "$SIGNING_IDENTITY" "$STAGE_APP/Contents/Helpers/CurrentRelauncher"
codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN_PATH" --entitlements Packaging/Current.entitlements --sign "$SIGNING_IDENTITY" "$STAGE_APP"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

if $ASSEMBLE_ONLY; then
  print "Assembly verified at $STAGE_APP (not installed or launched)."
  exit 0
fi

print "Installing without resetting TCC permissions or Current preferences…"
pkill -TERM -x Current 2>/dev/null || true
for _ in {1..30}; do pgrep -x Current >/dev/null || break; sleep 0.1; done
mkdir -p "$INSTALL_DIR"
if [[ -e "$PREVIOUS_APP" ]]; then rm -rf "$PREVIOUS_APP"; fi
if [[ -e "$INSTALL_APP" ]]; then mv "$INSTALL_APP" "$PREVIOUS_APP"; fi
mv "$STAGE_APP" "$INSTALL_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALL_APP"
open -n "$INSTALL_APP"
print "Installed and launched $INSTALL_APP"
print "Permissions persist while the signing identity, bundle identifier, and install path remain unchanged."
