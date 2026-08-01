#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
REPO_DIR="${PROJECT_DIR:h}"
DMGBUILD_PROJECT_DIR="$PROJECT_DIR/Packaging/dmgbuild"
SPARKLE_DISTRIBUTION="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle"
SPARKLE_GENERATE_KEYS="$SPARKLE_DISTRIBUTION/bin/generate_keys"
SPARKLE_GENERATE_APPCAST="$SPARKLE_DISTRIBUTION/bin/generate_appcast"
SPARKLE_SIGN_UPDATE="$SPARKLE_DISTRIBUTION/bin/sign_update"
SPARKLE_ACCOUNT="com.emilianscheel.current"
SPARKLE_PUBLIC_KEY_FILE="$PROJECT_DIR/Packaging/SparklePublicKey.txt"
SPARKLE_PUBLIC_KEY="$(tr -d '\r\n' < "$SPARKLE_PUBLIC_KEY_FILE")"
REMOTE="origin"
NOTARY_PROFILE="${CURRENT_NOTARY_PROFILE:-Current-notary}"
DEVELOPER_ID_OVERRIDE="${CURRENT_DEVELOPER_ID_APPLICATION:-}"
DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="$DIST_DIR/Current.dmg"
APPCAST_PATH="$DIST_DIR/appcast.xml"
STAGE_APP="$PROJECT_DIR/.build/Current.app-staging"
MOUNT_DIR=""
MOUNTED=false
APPCAST_SOURCE_DIR=""

cd "$REPO_DIR"

usage() {
  print -u2 $'Usage:\n  ./app/release.sh --setup\n  ./app/release.sh vX.Y.Z'
}

die() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

