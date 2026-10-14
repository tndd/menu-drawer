#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/Geometry.swift Tests/main.swift -o build/tests/geometry
build/tests/geometry
if [[ "${1:-}" == "--integration" ]]; then
    swiftc -swift-version 5 Sources/Geometry.swift Sources/MenuItems.swift Sources/NativeItems.swift Tests/Integration/main.swift -framework Cocoa -framework ApplicationServices -o build/tests/integration
    build/tests/integration /Applications/MenuDrawer.app/Contents/MacOS/MenuDrawer
    swiftc Sources/Geometry.swift Sources/MenuItems.swift Tests/Live/main.swift -framework Cocoa -framework ApplicationServices -o build/tests/ui
    build/tests/ui
    build/tests/ui --action
fi

if [[ "${1:-}" == "--real" ]]; then
    swiftc Sources/Geometry.swift Sources/MenuItems.swift Sources/NativeItems.swift Tests/RealApps/main.swift -framework Cocoa -framework ApplicationServices -o build/tests/real
    build/tests/real
fi
