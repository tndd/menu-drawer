#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -swift-version 5 -parse-as-library Sources/Failure.swift Sources/StatusWindows.swift Sources/ItemTransport.swift Sources/IconMover.swift Sources/StorageEngine.swift Tests/main.swift -framework Cocoa -o build/tests/unit
build/tests/unit
if [[ "${1:-}" == "--native" ]]; then
    scripts/test_native.sh
elif [[ "${1:-}" == "--real" ]]; then
    swiftc -swift-version 5 Sources/Failure.swift Sources/StatusWindows.swift Sources/ItemTransport.swift Sources/IconMover.swift Sources/StorageEngine.swift Tests/Real/main.swift -framework Cocoa -o build/tests/real-icons
    build/tests/real-icons
elif [[ "${1:-}" == "--live" ]]; then
    swiftc -swift-version 5 -parse-as-library Sources/Failure.swift Sources/StatusWindows.swift Tests/Live/main.swift -framework Cocoa -o build/tests/menu-live
    build/tests/menu-live
fi
