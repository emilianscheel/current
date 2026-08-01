#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
VOLUME_NAME="Current"
APP_PATH=""
OUTPUT_PATH=""
WORK_DIR=""
MOUNT_DIR=""
MOUNTED=false

usage() {
  print -u2 "Usage: ./app/package-dmg.sh --app <path-to-app> --output <path-to-dmg>"
}

die() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

cleanup() {
  if $MOUNTED && [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || { usage; exit 64; }
      APP_PATH="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || { usage; exit 64; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[[ -n "$APP_PATH" && -n "$OUTPUT_PATH" ]] || { usage; exit 64; }
APP_PATH="${APP_PATH:A}"
OUTPUT_PATH="${OUTPUT_PATH:A}"

[[ -d "$APP_PATH" && -f "$APP_PATH/Contents/Info.plist" ]] \
  || die "--app must point to a macOS application bundle."
[[ "$OUTPUT_PATH" == *.dmg ]] || die "--output must end in .dmg." 64
[[ ! -e "$OUTPUT_PATH" ]] || die "Output already exists: $OUTPUT_PATH"

for required_command in ditto hdiutil osascript SetFile swift tiffutil; do
  command -v "$required_command" >/dev/null || die "$required_command is required to package the DMG."
done

FINDER_VOLUME_COUNT="$(osascript -e "tell application \"Finder\" to count (every disk whose name is \"$VOLUME_NAME\")" 2>/dev/null)" \
  || die "Finder automation is unavailable. Allow the invoking terminal to control Finder in System Settings → Privacy & Security → Automation."
[[ "$FINDER_VOLUME_COUNT" == "0" ]] \
  || die "A volume named '$VOLUME_NAME' is already mounted. Eject it before packaging."

mkdir -p "${OUTPUT_PATH:h}"
WORK_DIR="$(mktemp -d "${TMPDIR%/}/current-dmg.XXXXXX")"
STAGE_DIR="$WORK_DIR/root"
RW_DMG="$WORK_DIR/Current-rw.dmg"
BACKGROUND_1X="$WORK_DIR/installer-background.png"
BACKGROUND_2X="$WORK_DIR/installer-background@2x.png"
MODULE_CACHE_DIR="$WORK_DIR/module-cache"
mkdir -p "$STAGE_DIR/.background" "$MODULE_CACHE_DIR"

ditto "$APP_PATH" "$STAGE_DIR/Current.app"
ln -s /Applications "$STAGE_DIR/Applications"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
  swift "$PROJECT_DIR/Packaging/make-dmg-background.swift" "$BACKGROUND_1X" "$BACKGROUND_2X"
tiffutil -cathidpicheck "$BACKGROUND_1X" "$BACKGROUND_2X" \
  -out "$STAGE_DIR/.background/installer-background.tiff" >/dev/null
SetFile -a V "$STAGE_DIR/.background"

hdiutil create \
  -srcfolder "$STAGE_DIR" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" \
  -nobrowse \
  -noautoopen \
  -readwrite)"
MOUNT_DIR="$(print -r -- "$ATTACH_OUTPUT" | awk -F $'\t' 'NF >= 3 && $NF ~ /^\// { mount = $NF } END { print mount }')"
[[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] || die "Could not determine the writable DMG mount point."
MOUNTED=true
SetFile -a V "$MOUNT_DIR/.background"

osascript - "$MOUNT_DIR" <<'APPLESCRIPT'
on run arguments
  set mountPath to item 1 of arguments
  set backgroundFile to POSIX file (mountPath & "/.background/installer-background.tiff") as alias

  tell application "Finder"
    set volumeDisk to missing value
    repeat 20 times
      try
        set volumeDisk to disk "Current"
        exit repeat
      on error
        delay 0.5
      end try
    end repeat
    if volumeDisk is missing value then error "Finder could not discover the mounted Current volume."

    open volumeDisk
    delay 1

    set dmgWindow to container window of volumeDisk
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    set pathbar visible of dmgWindow to false
    set sidebar width of dmgWindow to 0
    set bounds of dmgWindow to {200, 120, 860, 520}

    set viewOptions to icon view options of dmgWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 14
    set label position of viewOptions to bottom
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to true
    set background picture of viewOptions to backgroundFile

    set position of item "Current.app" of volumeDisk to {160, 170}
    set extension hidden of item "Current.app" of volumeDisk to true
    set position of item "Applications" of volumeDisk to {500, 170}

    update volumeDisk without registering applications
    delay 2

    if current view of dmgWindow is not icon view then error "Finder did not retain icon view."
    if bounds of dmgWindow is not {200, 120, 860, 520} then error "Finder did not retain the window bounds."
    if toolbar visible of dmgWindow then error "Finder did not hide the toolbar."
    if statusbar visible of dmgWindow then error "Finder did not hide the status bar."
    if pathbar visible of dmgWindow then error "Finder did not hide the path bar."
    if icon size of viewOptions is not 112 then error "Finder did not retain the icon size."
    if text size of viewOptions is not 14 then error "Finder did not retain the label size."
    if position of item "Current.app" of volumeDisk is not {160, 170} then error "Finder did not retain the Current.app position."
    if position of item "Applications" of volumeDisk is not {500, 170} then error "Finder did not retain the Applications position."

    close dmgWindow
  end tell
end run
APPLESCRIPT

for attempt in {1..20}; do
  [[ -f "$MOUNT_DIR/.DS_Store" ]] && break
  sleep 0.25
done
[[ -f "$MOUNT_DIR/.DS_Store" ]] || die "Finder did not persist the DMG layout metadata."

hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=false

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_PATH" >/dev/null
hdiutil verify "$OUTPUT_PATH" >/dev/null

print "Created $OUTPUT_PATH"
