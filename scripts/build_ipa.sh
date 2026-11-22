#!/bin/bash
# Builds real device code with Apple's toolchain. Run on macOS with Xcode 26+.
set -euo pipefail

SIGNING_MODE="unsigned"
RUN_TESTS=1
for argument in "$@"; do
  case "$argument" in
    --unsigned) SIGNING_MODE="unsigned" ;;
    --signed) SIGNING_MODE="signed" ;;
    --skip-tests) RUN_TESTS=0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null; then
  printf 'A real IPA requires macOS and Xcode 26 or newer. No IPA was produced.\n' >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode / {print $2}')"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
python3 - "$XCODE_VERSION" "$SDK_VERSION" <<'PY'
import sys
if any(int(version.split('.')[0]) < 26 for version in sys.argv[1:]):
    raise SystemExit('Xcode 26+ and iOS SDK 26+ are required for Liquid Glass. No IPA was produced.')
PY
KOMIIC_BUNDLE_ID="${KOMIIC_BUNDLE_ID:-com.example.Komiic}"
if [[ ! "$KOMIIC_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  printf 'KOMIIC_BUNDLE_ID must be a valid reverse-DNS bundle identifier.\n' >&2; exit 2
fi
if [[ "$SIGNING_MODE" == "signed" ]]; then
  : "${IOS_CERTIFICATE_P12_BASE64:?A real p12 certificate secret is required for signed IPA}"
  : "${IOS_CERTIFICATE_PASSWORD:?The real p12 password secret is required}"
  : "${IOS_PROVISIONING_PROFILE_BASE64:?A real development/ad-hoc/enterprise profile is required}"
fi
mkdir -p "$PROJECT_ROOT/build"
BUILD_ROOT="$(mktemp -d "$PROJECT_ROOT/build/ipa.XXXXXX")"
ARTIFACT_DIR="$BUILD_ROOT/artifacts"
mkdir -p "$ARTIFACT_DIR"
SIGNING_TEMP=""
KEYCHAIN_PATH=""
INSTALLED_PROFILE=""
KEYCHAIN_SEARCH_CHANGED=0
cleanup() {
  if [[ "$KEYCHAIN_SEARCH_CHANGED" == "1" && -f "$SIGNING_TEMP/keychain-search-list.json" ]]; then
    python3 - "$SIGNING_TEMP/keychain-search-list.json" <<'PY' || true
import json, subprocess, sys
subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *json.load(open(sys.argv[1]))], check=True)
PY
  fi
  if [[ -n "$KEYCHAIN_PATH" ]]; then /usr/bin/security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true; fi
  if [[ -n "$INSTALLED_PROFILE" && -f "$INSTALLED_PROFILE" ]]; then rm -f "$INSTALLED_PROFILE"; fi
  if [[ -n "$SIGNING_TEMP" && -d "$SIGNING_TEMP" ]]; then rm -rf "$SIGNING_TEMP"; fi
}
trap cleanup EXIT

xcodebuild -version | tee "$ARTIFACT_DIR/xcode-version.txt"
printf 'iOS SDK: %s\nSigning: %s\n' "$SDK_VERSION" "$SIGNING_MODE" | tee "$ARTIFACT_DIR/build-mode.txt"
python3 scripts/verify_project.py | tee "$ARTIFACT_DIR/project-validation.txt"

if [[ "$RUN_TESTS" == "1" ]]; then
  xcrun simctl list devices available --json > "$BUILD_ROOT/simulators.json"
  python3 - "$BUILD_ROOT/simulators.json" "$BUILD_ROOT/simulator-plan.txt" <<'PY'
import json, re, sys
devices = json.load(open(sys.argv[1]))['devices']
candidates = []
for runtime, entries in devices.items():
    match = re.search(r'\.iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$', runtime)
    if match and int(match[1]) >= 26:
        candidates.append((tuple(int(x or 0) for x in match.groups()), entries))
for _, entries in sorted(candidates, reverse=True):
    phone = next((x for x in entries if x['name'].startswith('iPhone') and x.get('isAvailable', True)), None)
    tablet = next((x for x in entries if x['name'].startswith('iPad') and x.get('isAvailable', True)), None)
    if phone and tablet:
        with open(sys.argv[2], 'w') as output:
            output.write('iPhone ' + phone['udid'] + '\niPad ' + tablet['udid'] + '\n')
        break
