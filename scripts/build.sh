#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
bundle_stage=$(mktemp -d "$PWD/build/.bundle.XXXXXX")
trap 'rm -rf "$bundle_stage"' EXIT
built_app="$bundle_stage/MenuDrawer.app"
mkdir -p "$built_app/Contents/MacOS" "$built_app/Contents/Resources"
cp Resources/MenuDrawer.icns "$built_app/Contents/Resources/"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -O Sources/VisibilitySwitch.swift Sources/TypelessTarget.swift Sources/Brand.swift Sources/main.swift -framework Cocoa -o "$built_app/Contents/MacOS/MenuDrawer"
cat > "$built_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex.MenuDrawer</string>
<key>CFBundleName</key><string>MenuDrawer</string>
<key>CFBundleDisplayName</key><string>メニュードロワー</string>
<key>CFBundleExecutable</key><string>MenuDrawer</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleIconFile</key><string>MenuDrawer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.codex.MenuDrawer "$built_app"
codesign --verify --deep --strict "$built_app"
ditto -c -k --sequesterRsrc --keepParent "$built_app" build/MenuDrawer.zip
printf 'ビルド完了: %s/build/MenuDrawer.zip\n' "$PWD"
