#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/Geometry.swift Tests/main.swift -o build/tests/geometry
build/tests/geometry
if [[ "${1:-}" == "--integration" ]]; then
    scripts/build.sh
    swiftc -swift-version 5 Sources/Geometry.swift Sources/MenuItems.swift Tests/Integration/main.swift -framework Cocoa -framework ApplicationServices -o build/tests/integration
    build/tests/integration "$PWD/build/MenuDrawer.app/Contents/MacOS/MenuDrawer"
    swiftc Tests/UI/main.swift -framework Cocoa -framework ApplicationServices -o build/tests/ui
    build/tests/ui "$PWD/build/MenuDrawer.app/Contents/MacOS/MenuDrawer" "$PWD/build/tests/panel.png"
fi