else:
    raise SystemExit('No available iOS 26+ iPhone and iPad simulators; install runtimes in Xcode before building.')
PY
  while read -r device_kind device_id; do
    xcodebuild -project Komiic.xcodeproj -scheme Komiic -configuration Debug \
      -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device_id" \
      -derivedDataPath "$BUILD_ROOT/SimulatorDerivedData" \
      -resultBundlePath "$ARTIFACT_DIR/$device_kind-tests.xcresult" \
      -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test \
      2>&1 | tee "$ARTIFACT_DIR/$device_kind-tests.log"
    # Launch the normal app after XCTest so screenshots show the actual UI, not the test host.
    xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$device_id" -b
    SIMULATOR_APP="$BUILD_ROOT/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/Komiic.app"
    SIMULATOR_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SIMULATOR_APP/Info.plist")"
    xcrun simctl install "$device_id" "$SIMULATOR_APP"
    xcrun simctl terminate "$device_id" "$SIMULATOR_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$device_id" "$SIMULATOR_BUNDLE_ID"
    sleep 5
    xcrun simctl io "$device_id" screenshot "$ARTIFACT_DIR/Komiic-$device_kind.png"
    xcrun simctl terminate "$device_id" "$SIMULATOR_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
  done < "$BUILD_ROOT/simulator-plan.txt"
fi

SIGNING_ARGUMENTS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
if [[ "$SIGNING_MODE" == "signed" ]]; then
  SIGNING_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/komiic-signing.XXXXXX")"
  chmod 700 "$SIGNING_TEMP"
  python3 - "$SIGNING_TEMP" <<'PY'
import base64, os, pathlib, sys
directory = pathlib.Path(sys.argv[1])
for variable, filename in [('IOS_CERTIFICATE_P12_BASE64', 'certificate.p12'), ('IOS_PROVISIONING_PROFILE_BASE64', 'profile.mobileprovision')]:
    path = directory / filename
    path.write_bytes(base64.b64decode(os.environ[variable], validate=True))
    path.chmod(0o600)
PY
  /usr/bin/security cms -D -i "$SIGNING_TEMP/profile.mobileprovision" > "$SIGNING_TEMP/profile.plist"
  python3 - "$SIGNING_TEMP/profile.plist" "$KOMIIC_BUNDLE_ID" <<'PY'
from datetime import datetime, timezone
import fnmatch, plistlib, re, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
if p['ExpirationDate'].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
    raise SystemExit('The provisioning profile has expired.')
identifier = p['Entitlements']['application-identifier'].split('.', 1)[1]
if not fnmatch.fnmatchcase(sys.argv[2], identifier):
    raise SystemExit('The provisioning profile does not authorize KOMIIC_BUNDLE_ID.')
if not p.get('ProvisionedDevices') and not p.get('ProvisionsAllDevices'):
    raise SystemExit('An App Store profile cannot produce a directly installable IPA. Use a development/ad-hoc/enterprise profile.')
if not re.fullmatch(r'[A-Fa-f0-9-]{36}', p['UUID']) or not re.fullmatch(r'[A-Z0-9]{10}', p['TeamIdentifier'][0]):
    raise SystemExit('Unexpected profile identifier or team format.')
PY
  PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$SIGNING_TEMP/profile.plist")"
  PROFILE_TEAM="$(/usr/libexec/PlistBuddy -c 'Print TeamIdentifier:0' "$SIGNING_TEMP/profile.plist")"
  PROFILE_DIRECTORY="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$PROFILE_DIRECTORY"
  PROFILE_PATH="$PROFILE_DIRECTORY/$PROFILE_UUID.mobileprovision"
  if [[ -e "$PROFILE_PATH" ]]; then
    cmp -s "$PROFILE_PATH" "$SIGNING_TEMP/profile.mobileprovision" || { printf 'A different profile with the same UUID already exists.\n' >&2; exit 1; }
  else
    cp "$SIGNING_TEMP/profile.mobileprovision" "$PROFILE_PATH"
    INSTALLED_PROFILE="$PROFILE_PATH"
  fi
  KEYCHAIN_PATH="$SIGNING_TEMP/build.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen)"
  /usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  /usr/bin/security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
  /usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  python3 - "$SIGNING_TEMP/keychain-search-list.json" "$KEYCHAIN_PATH" <<'PY'
