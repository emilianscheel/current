#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
DMGBUILD_PROJECT_DIR="$PROJECT_DIR/Packaging/dmgbuild"
DMGBUILD_SETTINGS="$DMGBUILD_PROJECT_DIR/settings.py"
VOLUME_NAME="Current"
ARROW_ITEM_NAME=$'\u2063.tiff'
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
[[ -f "$DMGBUILD_PROJECT_DIR/uv.lock" ]] || die "The locked dmgbuild environment is missing."

for required_command in hdiutil swift tiffutil uv; do
  command -v "$required_command" >/dev/null || die "$required_command is required to package the DMG."
done

mkdir -p "${OUTPUT_PATH:h}"
WORK_DIR="$(mktemp -d "${TMPDIR%/}/current-dmg.XXXXXX")"
ARROW_1X="$WORK_DIR/installer-arrow.png"
ARROW_2X="$WORK_DIR/installer-arrow@2x.png"
ARROW_TIFF="$WORK_DIR/installer-arrow.tiff"
MODULE_CACHE_DIR="$WORK_DIR/module-cache"
MOUNT_DIR="$WORK_DIR/verify-mount"
mkdir -p "$MODULE_CACHE_DIR" "$MOUNT_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
  swift "$PROJECT_DIR/Packaging/make-dmg-arrow.swift" "$ARROW_1X" "$ARROW_2X"
tiffutil -cathidpicheck "$ARROW_1X" "$ARROW_2X" \
  -out "$ARROW_TIFF" >/dev/null

uv run \
  --project "$DMGBUILD_PROJECT_DIR" \
  --isolated \
  --frozen \
  dmgbuild \
  -s "$DMGBUILD_SETTINGS" \
  -D "app=$APP_PATH" \
  -D "arrow=$ARROW_TIFF" \
  "$VOLUME_NAME" \
  "$OUTPUT_PATH"

[[ "$(hdiutil imageinfo -format "$OUTPUT_PATH")" == "UDZO" ]] \
  || die "The packaged disk image is not compressed UDZO."
hdiutil verify "$OUTPUT_PATH" >/dev/null

hdiutil attach "$OUTPUT_PATH" \
  -nobrowse \
  -noautoopen \
  -readonly \
  -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTED=true

[[ -d "$MOUNT_DIR/Current.app" ]] || die "Packaged DMG does not contain Current.app."
[[ "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] \
  || die "Packaged DMG has an invalid Applications shortcut."
[[ -f "$MOUNT_DIR/.DS_Store" ]] || die "Packaged DMG does not contain Finder layout metadata."
[[ -f "$MOUNT_DIR/$ARROW_ITEM_NAME" ]] \
  || die "Packaged DMG does not contain its installer arrow."
uv run \
  --project "$DMGBUILD_PROJECT_DIR" \
  --isolated \
  --frozen \
  python "$DMGBUILD_PROJECT_DIR/verify_layout.py" "$MOUNT_DIR/.DS_Store"

hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=false

print "Created $OUTPUT_PATH"
