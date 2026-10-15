#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -parse-as-library Sources/VisibilitySwitch.swift Tests/main.swift -o build/tests/switch
build/tests/switch
if [[ "${1:-}" == "--live" ]]; then
    swiftc -parse-as-library Sources/VisibilitySwitch.swift Sources/TypelessTarget.swift Tests/Live/main.swift -framework Cocoa -o build/tests/live
    build/tests/live
fi
