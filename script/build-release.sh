#!/bin/bash
# Build the app/CLI pair, then sign the final notarized archive for Sparkle.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Set VERSION}"
: "${RELEASE_DIR:?Set RELEASE_DIR}"
: "${RELEASE_REPOSITORY:?Set RELEASE_REPOSITORY}"
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY}"
: "${SPARKLE_PUBLIC_KEY:?Set the fork Sparkle public key}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid release repository" >&2; exit 1; }
[[ "$RELEASE_TAG" == "v$VERSION" ]] || { echo "Release tag must be v$VERSION" >&2; exit 1; }
if [[ "$GENERATE_APPCAST" == 1 || "$NOTARIZE" == 1 || "$PUBLISH" == 1 ]]; then
    [[ "$CODESIGN_IDENTITY" != - && -n "$DEVELOPMENT_TEAM" ]] || { echo "Signed releases require your Developer ID and Team ID" >&2; exit 1; }
fi
if [[ "$PUBLISH" == 1 && ( "$NOTARIZE" != 1 || "$GENERATE_APPCAST" != 1 ) ]]; then
    echo "Publishing requires NOTARIZE=1 and GENERATE_APPCAST=1" >&2
    exit 1
fi
if [[ "${1:-}" == --check ]]; then
    if [[ "$CODESIGN_IDENTITY" != - ]]; then
        identities="$(security find-identity -v -p codesigning)"
        if ! printf '%s\n' "$identities" | grep -F -- "$CODESIGN_IDENTITY" >/dev/null; then
            echo "Install the signing certificate and private key for CODESIGN_IDENTITY before building." >&2
            exit 1
        fi
    fi
    if [[ "$PUBLISH" == 1 ]]; then
        if [[ -n "$(git status --porcelain)" ]]; then
            echo "Commit source changes before publishing a tagged release." >&2
            exit 1
        fi
        python3 -B script/ci-release.py check "$RELEASE_TAG" "$RELEASE_REPOSITORY"
    fi
    exit 0
fi
source script/setup.sh

mkdir -p "$RELEASE_DIR"
release_dir="$(cd "$RELEASE_DIR" && pwd)"
archive="$release_dir/WinMux-$VERSION.xcarchive"
app="$archive/Products/Applications/WinMux.app"
derived="$release_dir/WinMux-$VERSION.deriveddata"
export_dir="$release_dir/WinMux-$VERSION.export"
app_zip="$release_dir/WinMux-$VERSION.zip"
dist="$release_dir/WinMux-$VERSION-macOS"
dist_zip="$dist.zip"
dmg="$release_dir/WinMux-$VERSION.dmg"
feed_url="${UPDATE_FEED_URL:-https://raw.githubusercontent.com/$RELEASE_REPOSITORY/updates/prerelease.xml}"
download_prefix="https://github.com/$RELEASE_REPOSITORY/releases/download/$RELEASE_TAG/"
cli="$CLI_STAGE_PATH"
test -x "$cli"
rm -rf "$archive" "$derived" "$export_dir" "$dist"
rm -f "$app_zip" "$dist_zip" "$dmg" "$release_dir/appcast.xml" "$release_dir/SHA256SUMS"

hardened_runtime=YES
if [[ "$CODESIGN_IDENTITY" == - ]]; then hardened_runtime=NO; fi
xcodebuild-pretty "$release_dir/WinMux-$VERSION-xcodebuild.log" \
    -project WinMux.xcodeproj -scheme WinMux -configuration Release \
    -archivePath "$archive" -derivedDataPath "$derived" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME="$hardened_runtime" \
    CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE="$CODESIGN_STYLE" archive
test -d "$app"

# Keep the CLI outside MacOS: WinMux and winmux alias on default macOS volumes.
# Insert the independently signed helper before the final bundle signature.
mkdir -p "$app/Contents/Helpers"
/usr/bin/install -m 755 "$cli" "$app/Contents/Helpers/winmux"
python3 -B script/verify-bundle-executables.py "$app"
sign_args=(--force --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != - ]]; then sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" --entitlements resources/WinMux.entitlements "$app"

archive_signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
if [[ "$archive_signature" == *"Authority=Developer ID Application:"* ]]; then
    : "${DEVELOPMENT_TEAM:?Set your Apple Team ID}"
    # Export distributes and re-signs nested Sparkle helpers using the same identity.
    export_plist="$release_dir/ExportOptions.plist"
    python3 - "$export_plist" "$DEVELOPMENT_TEAM" "$CODESIGN_IDENTITY" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'method': 'developer-id', 'teamID': sys.argv[2],
                  'signingStyle': 'manual', 'signingCertificate': sys.argv[3]}, stream)
PY
    xcodebuild-pretty "$release_dir/WinMux-$VERSION-export.log" \
        -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
        -exportOptionsPlist "$export_plist"
    test -x "$export_dir/WinMux.app/Contents/Helpers/winmux"
    rm -rf "$app"
    ditto "$export_dir/WinMux.app" "$app"
elif [[ "$NOTARIZE" == 1 || "$GENERATE_APPCAST" == 1 || "$PUBLISH" == 1 ]]; then
    echo "Distribution updates require a Developer ID Application signature" >&2
    exit 1
fi
python3 -B script/verify-bundle-executables.py "$app"