cleanup() {
  if $MOUNTED && [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  [[ -z "$MOUNT_DIR" ]] || rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  [[ -z "$APPCAST_SOURCE_DIR" ]] || rm -rf "$APPCAST_SOURCE_DIR"
}
trap cleanup EXIT INT TERM

default_keychain() {
  security default-keychain -d user | awk -F'"' 'NF >= 2 { print $2; exit }'
}

developer_id_hashes() {
  security find-identity -v -p codesigning "$1" 2>/dev/null \
    | awk '/"Developer ID Application:/{print $2}'
}

sparkle_signing_access_is_ready() {
  local signing_probe
  signing_probe="$(mktemp "${TMPDIR%/}/current-sparkle-signing.XXXXXX")" \
    || return 1
  if "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" \
      -p "$signing_probe" >/dev/null 2>&1; then
    rm -f "$signing_probe"
    return 0
  fi
  rm -f "$signing_probe"
  return 1
}

print_setup_help() {
  print ""
  print "One-time release setup:"
  print "  1. In Xcode Settings → Accounts → Manage Certificates, create Apple Development"
  print "     and Developer ID Application certificates."
  print "  2. Install uv and authenticate GitHub CLI:"
  print "       brew install gh uv"
  print "       gh auth login"
  print "  3. Store notarization credentials in Keychain (use an app-specific password):"
  print "       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <APPLE-ID> --team-id <TEAM-ID> --password <APP-SPECIFIC-PASSWORD>"
  print "  4. Generate Current's Sparkle update key in the login Keychain:"
  print "       cd app"
  print "       .build/artifacts/sparkle/Sparkle/bin/generate_keys --account $SPARKLE_ACCOUNT"
  print "     Keep an encrypted backup using generate_keys --account $SPARKLE_ACCOUNT -x <secure-path>."
  print "  5. Re-run: ./app/release.sh --setup"
  print "     If Keychain asks, choose Always Allow for Sparkle's sign_update tool."
  print ""
  print "Secrets are stored by notarytool in Keychain and are never read by this repository."
}

setup_release_environment() {
  local failed keychain identity_count resolved_public_key
  failed=false

  if ! (cd "$PROJECT_DIR" && swift package --disable-sandbox resolve >/dev/null); then
    print -u2 "Swift package dependencies could not be resolved."
    failed=true
  fi

  keychain="$(default_keychain)"
  if [[ -z "$keychain" || "$keychain" != /* ]]; then
    print -u2 "Could not resolve the default user Keychain."
    failed=true
  else
    identity_count="$(developer_id_hashes "$keychain" | awk 'NF { count += 1 } END { print count + 0 }')"
    if (( identity_count == 0 )); then
      print -u2 "No valid Developer ID Application identity with a private key was found."
      failed=true
    elif (( identity_count > 1 )) && [[ -z "$DEVELOPER_ID_OVERRIDE" ]]; then
      print -u2 "Multiple Developer ID Application identities were found. Set CURRENT_DEVELOPER_ID_APPLICATION to the intended SHA-1 hash or full identity name."
      failed=true
    else
      print "Found $identity_count Developer ID Application signing identity/identities."
    fi
  fi

  if ! command -v gh >/dev/null; then
    print -u2 "GitHub CLI is not installed."
    failed=true
  elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
    print -u2 "GitHub CLI is not authenticated for github.com."
    failed=true
  else
    print "GitHub CLI authentication is ready."
  fi

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    print -u2 "The notarytool Keychain profile '$NOTARY_PROFILE' is missing or invalid."
    failed=true
  else
    print "Notarization profile '$NOTARY_PROFILE' is ready."
  fi

  if ! command -v uv >/dev/null; then
    print -u2 "uv is not installed."
    failed=true
  elif ! uv run --project "$DMGBUILD_PROJECT_DIR" --isolated --frozen python -c 'import dmgbuild' >/dev/null 2>&1; then
    print -u2 "The locked dmgbuild packaging environment is unavailable."
    failed=true
  else
    print "Locked dmgbuild packaging environment is ready."
  fi

  if [[ ! -x "$SPARKLE_GENERATE_KEYS"
        || ! -x "$SPARKLE_GENERATE_APPCAST"
        || ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
    print -u2 "Sparkle's resolved release tools are unavailable."
    failed=true
  elif ! resolved_public_key="$(
    "$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null
  )"; then
    print -u2 "Current's Sparkle signing key is missing from the login Keychain."
    failed=true
  elif [[ "$resolved_public_key" != "$SPARKLE_PUBLIC_KEY" ]]; then
    print -u2 "The Sparkle private key does not match Packaging/SparklePublicKey.txt."
    failed=true
  elif ! sparkle_signing_access_is_ready; then
    print -u2 "Sparkle's sign_update tool cannot use Current's private key."
    failed=true
  else
    print "Sparkle update-signing key '$SPARKLE_ACCOUNT' is ready."
  fi

  if $failed; then
    print_setup_help
    return 1
  fi
  print "Release setup is complete."
}

if (( $# == 1 )) && [[ "$1" == "--setup" ]]; then
  setup_release_environment
  exit $?
fi
(( $# == 1 )) || { usage; exit 64; }

TAG="$1"
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "Release tag must use vX.Y.Z numeric format." 64
VERSION="${TAG#v}"
TAG_REF="refs/tags/$TAG"

for required_command in git gh swift codesign security xcrun xcodebuild hdiutil ditto plutil spctl shasum stat tiffutil uv curl xmllint; do
  command -v "$required_command" >/dev/null || die "$required_command is required. Run ./app/release.sh --setup for setup instructions."
done
[[ "$(uname -m)" == "arm64" ]] || die "Current releases must be built on Apple silicon (arm64)."
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( OS_MAJOR >= 26 )) || die "Current releases require macOS 26 or newer."
[[ "$(git rev-parse --show-toplevel)" == "$REPO_DIR" ]] || die "release.sh must run inside the Current repository."
[[ "$(git branch --show-current)" == "main" ]] || die "Releases must be built from the main branch."
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || die "The worktree must be clean before releasing."
gh auth status --hostname github.com >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run ./app/release.sh --setup."
uv run --project "$DMGBUILD_PROJECT_DIR" --isolated --frozen python -c 'import dmgbuild' >/dev/null \
  || die "The locked dmgbuild packaging environment is unavailable. Run ./app/release.sh --setup."
[[ -x "$SPARKLE_GENERATE_KEYS"
   && -x "$SPARKLE_GENERATE_APPCAST"
   && -x "$SPARKLE_SIGN_UPDATE" ]] \
  || die "Sparkle's release tools are unavailable. Run ./app/release.sh --setup."
RESOLVED_SPARKLE_PUBLIC_KEY="$(
  "$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p
)" || die "Current's Sparkle signing key is unavailable. Run ./app/release.sh --setup."
[[ "$RESOLVED_SPARKLE_PUBLIC_KEY" == "$SPARKLE_PUBLIC_KEY" ]] \
  || die "The Sparkle private key does not match Packaging/SparklePublicKey.txt."
sparkle_signing_access_is_ready \
  || die "Sparkle's sign_update tool cannot use Current's private key. Run ./app/release.sh --setup."

print "Fetching origin/main and release tags…"
git fetch --prune --tags "$REMOTE" main
HEAD_COMMIT="$(git rev-parse HEAD)"
REMOTE_MAIN="$(git rev-parse "refs/remotes/$REMOTE/main")"
[[ "$HEAD_COMMIT" == "$REMOTE_MAIN" ]] || die "HEAD must exactly match origin/main before releasing. Push main first, then retry."
BUILD_VERSION="$(git rev-list --count HEAD)"
[[ "$BUILD_VERSION" =~ '^[0-9]+$' ]] && (( BUILD_VERSION > 0 )) || die "Could not derive a positive numeric build version from Git history."

LOCAL_TAG_EXISTS=false
if git show-ref --verify --quiet "$TAG_REF"; then
  LOCAL_TAG_EXISTS=true
  [[ "$(git cat-file -t "$TAG_REF")" == "tag" ]] || die "Existing tag $TAG is lightweight; releases require an annotated tag."
  [[ "$(git rev-list -n 1 "$TAG")" == "$HEAD_COMMIT" ]] || die "Existing tag $TAG points to a different commit."
fi

REMOTE_TAG_OBJECT="$(git ls-remote --refs "$REMOTE" "$TAG_REF" | awk 'NR == 1 { print $1 }')"
REMOTE_TAG_COMMIT="$(git ls-remote "$REMOTE" "$TAG_REF^{}" | awk 'NR == 1 { print $1 }')"
if [[ -n "$REMOTE_TAG_OBJECT" ]]; then
  [[ -n "$REMOTE_TAG_COMMIT" ]] || die "Remote tag $TAG is not annotated."
  [[ "$REMOTE_TAG_COMMIT" == "$HEAD_COMMIT" ]] || die "Remote tag $TAG points to a different commit."
fi

DRAFT_EXISTS=false
if RELEASE_DRAFT_STATE="$(gh release view "$TAG" --json isDraft --jq '.isDraft' 2>&1)"; then
  [[ "$RELEASE_DRAFT_STATE" == "true" ]] || die "GitHub Release $TAG is already published and will not be overwritten."
  DRAFT_EXISTS=true
  print "A matching draft release exists and will be resumed."
elif [[ "$RELEASE_DRAFT_STATE" != *"release not found"* && "$RELEASE_DRAFT_STATE" != *"HTTP 404"* ]]; then
  die "Could not determine GitHub Release state for $TAG: $RELEASE_DRAFT_STATE"
fi

KEYCHAIN_PATH="$(default_keychain)"
[[ -n "$KEYCHAIN_PATH" && "$KEYCHAIN_PATH" == /* ]] || die "Could not resolve the default user Keychain."
typeset -a DEVELOPER_ID_HASHES
DEVELOPER_ID_HASHES=()
while IFS= read -r identity_hash; do
  [[ -z "$identity_hash" ]] || DEVELOPER_ID_HASHES+=("$identity_hash")
done < <(developer_id_hashes "$KEYCHAIN_PATH")
if [[ -n "$DEVELOPER_ID_OVERRIDE" ]]; then
  SIGNING_IDENTITY=""
  while IFS= read -r identity_line; do
    identity_hash="$(print -r -- "$identity_line" | awk '{print $2}')"
    identity_name="$(print -r -- "$identity_line" | sed -E 's/.*"(Developer ID Application:[^"]+)".*/\1/')"
    if [[ "$DEVELOPER_ID_OVERRIDE" == "$identity_hash" || "$DEVELOPER_ID_OVERRIDE" == "$identity_name" ]]; then
      SIGNING_IDENTITY="$identity_hash"
      break
    fi
  done < <(security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep '"Developer ID Application:' || true)
  [[ -n "$SIGNING_IDENTITY" ]] || die "CURRENT_DEVELOPER_ID_APPLICATION does not select a valid Developer ID Application identity."
else
  (( ${#DEVELOPER_ID_HASHES[@]} == 1 )) || {
    die "Expected exactly one Developer ID Application identity, found ${#DEVELOPER_ID_HASHES[@]}. Set CURRENT_DEVELOPER_ID_APPLICATION to its SHA-1 hash or full identity name."
  }
  SIGNING_IDENTITY="$DEVELOPER_ID_HASHES[1]"
fi

print "Validating notarization credentials…"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null \
  || die "The notarytool Keychain profile '$NOTARY_PROFILE' is missing or invalid. Run ./app/release.sh --setup."

print "Building Current $VERSION (build $BUILD_VERSION)…"
"$PROJECT_DIR/assemble-app.sh" \
  --signing-mode distribution \
  --signing-identity "$SIGNING_IDENTITY" \
  --keychain "$KEYCHAIN_PATH" \
  --version "$VERSION" \
  --build-version "$BUILD_VERSION"

MAIN_INFO_PLIST="$STAGE_APP/Contents/Info.plist"
WORKER_INFO_PLIST="$STAGE_APP/Contents/XPCServices/CurrentContextWorker.xpc/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$MAIN_INFO_PLIST")" == "com.emilianscheel.current" ]] || die "The staged app has an unexpected bundle identifier."
[[ "$(plutil -extract CFBundleIdentifier raw "$WORKER_INFO_PLIST")" == "com.emilianscheel.current.ContextWorker" ]] || die "The staged XPC service has an unexpected bundle identifier."
for info_plist in "$MAIN_INFO_PLIST" "$WORKER_INFO_PLIST"; do
  [[ "$(plutil -extract CFBundleShortVersionString raw "$info_plist")" == "$VERSION" ]] || die "$info_plist has an unexpected semantic version."
  [[ "$(plutil -extract CFBundleVersion raw "$info_plist")" == "$BUILD_VERSION" ]] || die "$info_plist has an unexpected build version."
done

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
print "Creating and signing Current.dmg…"
"$PROJECT_DIR/package-dmg.sh" --app "$STAGE_APP" --output "$DMG_PATH"
codesign --force --timestamp --identifier com.emilianscheel.current.dmg \
  --keychain "$KEYCHAIN_PATH" --sign "$SIGNING_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

NOTARY_RESULT="$DIST_DIR/notarization-submit.json"
print "Submitting Current.dmg to Apple's notary service…"
if ! xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_RESULT"; then
  SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" "$DIST_DIR/notarization-$SUBMISSION_ID.json" || true
  fi
  die "Apple notarization failed. The submission response and available log remain in app/dist/."
fi
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  [[ -z "$SUBMISSION_ID" ]] || xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" "$DIST_DIR/notarization-$SUBMISSION_ID.json" || true
  die "Apple notarization returned status '${NOTARY_STATUS:-unknown}'. No tag or release was published."
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

MOUNT_DIR="$(mktemp -d "${TMPDIR%/}/current-dmg-mount.XXXXXX")"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTED=true
[[ -d "$MOUNT_DIR/Current.app" ]] || die "Mounted DMG does not contain Current.app."
[[ "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] || die "Mounted DMG has an invalid Applications shortcut."
[[ -f "$MOUNT_DIR/.DS_Store" ]] || die "Mounted DMG does not contain Finder layout metadata."
[[ -f "$MOUNT_DIR/.background.tiff" ]] || die "Mounted DMG does not contain its Finder background."
codesign --verify --deep --strict --verbose=2 "$MOUNT_DIR/Current.app"
spctl --assess --type execute --verbose=2 "$MOUNT_DIR/Current.app"
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=false
rmdir "$MOUNT_DIR"
MOUNT_DIR=""

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_SIZE="$(stat -f '%z' "$DMG_PATH")"
print "Verified Current.dmg SHA-256: $DMG_SHA256"

APPCAST_SOURCE_DIR="$(mktemp -d "${TMPDIR%/}/current-appcast.XXXXXX")"
cp "$DMG_PATH" "$APPCAST_SOURCE_DIR/Current.dmg"
print "Generating and signing appcast.xml…"
"$SPARKLE_GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/emilianscheel/current/releases/download/$TAG/" \
  --link "https://github.com/emilianscheel/current/releases/tag/$TAG" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$APPCAST_PATH" \
  "$APPCAST_SOURCE_DIR"
xmllint --noout "$APPCAST_PATH"
"$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$APPCAST_PATH"
grep -Fq "<sparkle:version>$BUILD_VERSION</sparkle:version>" "$APPCAST_PATH" \
  || die "The appcast does not contain the expected build version."
grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_PATH" \
  || die "The appcast does not contain the expected semantic version."
grep -Fq "https://github.com/emilianscheel/current/releases/download/$TAG/Current.dmg" "$APPCAST_PATH" \
  || die "The appcast does not reference the tag-specific Current.dmg asset."
grep -Fq '<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>' "$APPCAST_PATH" \
  || die "The appcast does not require macOS 26.0."
grep -Fq '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>' "$APPCAST_PATH" \
  || die "The appcast does not require arm64."
grep -Eq "<enclosure [^>]*length=\"$DMG_SIZE\"" "$APPCAST_PATH" \
  || die "The appcast enclosure length does not match Current.dmg."
grep -Eq 'sparkle:edSignature="[A-Za-z0-9+/=]+"' "$APPCAST_PATH" \
  || die "The appcast enclosure is missing its Ed25519 signature."
grep -Fq '<!-- sparkle-signatures:' "$APPCAST_PATH" \
  || die "The appcast is missing signed-feed metadata."
grep -Eq '^edSignature: [A-Za-z0-9+/=]+$' "$APPCAST_PATH" \
  || die "The appcast is missing its signed-feed Ed25519 signature."
APPCAST_SHA256="$(shasum -a 256 "$APPCAST_PATH" | awk '{print $1}')"
rm -rf "$APPCAST_SOURCE_DIR"
APPCAST_SOURCE_DIR=""
print "Verified signed appcast.xml SHA-256: $APPCAST_SHA256"

if ! $LOCAL_TAG_EXISTS; then
  git tag -a "$TAG" -m "$TAG" "$HEAD_COMMIT"
  LOCAL_TAG_EXISTS=true
fi
if [[ -z "$REMOTE_TAG_OBJECT" ]]; then
  print "Pushing annotated tag $TAG…"
  git push "$REMOTE" "${TAG_REF}:${TAG_REF}"
fi
VERIFIED_REMOTE_COMMIT="$(git ls-remote "$REMOTE" "$TAG_REF^{}" | awk 'NR == 1 { print $1 }')"
[[ "$VERIFIED_REMOTE_COMMIT" == "$HEAD_COMMIT" ]] || die "GitHub does not resolve $TAG to the expected commit."

METADATA_FILE="$DIST_DIR/release-metadata.md"
{
  print '<!-- current-release-metadata:start -->'
  print 'Requires macOS 26 or newer, an Apple M1 or newer chip, and at least 8 GiB of unified memory. Context features require 16 GiB.'
  print ''
  print "**Current.dmg SHA-256:** \`$DMG_SHA256\`"
  print '<!-- current-release-metadata:end -->'
} > "$METADATA_FILE"

if $DRAFT_EXISTS; then
  EXISTING_BODY="$(gh release view "$TAG" --json body --jq '.body')"
  NOTES_FILE="$DIST_DIR/release-notes.md"
  {
    sed -n 'p' "$METADATA_FILE"
    print ''
    print -r -- "$EXISTING_BODY" | awk '
      /<!-- current-release-metadata:start -->/ { skipping = 1; next }
      /<!-- current-release-metadata:end -->/ { skipping = 0; next }
      !skipping { print }
    '
  } > "$NOTES_FILE"
  gh release edit "$TAG" --notes-file "$NOTES_FILE"
  gh release upload "$TAG" "$DMG_PATH" "$APPCAST_PATH" --clobber
else
  gh release create "$TAG" "$DMG_PATH" "$APPCAST_PATH" \
    --draft \
    --verify-tag \
    --title "$TAG" \
    --generate-notes \
    --notes-file "$METADATA_FILE"
fi

ASSET_COUNT="$(gh release view "$TAG" --json assets --jq '.assets | length')"
ASSET_NAMES="$(gh release view "$TAG" --json assets --jq '.assets | map(.name) | sort | join(",")')"
[[ "$ASSET_COUNT" == "2" && "$ASSET_NAMES" == "Current.dmg,appcast.xml" ]] || {
  die "Draft release must contain exactly Current.dmg and appcast.xml; it remains unpublished for inspection."
}
VERIFY_DIR="$(mktemp -d "${TMPDIR%/}/current-release-download.XXXXXX")"
gh release download "$TAG" --pattern Current.dmg --pattern appcast.xml --dir "$VERIFY_DIR"
DOWNLOADED_SHA256="$(shasum -a 256 "$VERIFY_DIR/Current.dmg" | awk '{print $1}')"
DOWNLOADED_APPCAST_SHA256="$(shasum -a 256 "$VERIFY_DIR/appcast.xml" | awk '{print $1}')"
rm -rf "$VERIFY_DIR"
[[ "$DOWNLOADED_SHA256" == "$DMG_SHA256" ]] || die "The uploaded Current.dmg checksum does not match the local artifact; the draft remains unpublished."
[[ "$DOWNLOADED_APPCAST_SHA256" == "$APPCAST_SHA256" ]] || die "The uploaded appcast.xml checksum does not match the local artifact; the draft remains unpublished."

gh release edit "$TAG" --draft=false --prerelease=false --latest
[[ "$(gh release view "$TAG" --json isDraft --jq '.isDraft')" == "false" ]] || die "GitHub Release $TAG did not publish successfully."
RELEASE_URL="$(gh release view "$TAG" --json url --jq '.url')"
LATEST_VERIFY_DIR="$(mktemp -d "${TMPDIR%/}/current-latest-release.XXXXXX")"
curl -L --fail --silent --show-error \
  "https://github.com/emilianscheel/current/releases/latest/download/appcast.xml" \
  -o "$LATEST_VERIFY_DIR/appcast.xml"
curl -L --fail --silent --show-error \
  "https://github.com/emilianscheel/current/releases/latest/download/Current.dmg" \
  -o "$LATEST_VERIFY_DIR/Current.dmg"
[[ "$(shasum -a 256 "$LATEST_VERIFY_DIR/appcast.xml" | awk '{print $1}')" == "$APPCAST_SHA256" ]] \
  || die "GitHub's latest appcast URL does not resolve to the published release."
[[ "$(shasum -a 256 "$LATEST_VERIFY_DIR/Current.dmg" | awk '{print $1}')" == "$DMG_SHA256" ]] \
  || die "GitHub's latest DMG URL does not resolve to the published release."
rm -rf "$LATEST_VERIFY_DIR"
print "Published Current $VERSION: $RELEASE_URL"
print "Download: https://github.com/emilianscheel/current/releases/latest/download/Current.dmg"
print "Appcast: https://github.com/emilianscheel/current/releases/latest/download/appcast.xml"
