#!/bin/bash
# 権限のない一時アプリで失敗を起こす。カーソル操作・他アプリの収納は行わない。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -swift-version 5 Sources/Failure.swift Sources/StatusWindows.swift Sources/ItemTransport.swift Sources/IconMover.swift Sources/StorageEngine.swift Sources/Brand.swift Tests/Spacing/main.swift -framework Cocoa -o build/tests/spacing
swiftc Tests/Fixture/main.swift -framework Cocoa -o build/tests/fixture
swiftc Tests/Fixture/cleanup.swift -framework Cocoa -o build/tests/fixture-cleanup
spacing_stage=$(mktemp -d "$PWD/build/tests/spacing.XXXXXX")
trap 'build/tests/fixture-cleanup "$spacing_stage"; for app in "$spacing_stage"/*.app; do /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" >/dev/null 2>&1 || true; done; rm -rf "$spacing_stage"' EXIT
python3 - "$spacing_stage" <<'PY'
import pathlib,plistlib,shutil,subprocess,sys,uuid,time
root=pathlib.Path(sys.argv[1]); ids={}
for name,binary in [('Fixture','fixture'),('SpacingProbe','spacing')]:
 app=root/(name+'.app'); dest=app/'Contents/MacOS'/name
 dest.parent.mkdir(parents=True);shutil.copy2('build/tests/'+binary,dest)
 ids[name]='local.codex.MenuDrawerTest.'+uuid.uuid4().hex
 info={'CFBundleIdentifier':ids[name],'CFBundleName':'幅と空白の検証'+name,'CFBundleExecutable':name,'CFBundlePackageType':'APPL','LSUIElement':True,'FixtureStatusName':'SpacingFixture','FixtureLabel':'検証'}
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
subprocess.run(['open','-g',str(root/'Fixture.app')],check=True);time.sleep(1)
report=pathlib.Path('build/tests/spacing-result.txt').resolve()
report.unlink(missing_ok=True)
subprocess.run(['open','-g','-W',str(root/'SpacingProbe.app'),'--args',str(report),ids['Fixture']],check=True,timeout=30)
result=report.read_text();print(result)
if not result.startswith('成功'):raise SystemExit(1)
PY
