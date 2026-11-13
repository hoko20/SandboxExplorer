#!/usr/bin/env bash
# SandboxExplorer IPA builder (runs on a macOS GitHub Actions runner).
#
# Environment:
#   SIGN_MODE=unsigned|signed        (default unsigned)
#   BUNDLE_ID, APP_GROUP_ID, DISPLAY_NAME
#   IOS_P12_BASE64, IOS_P12_PASSWORD, IOS_PROVISION_PROFILE_BASE64, IOS_TEAM_ID
#   KEYCHAIN_PASSWORD                (only used in signed mode)
#
# Outputs (dist/):
#   SandboxExplorer-unsigned.ipa / SandboxExplorer-signed.ipa
#   SandboxExplorer.entitlements.plist   <- use this when re-signing with a sideload tool
#   build-report.txt, xcodebuild.log

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN_MODE="${SIGN_MODE:-unsigned}"
BUNDLE_ID="${BUNDLE_ID:-dev.local.SandboxExplorer}"
APP_GROUP_ID="${APP_GROUP_ID:-group.dev.local.SandboxExplorer}"
DISPLAY_NAME="${DISPLAY_NAME:-SandboxExplorer}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="$ROOT/build/DerivedData"
STAGE="$ROOT/build/ipa-stage"
OUT="$ROOT/dist"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

echo "==> configure identities"
bash "$ROOT/Scripts/configure.sh" \
    --bundle-id "$BUNDLE_ID" \
    --app-group "$APP_GROUP_ID" \
    --display-name "$DISPLAY_NAME"

rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$OUT" "$DERIVED_DATA"

PROFILE_UUID=""
if [[ "$SIGN_MODE" == "signed" ]]; then
    for required in IOS_P12_BASE64 IOS_P12_PASSWORD IOS_PROVISION_PROFILE_BASE64 IOS_TEAM_ID; do
        if [[ -z "${!required:-}" ]]; then
            echo "build_ipa.sh: signed mode requires secret $required" >&2
            exit 1
        fi
    done
    KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-$(uuidgen)}"
    KEYCHAIN="$RUNNER_TEMP/sandboxexplorer-build.keychain-db"

    echo "==> import signing identity"
    python3 -c 'import base64,os,sys; open(sys.argv[1],"wb").write(base64.b64decode(os.environ["IOS_P12_BASE64"]))' \
        "$RUNNER_TEMP/cert.p12"
    python3 -c 'import base64,os,sys; open(sys.argv[1],"wb").write(base64.b64decode(os.environ["IOS_PROVISION_PROFILE_BASE64"]))' \
        "$RUNNER_TEMP/profile.mobileprovision"

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" \
        -P "$IOS_P12_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

    security cms -D -i "$RUNNER_TEMP/profile.mobileprovision" > "$RUNNER_TEMP/profile.plist"
    PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$RUNNER_TEMP/profile.plist")"
    PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$PROFILE_DIR"
    cp "$RUNNER_TEMP/profile.mobileprovision" "$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
    echo "    provisioning profile UUID: $PROFILE_UUID"
fi

echo "==> xcodebuild ($CONFIGURATION, iphoneos, $SIGN_MODE)"
COMMON=(
    -project "$ROOT/SandboxExplorer.xcodeproj"
    -scheme SandboxExplorer
    -configuration "$CONFIGURATION"
    -sdk iphoneos
    -destination 'generic/platform=iOS'
    -derivedDataPath "$DERIVED_DATA"
    ONLY_ACTIVE_ARCH=NO
    APP_BUNDLE_ID="$BUNDLE_ID"
    APP_GROUP_ID="$APP_GROUP_ID"
    APP_DISPLAY_NAME="$DISPLAY_NAME"
)

if [[ "$SIGN_MODE" == "signed" ]]; then
    xcodebuild "${COMMON[@]}" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="Apple Development" \
        DEVELOPMENT_TEAM="$IOS_TEAM_ID" \
        PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
        build 2>&1 | tee "$OUT/xcodebuild.log"
else
    xcodebuild "${COMMON[@]}" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGN_STYLE=Manual \
        build 2>&1 | tee "$OUT/xcodebuild.log"
fi

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/SandboxExplorer.app"
if [[ ! -d "$APP" ]]; then
    echo "build_ipa.sh: expected product not found at $APP" >&2
    exit 1
fi

echo "==> verify built bundle"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :WQAppGroupIdentifier' "$APP/Info.plist"
if [[ "$SIGN_MODE" == "signed" ]]; then
    codesign -dvv "$APP" 2>&1 | head -n 12
    codesign -d --entitlements :- "$APP" 2>/dev/null | head -n 30 || true
fi

echo "==> package IPA"
cp -R "$APP" "$STAGE/Payload/"
# Preserve symlinks inside frameworks / bundles and keep executable permissions.
(cd "$STAGE" && zip -qry "$OUT/SandboxExplorer-$SIGN_MODE.ipa" Payload)
cp "$ROOT/Config/SandboxExplorer.entitlements" "$OUT/SandboxExplorer.entitlements.plist"

echo "==> validate IPA"
unzip -t "$OUT/SandboxExplorer-$SIGN_MODE.ipa" >/dev/null
unzip -l "$OUT/SandboxExplorer-$SIGN_MODE.ipa" | grep -q "Payload/SandboxExplorer.app/Info.plist"

IPA="$OUT/SandboxExplorer-$SIGN_MODE.ipa"
{
    echo "SandboxExplorer build report"
    echo "generated       : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runner          : $(sw_vers -productVersion)"
    echo "xcode           : $(xcodebuild -version | tr '\n' ' ')"
    echo "iphoneos SDK    : $(xcrun --sdk iphoneos --show-sdk-version)"
    echo "configuration   : $CONFIGURATION"
    echo "sign mode       : $SIGN_MODE"
    echo "bundle id       : $BUNDLE_ID"
    echo "app group       : $APP_GROUP_ID"
    echo "display name    : $DISPLAY_NAME"
    echo "provision uuid  : ${PROFILE_UUID:-n/a}"
    echo "ipa             : $IPA"
    echo "ipa bytes       : $(stat -f%z "$IPA")"
    echo "ipa sha256      : $(shasum -a 256 "$IPA" | awk '{print $1}')"
} > "$OUT/build-report.txt"

cat "$OUT/build-report.txt"
echo "==> done"
