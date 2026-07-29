#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
ASSEMBLE_ONLY=false
APP_VERSION=""
while (( $# > 0 )); do
  case "$1" in
    --assemble-only)
      ASSEMBLE_ONLY=true
      shift
      ;;
    --version)
      (( $# >= 2 )) || { print -u2 "Missing value for --version."; exit 64; }
      APP_VERSION="$2"
      shift 2
      ;;
    *)
      print -u2 "Usage: $0 [--assemble-only [--version X.Y.Z]]"
      exit 64
      ;;
  esac
done
if [[ -n "$APP_VERSION" && "$ASSEMBLE_ONLY" != true ]]; then
  print -u2 "--version is only supported with --assemble-only."
  exit 64
fi
if [[ -n "$APP_VERSION" && ! "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Version must use X.Y.Z numeric format."
  exit 64
fi

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
command -v openssl >/dev/null || { print -u2 "OpenSSL is required."; exit 1; }

if ! $ASSEMBLE_ONLY; then
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
fi

STAGE_APP="$PROJECT_DIR/.build/Current.app-staging"
ICON_BUILD_DIR="$PROJECT_DIR/.build/AppIcon-assets"
ICON_PARTIAL_INFO_PLIST="$ICON_BUILD_DIR/partial-info.plist"
XCODE_DERIVED_DATA="$PROJECT_DIR/.build/xcode-derived"
BUILD_VERSION="${APP_VERSION:-$(date -u +%Y%m%d%H%M%S)}"
typeset -a CODESIGN_KEYCHAIN_ARGS
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swiftpm-module-cache"

find_usable_apple_identity() {
  local identity_line identity_hash identity_name certificate_dir certificate_list certificate_file certificate_hash verification_error
  while IFS= read -r identity_line; do
    if [[ ! "$identity_line" =~ '^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(Apple Development:[^"]+)"' ]]; then
      continue
    fi
    identity_hash="${match[1]:u}"
    identity_name="${match[2]}"
    certificate_dir="$(mktemp -d "${TMPDIR%/}/current-identity.XXXXXX")"
    certificate_list="$certificate_dir/certificates.pem"
    security find-certificate -a -c "$identity_name" -p "$KEYCHAIN_PATH" > "$certificate_list"
    awk -v output_dir="$certificate_dir" '
      /-----BEGIN CERTIFICATE-----/ {
        certificate_index += 1
        output_file = sprintf("%s/certificate-%03d.pem", output_dir, certificate_index)
      }
      certificate_index > 0 { print > output_file }
    ' "$certificate_list"

    for certificate_file in "$certificate_dir"/certificate-*.pem(N); do
      certificate_hash="$(openssl x509 -in "$certificate_file" -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//; s/://g' | tr '[:lower:]' '[:upper:]')"
      [[ "$certificate_hash" == "$identity_hash" ]] || continue
      if verification_error="$(security verify-cert -c "$certificate_file" -k "$KEYCHAIN_PATH" -p codeSign -R ocsp -R require -q 2>&1)"; then
        rm -rf "$certificate_dir"
        print -r -- "$identity_hash"
        return 0
      fi
      print -u2 "Skipping Apple Development identity $identity_hash ($identity_name): required OCSP code-signing validation failed."
      if [[ -n "$verification_error" ]]; then
        print -u2 -- "$verification_error"
      fi
      break
    done
    rm -rf "$certificate_dir"
  done < <(security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null)
}

find_local_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
    | awk '/"Current Local Development"/{print $2; exit}'
}

create_local_identity() {
  local certificate_dir certificate_password
  typeset -a pkcs12_compatibility_args
  certificate_dir="$(mktemp -d "${TMPDIR%/}/current-signing.XXXXXX")"
  certificate_password="$(uuidgen)"
  trap '[[ -n "${certificate_dir:-}" ]] && rm -rf "$certificate_dir"' EXIT
  print "No usable Apple Development identity found. Creating the persistent Current Local Development identity…"
  openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -subj "/CN=Current Local Development/O=Current Local Development/OU=Local Code Signing" \
    -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" \
    -keyout "$certificate_dir/key.pem" -out "$certificate_dir/cert.pem" >/dev/null 2>&1
  pkcs12_compatibility_args=()
  if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    pkcs12_compatibility_args=(-legacy)
  fi
  openssl pkcs12 -export "${pkcs12_compatibility_args[@]}" -inkey "$certificate_dir/key.pem" -in "$certificate_dir/cert.pem" \
    -out "$certificate_dir/identity.p12" -passout "pass:$certificate_password" >/dev/null 2>&1
  security import "$certificate_dir/identity.p12" -k "$KEYCHAIN_PATH" -P "$certificate_password" -T /usr/bin/codesign >/dev/null
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN_PATH" "$certificate_dir/cert.pem"
}

if $ASSEMBLE_ONLY; then
  SIGNING_IDENTITY="-"
  CODESIGN_KEYCHAIN_ARGS=()
else
  USER_NAME="$(id -un)"
  USER_HOME_DIR="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
  [[ -n "$USER_HOME_DIR" && "$USER_HOME_DIR" == /* ]] || { print -u2 "Could not resolve the user home directory."; exit 1; }
  INSTALL_DIR="$USER_HOME_DIR/Applications"
  INSTALL_APP="$INSTALL_DIR/Current.app"
  PREVIOUS_APP="$INSTALL_DIR/Current.previous.app"
  KEYCHAIN_PATH="$(security default-keychain -d user | awk -F'"' 'NF >= 2 { print $2; exit }')"
  [[ -n "$KEYCHAIN_PATH" && "$KEYCHAIN_PATH" == /* ]] || { print -u2 "Could not resolve the default user Keychain."; exit 1; }
  CODESIGN_KEYCHAIN_ARGS=(--keychain "$KEYCHAIN_PATH")
  SIGNING_IDENTITY="$(find_usable_apple_identity)"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(find_local_identity)"
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    create_local_identity
    SIGNING_IDENTITY="$(find_local_identity)"
  fi
  [[ -n "$SIGNING_IDENTITY" ]] || { print -u2 "Unable to create a valid code-signing identity. Open Keychain Access and trust Current Local Development for code signing."; exit 1; }
fi
print "Signing with identity: $SIGNING_IDENTITY"

print "Running tests…"
swift test --disable-sandbox
print "Building release binaries…"
swift build --disable-sandbox -c release --arch arm64
BIN_DIR="$(swift build --disable-sandbox -c release --arch arm64 --show-bin-path)"

if ! xcrun --sdk macosx metal --version >/dev/null 2>&1; then
  print -u2 "Apple's Metal Toolchain is required to package MLX."
  print -u2 "Install it with: xcodebuild -downloadComponent MetalToolchain"
  exit 1
fi

print "Compiling MLX Metal resources with Xcode…"
xcodebuild \
  -quiet \
  -scheme Current \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$XCODE_DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
MLX_RESOURCE_BUNDLE="$XCODE_DERIVED_DATA/Build/Products/Release/mlx-swift_Cmlx.bundle"
MLX_DEFAULT_LIBRARY="$MLX_RESOURCE_BUNDLE/Contents/Resources/default.metallib"
if [[ ! -f "$MLX_DEFAULT_LIBRARY" ]]; then
  print -u2 "Xcode did not produce MLX's required default.metallib resource."
  exit 1
fi

print "Compiling the adaptive app icon with Xcode…"
rm -rf "$ICON_BUILD_DIR"
mkdir -p "$ICON_BUILD_DIR"
xcrun actool \
  --compile "$ICON_BUILD_DIR" \
  --output-format human-readable-text \
  --warnings \
  --errors \
  --notices \
  --output-partial-info-plist "$ICON_PARTIAL_INFO_PLIST" \
  --app-icon AppIcon \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --target-device mac \
  --standalone-icon-behavior all \
  "$PROJECT_DIR/AppIcon.icon"
[[ -f "$ICON_BUILD_DIR/Assets.car" ]] || { print -u2 "App icon compilation did not produce Assets.car."; exit 1; }
[[ -f "$ICON_BUILD_DIR/AppIcon.icns" ]] || { print -u2 "App icon compilation did not produce AppIcon.icns."; exit 1; }
[[ -f "$ICON_PARTIAL_INFO_PLIST" ]] || { print -u2 "App icon compilation did not produce bundle metadata."; exit 1; }

rm -rf "$STAGE_APP"
WORKER_BUNDLE="$STAGE_APP/Contents/XPCServices/CurrentContextWorker.xpc"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Helpers" "$STAGE_APP/Contents/Resources" \
  "$WORKER_BUNDLE/Contents/MacOS" "$WORKER_BUNDLE/Contents/Resources"
cp Packaging/Info.plist "$STAGE_APP/Contents/Info.plist"
for ICON_KEY in CFBundleIconFile CFBundleIconName; do
  ICON_VALUE="$(plutil -extract "$ICON_KEY" raw "$ICON_PARTIAL_INFO_PLIST")"
  if plutil -extract "$ICON_KEY" raw "$STAGE_APP/Contents/Info.plist" >/dev/null 2>&1; then
    plutil -replace "$ICON_KEY" -string "$ICON_VALUE" "$STAGE_APP/Contents/Info.plist"
  else
    plutil -insert "$ICON_KEY" -string "$ICON_VALUE" "$STAGE_APP/Contents/Info.plist"
  fi
done
if [[ -n "$APP_VERSION" ]]; then
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$STAGE_APP/Contents/Info.plist"
fi
# Finder caches an app's icon by bundle identifier, path, and build version. Local
# installs reuse the first two, so every assembled bundle needs a fresh version.
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$STAGE_APP/Contents/Info.plist"
cp "$BIN_DIR/Current" "$STAGE_APP/Contents/MacOS/Current"
cp "$BIN_DIR/CurrentRelauncher" "$STAGE_APP/Contents/Helpers/CurrentRelauncher"
cp Packaging/ContextWorker-Info.plist "$WORKER_BUNDLE/Contents/Info.plist"
cp "$BIN_DIR/CurrentContextWorker" "$WORKER_BUNDLE/Contents/MacOS/CurrentContextWorker"
cp "$ICON_BUILD_DIR/AppIcon.icns" "$ICON_BUILD_DIR/Assets.car" "$STAGE_APP/Contents/Resources/"
cp Sources/Current/Resources/model-manifest.json Sources/Current/Resources/Privacy.md Licenses/NOTICE.md "$STAGE_APP/Contents/Resources/"
for resource_bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$resource_bundle" "$STAGE_APP/Contents/Resources/"; done
cp -R "$MLX_RESOURCE_BUNDLE" "$STAGE_APP/Contents/Resources/"
cp -R "$MLX_RESOURCE_BUNDLE" "$WORKER_BUNDLE/Contents/Resources/"
[[ -f "$STAGE_APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
  print -u2 "Packaged app is missing MLX's required default.metallib resource."
  exit 1
}
[[ -f "$WORKER_BUNDLE/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
  print -u2 "Packaged context worker is missing MLX's required default.metallib resource."
  exit 1
}

codesign --force --options runtime --timestamp=none "${CODESIGN_KEYCHAIN_ARGS[@]}" --sign "$SIGNING_IDENTITY" "$STAGE_APP/Contents/Helpers/CurrentRelauncher"
codesign --force --options runtime --timestamp=none "${CODESIGN_KEYCHAIN_ARGS[@]}" --sign "$SIGNING_IDENTITY" "$WORKER_BUNDLE"
codesign --force --options runtime --timestamp=none "${CODESIGN_KEYCHAIN_ARGS[@]}" --entitlements Packaging/Current.entitlements --sign "$SIGNING_IDENTITY" "$STAGE_APP"
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
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
fi
open -n "$INSTALL_APP"
print "Installed and launched $INSTALL_APP"
print "Permissions persist while the signing identity, bundle identifier, and install path remain unchanged."
