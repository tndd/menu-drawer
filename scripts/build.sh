#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/MenuDrawer.app/Contents/MacOS
swiftc -swift-version 5 -target arm64-apple-macos14.0 -O Sources/Geometry.swift Sources/MenuItems.swift Sources/NativeItems.swift Sources/main.swift -framework Cocoa -framework ApplicationServices -o build/MenuDrawer.app/Contents/MacOS/MenuDrawer
cat > build/MenuDrawer.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex.MenuDrawer</string>
<key>CFBundleName</key><string>MenuDrawer</string>
<key>CFBundleDisplayName</key><string>メニュードロワー</string>
<key>CFBundleExecutable</key><string>MenuDrawer</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.codex.MenuDrawer build/MenuDrawer.app
printf 'ビルド完了: %s/build/MenuDrawer.app\n' "$PWD"
