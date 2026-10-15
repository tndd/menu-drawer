#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
bundle_stage=$(mktemp -d "$PWD/build/.bundle.XXXXXX")
trap 'rm -rf "$bundle_stage"' EXIT
built_app="$bundle_stage/MenuDrawer.app"
mkdir -p "$built_app/Contents/MacOS" "$built_app/Contents/Resources"
cp Resources/MenuDrawer.icns "$built_app/Contents/Resources/"
mkdir -p "$built_app/Contents/Resources/Notices"
cp THIRD_PARTY.md THIRD_PARTY/Ice-GPL-3.0.txt "$built_app/Contents/Resources/Notices/"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -O Sources/Failure.swift Sources/StatusWindows.swift Sources/ItemTransport.swift Sources/IconMover.swift Sources/StorageEngine.swift Sources/Brand.swift Sources/main.swift -framework Cocoa -o "$built_app/Contents/MacOS/MenuDrawer"
cat > "$built_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex.MenuDrawer</string>
<key>CFBundleName</key><string>MenuDrawer</string>
<key>CFBundleDisplayName</key><string>メニュードロワー</string>
<key>CFBundleExecutable</key><string>MenuDrawer</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.8.0</string>
<key>CFBundleIconFile</key><string>MenuDrawer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -replace CFBundleVersion -string "${MENUDRAWER_BUILD_NUMBER:-1}" "$built_app/Contents/Info.plist"
signing_identity=${MENUDRAWER_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '/"MenuDrawer Local Signing"/ {print $2; exit}')
fi
if [[ -z "$signing_identity" ]]; then
    if [[ "${MENUDRAWER_ALLOW_ADHOC:-0}" != 1 ]]; then
        printf '継続して使うための固定署名がありません。証明書作成の承認と準備後にビルドしてください。検証用に限りMENUDRAWER_ALLOW_ADHOC=1を指定できます。\n' >&2
        exit 1
    fi
    signing_identity=-
fi
codesign --force --sign "$signing_identity" --identifier local.codex.MenuDrawer "$built_app"
codesign --verify --deep --strict "$built_app"
ditto -c -k --sequesterRsrc --keepParent "$built_app" "$bundle_stage/MenuDrawer.zip"
mv "$bundle_stage/MenuDrawer.zip" build/MenuDrawer.zip
printf 'ビルド完了: %s/build/MenuDrawer.zip\n' "$PWD"
