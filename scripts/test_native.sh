#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
if [[ "${1:-}" == "--live" ]]; then
    swiftc -swift-version 5 -parse-as-library Sources/Failure.swift Sources/StatusWindows.swift Tests/Live/main.swift -framework Cocoa -o build/tests/menu-live
else
    swiftc -swift-version 5 Sources/Failure.swift Sources/StatusWindows.swift Sources/ItemTransport.swift Sources/IconMover.swift Sources/StorageEngine.swift Tests/Native/main.swift -framework Cocoa -o build/tests/movement
fi
    swiftc Tests/Fixture/main.swift -framework Cocoa -o build/tests/fixture
    swiftc Tests/Fixture/cleanup.swift -framework Cocoa -o build/tests/fixture-cleanup
    fixture_stage=$(mktemp -d "$PWD/build/tests/fixtures.XXXXXX")
    trap 'build/tests/fixture-cleanup "$fixture_stage"; for fixture in "$fixture_stage"/*.app; do /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$fixture" >/dev/null 2>&1 || true; done; rm -rf "$fixture_stage"' EXIT
    python3 - "$fixture_stage" <<'PY'
import pathlib, plistlib, shutil, sys, uuid, subprocess
root=pathlib.Path(sys.argv[1])
for name in ['A','B','C']:
    app=root/('Fixture'+name+'.app'); binary=app/'Contents/MacOS/Fixture'
    binary.parent.mkdir(parents=True); shutil.copy2('build/tests/fixture',binary)
    info={'CFBundleIdentifier':'local.codex.MenuDrawerTest.'+uuid.uuid4().hex,'CFBundleName':'検証アプリ'+name,'CFBundleExecutable':'Fixture','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','LSUIElement':True,'FixtureStatusName':'Tray'+name,'FixtureLabel':name}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    if name != 'C': subprocess.run(['open','-g',str(app)],check=True)
PY
    sleep 2
    if [[ "${1:-}" == "--live" ]]; then
        build/tests/menu-live
    else
        build/tests/movement "$fixture_stage"
    fi