verify_code() {
    codesign --verify --strict --verbose=2 "$1"
    if [[ -n "$EXPECTED_CODESIGN_AUTHORITY_PREFIX" ]]; then
        local details
        details="$(codesign -dv --verbose=4 "$1" 2>&1)"
        printf '%s\n' "$details" | grep -F "$EXPECTED_CODESIGN_AUTHORITY_PREFIX" >/dev/null
        printf '%s\n' "$details" | grep -Fx "TeamIdentifier=$DEVELOPMENT_TEAM" >/dev/null
    fi
}
codesign --verify --deep --strict --verbose=2 "$app"
verify_code "$app"
verify_code "$app/Contents/Helpers/winmux"
if [[ "$archive_signature" == *"Authority=Developer ID Application:"* ]]; then
    while IFS= read -r -d '' nested; do
        verify_code "$nested"
    done < <(find "$app/Contents" -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print0)
fi
for executable in "$app/Contents/MacOS/WinMux" "$app/Contents/Helpers/winmux"; do
    archs="$(lipo -archs "$executable")"
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || { echo "Missing universal slices: $executable" >&2; exit 1; }
done

python3 - "$app/Contents/Info.plist" "$VERSION" "$feed_url" "$SPARKLE_PUBLIC_KEY" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
expected = {'CFBundleVersion': sys.argv[2], 'CFBundleShortVersionString': sys.argv[2],
            'SUFeedURL': sys.argv[3], 'SUPublicEDKey': sys.argv[4],
            'SUEnableAutomaticChecks': True, 'SUAutomaticallyUpdate': True}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f'Incorrect {key} in release bundle')
PY
generated_hash="$(sed -n 's/^public let gitHash = "\(.*\)"/\1/p' Sources/Common/gitHashGenerated.swift)"
test "$generated_hash" = "$(git rev-parse HEAD)"
for executable in "$app/Contents/MacOS/WinMux" "$app/Contents/Helpers/winmux"; do
    # Avoid running the window manager during packaging.
    strings "$executable" | grep -Fx "$VERSION" >/dev/null
    strings "$executable" | grep -Fx "$generated_hash" >/dev/null
done
# Preserve and validate the exact exported CLI before any notarization upload.
/usr/bin/install -m 755 "$app/Contents/Helpers/winmux" "$cli"
verify_code "$cli"
ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip"
notary_args=(--keychain-profile "$NOTARYTOOL_PROFILE" --wait)
if [[ -n "$NOTARYTOOL_KEYCHAIN" ]]; then notary_args+=(--keychain "$NOTARYTOOL_KEYCHAIN"); fi
if [[ "$NOTARIZE" == 1 ]]; then
    xcrun notarytool submit "$app_zip" "${notary_args[@]}"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
    spctl --assess --type execute --verbose=4 "$app"
    rm -f "$app_zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip"
fi

mkdir -p "$dist/bin" "$dist/docs"
ditto "$app" "$dist/WinMux.app"
/usr/bin/install -m 755 script/winmux-launcher.sh "$dist/bin/winmux"
cp docs/cli.md docs/releasing.md "$dist/docs/"
cat > "$dist/README.txt" <<'EOF'
Copy WinMux.app to /Applications. Install bin/winmux on your PATH to run the CLI
inside the installed app. Sparkle updates replace the app and embedded CLI together.
For a custom app location set WINMUX_APP_PATH to its absolute .app path.
Existing upstream/ad-hoc builds require this first fork installation manually.
See docs/cli.md and docs/releasing.md for setup and signing details.
EOF
ditto -c -k --sequesterRsrc --keepParent "$dist" "$dist_zip"
dmg_stage="$(mktemp -d "$release_dir/dmg-stage.XXXXXX")"
appcast_stage=""
cleanup() {
    rm -rf "$dmg_stage"
    if [[ -n "$appcast_stage" ]]; then rm -rf "$appcast_stage"; fi
}
trap cleanup EXIT
ditto "$dist" "$dmg_stage"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create -volname "WinMux $VERSION" -srcfolder "$dmg_stage" -ov -format UDZO "$dmg"
if [[ "$CODESIGN_IDENTITY" != - ]]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$dmg"
    verify_code "$dmg"
fi
if [[ "$NOTARIZE" == 1 ]]; then
    xcrun notarytool submit "$dmg" "${notary_args[@]}"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
fi
hdiutil verify "$dmg"

# Sign only after the published ZIP is final. Stapling changes archive bytes.
if [[ "$GENERATE_APPCAST" == 1 ]]; then
    sparkle_bin="$(find "$derived/SourcePackages/artifacts" -type f -name generate_appcast -print -quit)"
    test -n "$sparkle_bin"
    sparkle_dir="$(dirname "$sparkle_bin")"
    key_args=(--account "$SPARKLE_ACCOUNT")
    if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then key_args=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"); fi
    appcast_stage="$(mktemp -d "$release_dir/appcast-stage.XXXXXX")"
    cp "$app_zip" "$appcast_stage/"
    "$sparkle_bin" "${key_args[@]}" --download-url-prefix "$download_prefix" -o "$appcast_stage/appcast.xml" "$appcast_stage"
    cp "$appcast_stage/appcast.xml" "$release_dir/appcast.xml"
    python3 -B script/validate-appcast.py "$release_dir/appcast.xml" "$VERSION" \
        "$download_prefix$(basename "$app_zip")" --archive "$app_zip"
    signature="$(python3 - "$release_dir/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).find('channel/item/enclosure').get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'))
PY
)"
    "$sparkle_dir/sign_update" --verify "${key_args[@]}" "$app_zip" "$signature"
fi
(
    cd "$release_dir"
    assets=("$(basename "$app_zip")" "$(basename "$dist_zip")" "$(basename "$dmg")")
    if [[ "$GENERATE_APPCAST" == 1 ]]; then assets+=(appcast.xml); fi
    shasum -a 256 "${assets[@]}" > SHA256SUMS
)
if [[ "$PUBLISH" == 1 ]]; then
    /bin/bash script/publish-release.sh
else
    echo "Built $dmg; publishing is disabled (PUBLISH=$PUBLISH)."
fi
