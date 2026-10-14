#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/Geometry.swift Tests/main.swift -o build/tests/geometry
build/tests/geometry
if [[ "${1:-}" == "--integration" ]]; then
    scripts/build.sh
    swiftc -swift-version 5 -import-objc-header Sources/Capture.h Sources/Geometry.swift Sources/MenuItems.swift Tests/Integration/main.swift build/Capture.o -framework Cocoa -framework ApplicationServices -o build/tests/integration
    build/tests/integration "$PWD/build/MenuDrawer.app/Contents/MacOS/MenuDrawer"
fi
