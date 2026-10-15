#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/Failure.swift Sources/StatusWindows.swift Sources/DrawerWindow.swift Tests/Window/main.swift -framework Cocoa -o build/tests/window
build/tests/window