import json, shlex, subprocess, sys
original = shlex.split(subprocess.check_output(['/usr/bin/security', 'list-keychains', '-d', 'user'], text=True))
with open(sys.argv[1], 'w') as output:
    json.dump(original, output)
subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', sys.argv[2], *original], check=True)
PY
  KEYCHAIN_SEARCH_CHANGED=1
  /usr/bin/security import "$SIGNING_TEMP/certificate.p12" -k "$KEYCHAIN_PATH" -P "$IOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  CERTIFICATE_ID="$(/usr/bin/security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk '/[A-F0-9]{40}/ {print $2; exit}')"
  [[ -n "$CERTIFICATE_ID" ]] || { printf 'The imported p12 does not contain a valid signing identity.\n' >&2; exit 1; }
  SIGNING_ARGUMENTS=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual \
    "DEVELOPMENT_TEAM=$PROFILE_TEAM" "PROVISIONING_PROFILE_SPECIFIER=$PROFILE_UUID" \
    "CODE_SIGN_IDENTITY=$CERTIFICATE_ID" "OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN_PATH")
fi

xcodebuild -project Komiic.xcodeproj -scheme Komiic -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_ROOT/DeviceDerivedData" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO TARGETED_DEVICE_FAMILY=1,2 \
  "PRODUCT_BUNDLE_IDENTIFIER=$KOMIIC_BUNDLE_ID" "${SIGNING_ARGUMENTS[@]}" build \
  2>&1 | tee "$ARTIFACT_DIR/device-build.log"

BUILT_APP="$BUILD_ROOT/DeviceDerivedData/Build/Products/Release-iphoneos/Komiic.app"
[[ -d "$BUILT_APP" ]] || { printf 'Xcode did not produce the device app.\n' >&2; exit 1; }
PACKAGE_ROOT="$BUILD_ROOT/package"
mkdir -p "$PACKAGE_ROOT/Payload"
ditto "$BUILT_APP" "$PACKAGE_ROOT/Payload/Komiic.app"
if [[ "$SIGNING_MODE" == "signed" ]]; then
  /usr/bin/codesign --verify --deep --strict "$PACKAGE_ROOT/Payload/Komiic.app"
  [[ -f "$PACKAGE_ROOT/Payload/Komiic.app/embedded.mobileprovision" ]] || { printf 'Signed app is missing its provisioning profile.\n' >&2; exit 1; }
else
  if /usr/bin/codesign -dv "$PACKAGE_ROOT/Payload/Komiic.app" >/dev/null 2>&1; then
    /usr/bin/codesign --remove-signature "$PACKAGE_ROOT/Payload/Komiic.app"
  fi
  if [[ -d "$PACKAGE_ROOT/Payload/Komiic.app/_CodeSignature" ]]; then
    rm -rf "$PACKAGE_ROOT/Payload/Komiic.app/_CodeSignature"
  fi
fi
IPA_PATH="$ARTIFACT_DIR/Komiic-iPhone-iPad-$SIGNING_MODE.ipa"
ditto -c -k --keepParent "$PACKAGE_ROOT/Payload" "$IPA_PATH"
python3 scripts/verify_ipa.py "$IPA_PATH" --expected-signing "$SIGNING_MODE" --output "$ARTIFACT_DIR/ipa-verification.json"
shasum -a 256 "$IPA_PATH" > "$ARTIFACT_DIR/SHA256SUMS.txt"
if [[ "$SIGNING_MODE" == "unsigned" ]]; then
  printf 'This IPA contains real iPhone/iPad device code but is unsigned. It cannot be installed until you sign it with your own authorized Apple certificate and provisioning.\n' > "$ARTIFACT_DIR/INSTALLATION.txt"
else
  printf 'This IPA is signed. Installation is limited to the devices and distribution permissions in the supplied provisioning profile.\n' > "$ARTIFACT_DIR/INSTALLATION.txt"
fi
cat "$ARTIFACT_DIR/INSTALLATION.txt"
printf 'IPA: %s\nArtifacts: %s\n' "$IPA_PATH" "$ARTIFACT_DIR"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ipa_path=%s\nartifact_dir=%s\n' "$IPA_PATH" "$ARTIFACT_DIR" >> "$GITHUB_OUTPUT"
fi
