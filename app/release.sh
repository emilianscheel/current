#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
REPO_DIR="${PROJECT_DIR:h}"
REMOTE="origin"
NOTARY_PROFILE="${CURRENT_NOTARY_PROFILE:-Current-notary}"
DEVELOPER_ID_OVERRIDE="${CURRENT_DEVELOPER_ID_APPLICATION:-}"
DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="$DIST_DIR/Current.dmg"
STAGE_APP="$PROJECT_DIR/.build/Current.app-staging"
MOUNT_DIR=""
MOUNTED=false

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
}
trap cleanup EXIT INT TERM

default_keychain() {
  security default-keychain -d user | awk -F'"' 'NF >= 2 { print $2; exit }'
}

developer_id_hashes() {
  security find-identity -v -p codesigning "$1" 2>/dev/null \
    | awk '/"Developer ID Application:/{print $2}'
}

print_setup_help() {
  print ""
  print "One-time release setup:"
  print "  1. In Xcode Settings → Accounts → Manage Certificates, create Apple Development"
  print "     and Developer ID Application certificates."
  print "  2. Install and authenticate GitHub CLI:"
  print "       brew install gh"
  print "       gh auth login"
  print "  3. Store notarization credentials in Keychain (use an app-specific password):"
  print "       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <APPLE-ID> --team-id <TEAM-ID> --password <APP-SPECIFIC-PASSWORD>"
  print "  4. Re-run: ./app/release.sh --setup"
  print ""
  print "Secrets are stored by notarytool in Keychain and are never read by this repository."
}

setup_release_environment() {
  local failed keychain identity_count
  failed=false

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

for required_command in git gh swift codesign security xcrun xcodebuild hdiutil ditto plutil spctl shasum; do
  command -v "$required_command" >/dev/null || die "$required_command is required. Run ./app/release.sh --setup for setup instructions."
done
[[ "$(uname -m)" == "arm64" ]] || die "Current releases must be built on Apple silicon (arm64)."
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( OS_MAJOR >= 26 )) || die "Current releases require macOS 26 or newer."
[[ "$(git rev-parse --show-toplevel)" == "$REPO_DIR" ]] || die "release.sh must run inside the Current repository."
[[ "$(git branch --show-current)" == "main" ]] || die "Releases must be built from the main branch."
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || die "The worktree must be clean before releasing."
gh auth status --hostname github.com >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run ./app/release.sh --setup."

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
DMG_ROOT="$(mktemp -d "${TMPDIR%/}/current-dmg-root.XXXXXX")"
trap 'cleanup; rm -rf "$DMG_ROOT"' EXIT INT TERM
ditto "$STAGE_APP" "$DMG_ROOT/Current.app"
ln -s /Applications "$DMG_ROOT/Applications"

print "Creating and signing Current.dmg…"
hdiutil create -volname Current -srcfolder "$DMG_ROOT" -format UDZO -ov "$DMG_PATH"
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
codesign --verify --deep --strict --verbose=2 "$MOUNT_DIR/Current.app"
spctl --assess --type execute --verbose=2 "$MOUNT_DIR/Current.app"
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=false
rmdir "$MOUNT_DIR"
MOUNT_DIR=""

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
print "Verified Current.dmg SHA-256: $DMG_SHA256"

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
  print 'Requires macOS 26 or newer, an Apple M3 or newer chip, and at least 16 GiB of unified memory.'
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
  gh release upload "$TAG" "$DMG_PATH" --clobber
else
  gh release create "$TAG" "$DMG_PATH" \
    --draft \
    --verify-tag \
    --title "$TAG" \
    --generate-notes \
    --notes-file "$METADATA_FILE"
fi

ASSET_COUNT="$(gh release view "$TAG" --json assets --jq '.assets | length')"
ASSET_NAME="$(gh release view "$TAG" --json assets --jq '.assets[0].name')"
[[ "$ASSET_COUNT" == "1" && "$ASSET_NAME" == "Current.dmg" ]] || {
  die "Draft release must contain exactly one asset named Current.dmg; it remains unpublished for inspection."
}
VERIFY_DIR="$(mktemp -d "${TMPDIR%/}/current-release-download.XXXXXX")"
gh release download "$TAG" --pattern Current.dmg --dir "$VERIFY_DIR"
DOWNLOADED_SHA256="$(shasum -a 256 "$VERIFY_DIR/Current.dmg" | awk '{print $1}')"
rm -rf "$VERIFY_DIR"
[[ "$DOWNLOADED_SHA256" == "$DMG_SHA256" ]] || die "The uploaded Current.dmg checksum does not match the local artifact; the draft remains unpublished."

gh release edit "$TAG" --draft=false --prerelease=false --latest
[[ "$(gh release view "$TAG" --json isDraft --jq '.isDraft')" == "false" ]] || die "GitHub Release $TAG did not publish successfully."
RELEASE_URL="$(gh release view "$TAG" --json url --jq '.url')"
print "Published Current $VERSION: $RELEASE_URL"
print "Download: https://github.com/emilianscheel/current/releases/latest/download/Current.dmg"
