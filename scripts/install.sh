#!/bin/bash
# 署名検証を先に済ませ、失敗したビルドや古い仮署名版で起動中アプリを上書きしない。
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib,tempfile,subprocess,shutil
root=pathlib.Path('build')
with tempfile.TemporaryDirectory(prefix='.install.',dir=root) as temp:
    subprocess.run(['ditto','-x','-k',str(root/'MenuDrawer.zip'),temp],check=True)
    app=pathlib.Path(temp)/'MenuDrawer.app'
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    detail=subprocess.run(['codesign','-d','--verbose=4','-r-',str(app)],capture_output=True,text=True,check=True).stderr
    if 'Authority=MenuDrawer Local Signing' not in detail or 'designated => cdhash ' in detail:
        raise SystemExit('固定署名版ではありません。起動中アプリを変更せず中止します。')
    code='''import Cocoa
let apps=NSRunningApplication.runningApplications(withBundleIdentifier:"local.codex.MenuDrawer")
for app in apps { guard app.terminate() else { exit(1) } }
let deadline=Date().addingTimeInterval(8)
while apps.contains(where:{!$0.isTerminated}) && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
if apps.contains(where:{!$0.isTerminated}) { exit(2) }
'''
    subprocess.run(['swift','-e',code],check=True)
    dest=pathlib.Path('/Applications/MenuDrawer.app')
    backup=pathlib.Path(temp)/'previous-bundle'
    if dest.exists():dest.rename(backup)
    try:shutil.move(str(app),dest)
    except BaseException:
        if backup.exists():backup.rename(dest)
        raise
    if backup.exists():shutil.rmtree(backup)
subprocess.run(['open','-g','-a','/Applications/MenuDrawer.app'],check=True)
print('固定署名版を/Applications/MenuDrawer.appへ配置しました。')
PY
