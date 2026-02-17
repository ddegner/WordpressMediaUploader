#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="WP Media Uploader"
PROJECT_PATH="WordpressMediaUploader.xcodeproj"
SCHEME="WordpressMediaUploader"
ENTITLEMENTS_PATH="Sources/WordpressImageUploaderApp/WPMediaUploader.entitlements"

DEVELOPER_ID_APP_CERT="${DEVELOPER_ID_APP_CERT:-Developer ID Application: David Degner (Q26G342EEL)}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"

notify() {
    local message="$1"
    /usr/bin/osascript -e "display notification \"${message}\" with title \"WP Media Uploader\"" >/dev/null 2>&1 || true
}

trap 'notify "Distribution build failed"' ERR

version="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)"
build_number="$(awk -F': ' '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"

if [[ -z "$version" || -z "$build_number" ]]; then
    echo "ERROR: Could not read version/build from project.yml"
    exit 1
fi

release_dir="output/release/v${version}"
derived_data_path="${release_dir}/DerivedData"
app_path="${derived_data_path}/Build/Products/Release/${APP_NAME}.app"
submit_zip="${release_dir}/WPMediaUploader-v${version}-submit.zip"
final_zip="WPMediaUploader-v${version}-macOS.zip"

mkdir -p "$release_dir"

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Release app (unsigned build output)"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    build | tee "${release_dir}/build.log"

if [[ ! -d "$app_path" ]]; then
    echo "ERROR: Expected app not found at: $app_path"
    exit 1
fi

echo "==> Signing app with Developer ID"
codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$DEVELOPER_ID_APP_CERT" \
    "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

echo "==> Creating notarization archive"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submit_zip"

echo "==> Submitting to Apple notarization service"
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    xcrun notarytool submit "$submit_zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait | tee "${release_dir}/notary.log"
elif [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
    xcrun notarytool submit \
        "$submit_zip" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait | tee "${release_dir}/notary.log"
else
    echo "ERROR: Notary credentials are missing."
    echo "Set NOTARY_KEYCHAIN_PROFILE, or set APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD."
    exit 1
fi

echo "==> Stapling notarization ticket"
staple_attempts=12
staple_delay_seconds=10
stapled=0

for ((attempt = 1; attempt <= staple_attempts; attempt++)); do
    echo "Staple attempt ${attempt}/${staple_attempts}"
    if xcrun stapler staple -v "$app_path"; then
        xcrun stapler validate -v "$app_path"
        stapled=1
        break
    fi
    if (( attempt < staple_attempts )); then
        echo "Stapling failed, retrying in ${staple_delay_seconds}s..."
        sleep "$staple_delay_seconds"
    fi
done

if (( stapled == 0 )); then
    echo "ERROR: Failed to staple notarization ticket after ${staple_attempts} attempts."
    exit 1
fi

echo "==> Creating final distribution archive"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$final_zip"
shasum -a 256 "$final_zip" | tee "${release_dir}/sha256.txt"

echo "==> Distribution build complete"
echo "Version: $version ($build_number)"
echo "Archive: $final_zip"
notify "Distribution build v${version} is ready"
