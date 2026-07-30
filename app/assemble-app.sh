#!/bin/zsh
set -euo pipefail

SCRIPT_PATH="$0"
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"

SIGNING_MODE=""
SIGNING_IDENTITY=""
KEYCHAIN_PATH=""
APP_VERSION=""
BUILD_VERSION="$(date -u +%Y%m%d%H%M%S)"

usage() {
  print -u2 "Usage: $SCRIPT_PATH --signing-mode adhoc|development|distribution --signing-identity ID [--keychain PATH] [--version X.Y.Z] [--build-version N]"
}

die() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

while (( $# > 0 )); do
  case "$1" in
    --signing-mode)
      (( $# >= 2 )) || die "Missing value for --signing-mode." 64
      SIGNING_MODE="$2"
      shift 2
      ;;
    --signing-identity)
      (( $# >= 2 )) || die "Missing value for --signing-identity." 64
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --keychain)
      (( $# >= 2 )) || die "Missing value for --keychain." 64
      KEYCHAIN_PATH="$2"
      shift 2
      ;;
    --version)
      (( $# >= 2 )) || die "Missing value for --version." 64
      APP_VERSION="$2"
      shift 2
      ;;
    --build-version)
      (( $# >= 2 )) || die "Missing value for --build-version." 64
      BUILD_VERSION="$2"
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[[ "$SIGNING_MODE" == "adhoc" || "$SIGNING_MODE" == "development" || "$SIGNING_MODE" == "distribution" ]] || {
  usage
  exit 64
}
[[ -n "$SIGNING_IDENTITY" ]] || die "A signing identity is required." 64
[[ -z "$APP_VERSION" || "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "Version must use X.Y.Z numeric format." 64
[[ "$BUILD_VERSION" =~ '^[0-9]+$' ]] || die "Build version must be a positive integer." 64
(( BUILD_VERSION > 0 )) || die "Build version must be a positive integer." 64
[[ -z "$KEYCHAIN_PATH" || "$KEYCHAIN_PATH" == /* ]] || die "Keychain path must be absolute." 64

[[ "$(uname -m)" == "arm64" ]] || die "Current requires Apple silicon (arm64)."
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( OS_MAJOR >= 26 )) || die "Current requires macOS 26 or newer."

for required_command in swift codesign xcrun xcodebuild plutil file; do
  command -v "$required_command" >/dev/null || die "$required_command is required."
done

STAGE_APP="$PROJECT_DIR/.build/Current.app-staging"
ICON_BUILD_DIR="$PROJECT_DIR/.build/AppIcon-assets"
ICON_PARTIAL_INFO_PLIST="$ICON_BUILD_DIR/partial-info.plist"
XCODE_DERIVED_DATA="$PROJECT_DIR/.build/xcode-derived"
typeset -a CODESIGN_KEYCHAIN_ARGS CODESIGN_TIMESTAMP_ARGS
CODESIGN_KEYCHAIN_ARGS=()
[[ -z "$KEYCHAIN_PATH" ]] || CODESIGN_KEYCHAIN_ARGS=(--keychain "$KEYCHAIN_PATH")
if [[ "$SIGNING_MODE" == "distribution" ]]; then
  [[ "$SIGNING_IDENTITY" != "-" ]] || die "Distribution builds cannot use ad-hoc signing."
  CODESIGN_TIMESTAMP_ARGS=(--timestamp)
else
  CODESIGN_TIMESTAMP_ARGS=(--timestamp=none)
fi

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swiftpm-module-cache"

patch_fluid_audio_manifest() {
  local manifest benchmark exclusion
  manifest="$PROJECT_DIR/.build/checkouts/FluidAudio/Package.swift"
  benchmark="$PROJECT_DIR/.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Unified/benchmark.md"
  exclusion='            exclude: ["ASR/Parakeet/Unified/benchmark.md"]'

  [[ -f "$manifest" && -f "$benchmark" ]] || die "FluidAudio 0.15.5 did not resolve with the expected layout."
  if grep -Fqx "$exclusion" "$manifest"; then
    return
  fi
  grep -Fqx '            path: "Sources/FluidAudio"' "$manifest" || {
    die "FluidAudio's package manifest changed; refusing to apply the benchmark exclusion automatically."
  }

  # FluidAudio 0.15.5 ships this documentation file inside its library target
  # without declaring it. Patch only the resolved checkout, never tracked code.
  /usr/bin/perl -0pi -e \
    's/            path: "Sources\/FluidAudio"\n/            path: "Sources\/FluidAudio",\n            exclude: ["ASR\/Parakeet\/Unified\/benchmark.md"]\n/' \
    "$manifest"
  grep -Fqx "$exclusion" "$manifest" || die "Failed to exclude FluidAudio's benchmark documentation from its library target."
}

sign_code() {
  codesign --force --options runtime "${CODESIGN_TIMESTAMP_ARGS[@]}" "${CODESIGN_KEYCHAIN_ARGS[@]}" --sign "$SIGNING_IDENTITY" "$1"
}

print "Signing mode: $SIGNING_MODE"
print "Signing with identity: $SIGNING_IDENTITY"
print "Resolving dependencies…"
swift package resolve
patch_fluid_audio_manifest

print "Running tests…"
swift test --disable-sandbox
print "Building release binaries…"
swift build --disable-sandbox -c release --arch arm64
BIN_DIR="$(swift build --disable-sandbox -c release --arch arm64 --show-bin-path)"

if ! xcrun --sdk macosx metal --version >/dev/null 2>&1; then
  die $'Apple\'s Metal Toolchain is required to package MLX.\nInstall it with: xcodebuild -downloadComponent MetalToolchain'
fi

print "Compiling MLX Metal resources with Xcode (this can take a few minutes on the first build)…"
xcodebuild \
  -quiet \
  -scheme Current \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$XCODE_DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build &
XCODEBUILD_PID=$!
XCODEBUILD_SECONDS=0
while kill -0 "$XCODEBUILD_PID" 2>/dev/null; do
  sleep 1
  (( XCODEBUILD_SECONDS += 1 ))
  if (( XCODEBUILD_SECONDS % 10 == 0 )) && kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
    print "Still compiling MLX Metal resources (${XCODEBUILD_SECONDS}s elapsed)…"
  fi
done
wait "$XCODEBUILD_PID" || die "Xcode failed to compile MLX's Metal resources."

MLX_RESOURCE_BUNDLE="$XCODE_DERIVED_DATA/Build/Products/Release/mlx-swift_Cmlx.bundle"
MLX_DEFAULT_LIBRARY="$MLX_RESOURCE_BUNDLE/Contents/Resources/default.metallib"
[[ -f "$MLX_DEFAULT_LIBRARY" ]] || die "Xcode did not produce MLX's required default.metallib resource."

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
[[ -f "$ICON_BUILD_DIR/Assets.car" ]] || die "App icon compilation did not produce Assets.car."
[[ -f "$ICON_BUILD_DIR/AppIcon.icns" ]] || die "App icon compilation did not produce AppIcon.icns."
[[ -f "$ICON_PARTIAL_INFO_PLIST" ]] || die "App icon compilation did not produce bundle metadata."

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
cp Packaging/ContextWorker-Info.plist "$WORKER_BUNDLE/Contents/Info.plist"
if [[ -n "$APP_VERSION" ]]; then
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$STAGE_APP/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$WORKER_BUNDLE/Contents/Info.plist"
fi
# Finder caches local app icons by bundle identifier, path, and build version,
# so development builds retain timestamp-based build numbers. Releases inject a
# monotonically increasing numeric build number from Git history.
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$STAGE_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$WORKER_BUNDLE/Contents/Info.plist"

cp "$BIN_DIR/Current" "$STAGE_APP/Contents/MacOS/Current"
cp "$BIN_DIR/CurrentRelauncher" "$STAGE_APP/Contents/Helpers/CurrentRelauncher"
cp "$BIN_DIR/CurrentContextWorker" "$WORKER_BUNDLE/Contents/MacOS/CurrentContextWorker"
cp "$ICON_BUILD_DIR/AppIcon.icns" "$ICON_BUILD_DIR/Assets.car" "$STAGE_APP/Contents/Resources/"
cp Sources/Current/Resources/model-manifest.json Sources/Current/Resources/Privacy.md Licenses/NOTICE.md "$STAGE_APP/Contents/Resources/"
for resource_bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$resource_bundle" "$STAGE_APP/Contents/Resources/"; done
cp -R "$MLX_RESOURCE_BUNDLE" "$STAGE_APP/Contents/Resources/"
cp -R "$MLX_RESOURCE_BUNDLE" "$WORKER_BUNDLE/Contents/Resources/"
[[ -f "$STAGE_APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
  die "Packaged app is missing MLX's required default.metallib resource."
}
[[ -f "$WORKER_BUNDLE/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
  die "Packaged context worker is missing MLX's required default.metallib resource."
}

plutil -lint Packaging/Current.entitlements >/dev/null || die "Current.entitlements is not a valid property list."

# Sign every Mach-O payload first, followed by its containing XPC bundle and
# finally the app bundle. This makes the order explicit and keeps --deep for
# verification only.
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    sign_code "$candidate"
  fi
done < <(find "$STAGE_APP/Contents" -type f -perm -111 -print0)
sign_code "$WORKER_BUNDLE"
codesign --force --options runtime "${CODESIGN_TIMESTAMP_ARGS[@]}" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
  --entitlements Packaging/Current.entitlements --sign "$SIGNING_IDENTITY" "$STAGE_APP"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

if [[ "$SIGNING_MODE" == "distribution" ]]; then
  for signed_item in \
    "$STAGE_APP/Contents/MacOS/Current" \
    "$STAGE_APP/Contents/Helpers/CurrentRelauncher" \
    "$WORKER_BUNDLE/Contents/MacOS/CurrentContextWorker" \
    "$WORKER_BUNDLE" \
    "$STAGE_APP"; do
    SIGNATURE_DETAILS="$(codesign -dvvv "$signed_item" 2>&1)"
    [[ "$SIGNATURE_DETAILS" == *"Authority=Developer ID Application:"* ]] || die "$signed_item is not signed with a Developer ID Application identity."
    [[ "$SIGNATURE_DETAILS" == *"Timestamp="* ]] || die "$signed_item has no secure timestamp."
    [[ "$SIGNATURE_DETAILS" == *"runtime"* ]] || die "$signed_item does not enable Hardened Runtime."
  done

  EMBEDDED_ENTITLEMENTS="$PROJECT_DIR/.build/Current.release-entitlements.plist"
  codesign -d --entitlements :- "$STAGE_APP" > "$EMBEDDED_ENTITLEMENTS" 2>/dev/null
  plutil -lint "$EMBEDDED_ENTITLEMENTS" >/dev/null || die "The assembled app has malformed embedded entitlements."
  AUDIO_INPUT="$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - "$EMBEDDED_ENTITLEMENTS" 2>/dev/null || true)"
  [[ "$AUDIO_INPUT" == "true" ]] || die "The distribution app is missing the audio-input entitlement."
  GET_TASK_ALLOW="$(plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - "$EMBEDDED_ENTITLEMENTS" 2>/dev/null || true)"
  [[ "$GET_TASK_ALLOW" != "true" ]] || die "Distribution builds must not include com.apple.security.get-task-allow."
fi

print "Assembly verified at $STAGE_APP."
