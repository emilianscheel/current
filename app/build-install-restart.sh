#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"

ASSEMBLE_ONLY=false
APP_VERSION=""

die() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

while (( $# > 0 )); do
  case "$1" in
    --assemble-only)
      ASSEMBLE_ONLY=true
      shift
      ;;
    --version)
      (( $# >= 2 )) || die "Missing value for --version." 64
      APP_VERSION="$2"
      shift 2
      ;;
    *)
      print -u2 "Usage: $0 [--assemble-only [--version X.Y.Z]]"
      exit 64
      ;;
  esac
done

[[ -z "$APP_VERSION" || "$ASSEMBLE_ONLY" == true ]] || die "--version is only supported with --assemble-only." 64
[[ -z "$APP_VERSION" || "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "Version must use X.Y.Z numeric format." 64
[[ "$(uname -m)" == "arm64" ]] || die "Current requires Apple silicon (arm64)."
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( OS_MAJOR >= 26 )) || die "Current requires macOS 26 or newer."

for required_command in swift codesign openssl security; do
  command -v "$required_command" >/dev/null || die "$required_command is required."
done

typeset -a ASSEMBLER_ARGS
BUILD_VERSION="$(date -u +%Y%m%d%H%M%S)"

if $ASSEMBLE_ONLY; then
  ASSEMBLER_ARGS=(
    --signing-mode adhoc
    --signing-identity -
    --build-version "$BUILD_VERSION"
  )
else
  CHIP_NAME="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip:/{print $2; exit}')"
  if [[ ! "$CHIP_NAME" =~ 'Apple M([0-9]+)' ]] || (( match[1] < 3 )); then
    die "Current requires an Apple M3 or newer chip (found: ${CHIP_NAME:-unknown})."
  fi
  MEMORY_BYTES="$(sysctl -n hw.memsize)"
  (( MEMORY_BYTES >= 17179869184 )) || die "Current requires at least 16 GiB of unified memory."

  USER_NAME="$(id -un)"
  USER_HOME_DIR="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
  [[ -n "$USER_HOME_DIR" && "$USER_HOME_DIR" == /* ]] || die "Could not resolve the user home directory."
  INSTALL_DIR="$USER_HOME_DIR/Applications"
  INSTALL_APP="$INSTALL_DIR/Current.app"
  KEYCHAIN_PATH="$(security default-keychain -d user | awk -F'"' 'NF >= 2 { print $2; exit }')"
  [[ -n "$KEYCHAIN_PATH" && "$KEYCHAIN_PATH" == /* ]] || die "Could not resolve the default user Keychain."

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
        [[ -z "$verification_error" ]] || print -u2 -- "$verification_error"
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
    rm -rf "$certificate_dir"
    trap - EXIT
  }

  SIGNING_IDENTITY="$(find_usable_apple_identity)"
  [[ -n "$SIGNING_IDENTITY" ]] || SIGNING_IDENTITY="$(find_local_identity)"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    create_local_identity
    SIGNING_IDENTITY="$(find_local_identity)"
  fi
  [[ -n "$SIGNING_IDENTITY" ]] || die "Unable to create a valid code-signing identity. Open Keychain Access and trust Current Local Development for code signing."

  ASSEMBLER_ARGS=(
    --signing-mode development
    --signing-identity "$SIGNING_IDENTITY"
    --keychain "$KEYCHAIN_PATH"
    --build-version "$BUILD_VERSION"
  )
fi

[[ -z "$APP_VERSION" ]] || ASSEMBLER_ARGS+=(--version "$APP_VERSION")
"$PROJECT_DIR/assemble-app.sh" "${ASSEMBLER_ARGS[@]}"

STAGE_APP="$PROJECT_DIR/.build/Current.app-staging"
if $ASSEMBLE_ONLY; then
  print "Assembly was not installed or launched."
  exit 0
fi

print "Installing without resetting TCC permissions or Current preferences…"
pkill -TERM -x Current 2>/dev/null || true
for _ in {1..30}; do pgrep -x Current >/dev/null || break; sleep 0.1; done
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_APP" "$INSTALL_DIR/Current.previous.app"
mv "$STAGE_APP" "$INSTALL_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALL_APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/Support/lsregister"
if [[ ! -x "$LSREGISTER" ]]; then
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
fi
[[ ! -x "$LSREGISTER" ]] || "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
open -n "$INSTALL_APP"
print "Installed and launched $INSTALL_APP"
print "Permissions persist while the signing identity, bundle identifier, and install path remain unchanged."
