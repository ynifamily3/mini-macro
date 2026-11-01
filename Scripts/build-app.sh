#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Pin the certificate outside build/ so rebuilds keep the same code identity.
# A missing certificate must never silently downgrade the app to ad-hoc signing.
identity_file="$PWD/.codesign-identity"
distribution="${MACMACRO_DISTRIBUTION:-0}"
if [[ "$distribution" == 1 && -z "${MACMACRO_APP_OUTPUT:-}" ]]; then
    printf '%s\n' '배포 빌드에는 별도 MACMACRO_APP_OUTPUT 경로를 지정해주세요.' >&2
    exit 1
fi
identity="${CODE_SIGN_IDENTITY:-}"
if [[ "$distribution" != 1 && -z "$identity" && -s "$identity_file" ]]; then
    IFS= read -r identity < "$identity_file"
fi
identities="$(security find-identity -v -p codesigning)"
if [[ "$distribution" != 1 && -z "$identity" ]]; then
    identity="$(printf '%s\n' "$identities" | sed -n 's/.*) \([[:xdigit:]]\{40\}\) "Apple Development:.*".*/\1/p' | head -n 1)"
fi
if [[ -z "$identity" ]]; then
    identity="$(printf '%s\n' "$identities" | sed -n 's/.*) \([[:xdigit:]]\{40\}\) "Developer ID Application:.*".*/\1/p' | head -n 1)"
fi
resolved_identity="$(printf '%s\n' "$identities" | awk -v requested="$identity" '
    $1 ~ /^[0-9]+\)$/ {
        hash = $2
        name = $0
        sub(/^[^"]*"/, "", name)
        sub(/".*$/, "", name)
        if (toupper(hash) == toupper(requested) || name == requested) { print hash; exit }
    }
')"
if [[ -z "$resolved_identity" ]]; then
    printf '%s\n' '지정한 코드 서명 인증서를 찾을 수 없습니다. 키체인 인증서를 확인하거나 CODE_SIGN_IDENTITY로 인증서 이름 또는 SHA-1을 지정해주세요.' >&2
    exit 1
fi
if [[ "$distribution" == 1 ]]; then
    certificate_name="$(printf '%s\n' "$identities" | awk -v hash="$resolved_identity" '$2 == hash { print; exit }')"
    if [[ "$certificate_name" != *'"Developer ID Application:'* ]]; then
        printf '%s\n' '배포 빌드에는 Developer ID Application 인증서가 필요합니다.' >&2
        exit 1
    fi
fi
build_args=(-c release)
if [[ "${MACMACRO_UNIVERSAL:-0}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app="${MACMACRO_APP_OUTPUT:-$PWD/build/Mouse Macro.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/MacMacro" "$app/Contents/MacOS/MacMacro"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ ! -f build/AppIcon.icns || Scripts/MakeIcon.swift -nt build/AppIcon.icns ]]; then
    swift Scripts/MakeIcon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
sign_args=(--force --options runtime --sign "$resolved_identity")
if [[ "$distribution" == 1 ]]; then
    sign_args+=(--timestamp)
else
    sign_args+=(--timestamp=none)
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --strict "$app"
if [[ "$distribution" != 1 ]]; then
    printf '%s\n' "$resolved_identity" > "$identity_file"
fi
printf 'Built: %s\n' "$app"
if [[ "${1:-}" == "--open" ]]; then
    open "$app"
fi
