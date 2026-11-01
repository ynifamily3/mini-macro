#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile.}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
work="$PWD/build/release-$version"
out="$PWD/dist/v$version"
app="$work/Mouse Macro.app"
archive="mini-macro-$version-universal"
mkdir -p "$work" "$out"
if [[ -e "$out/$archive.zip" || -e "$out/$archive.dmg" ]]; then
    printf '%s\n' "Release artifacts already exist in $out. Move them aside before rebuilding." >&2
    exit 1
fi

MACMACRO_DISTRIBUTION=1 MACMACRO_UNIVERSAL=1 MACMACRO_APP_OUTPUT="$app" ./Scripts/build-app.sh
[[ "$(lipo -archs "$app/Contents/MacOS/MacMacro")" == *arm64* ]]
[[ "$(lipo -archs "$app/Contents/MacOS/MacMacro")" == *x86_64* ]]

# Staple the app before making either final archive; ZIP cannot hold its own ticket.
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarization-upload.zip"
xcrun notarytool submit "$work/notarization-upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m --output-format json > "$work/app-notarization.json"
python3 - "$work/app-notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('App notarization:', result.get('status'), result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('App notarization was not accepted; check the submission log.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$archive.zip"

stage=$(mktemp -d "$work/dmg.XXXXXX")
ditto "$app" "$stage/Mouse Macro.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Mini Macro $version" -srcfolder "$stage" -format UDZO -ov "$out/$archive.dmg"
identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -n 1)
[[ -n "$identity" ]]
codesign --force --timestamp --sign "$identity" "$out/$archive.dmg"
xcrun notarytool submit "$out/$archive.dmg" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m --output-format json > "$work/dmg-notarization.json"
python3 - "$work/dmg-notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('DMG notarization:', result.get('status'), result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('DMG notarization was not accepted; check the submission log.')
PY
xcrun stapler staple "$out/$archive.dmg"
xcrun stapler validate "$out/$archive.dmg"
codesign --verify --strict "$out/$archive.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$out/$archive.dmg"
(
    cd "$out"
    shasum -a 256 "$archive.dmg" "$archive.zip" > SHA256SUMS.txt
)
printf 'Release artifacts: %s\n' "$out"
