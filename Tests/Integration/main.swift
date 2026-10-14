import Cocoa
import ApplicationServices
let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
process.arguments = ["--fixture", "--fixture-hidden"]
try process.run()
defer { process.terminate(); process.waitUntilExit() }
Thread.sleep(forTimeInterval: 3)
guard AXIsProcessTrusted() else { print("検証を実行する端末のアクセシビリティ権限が必要です"); exit(2) }
var checked = false
let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = rows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == process.processIdentifier && $0[kCGWindowLayer as String] as? Int == 25 }
for row in candidates {
    let bounds = CGRect(dictionaryRepresentation: row[kCGWindowBounds as String] as! NSDictionary)!
    guard bounds.width < 100 else { continue }
    let id = row[kCGWindowNumber as String] as! CGWindowID
    guard bounds.width > 0 else { continue }
    precondition(row[kCGWindowIsOnscreen as String] as? Bool == false, "検証アイコンは収納されている必要があります")
    let result = MenuItems.press(MenuEntry(id: id, pid: process.processIdentifier, name: "検証用", frame: bounds, image: nil))
    precondition(result == .success, "収納したアイコンのメニュー操作に失敗しました")
    Thread.sleep(forTimeInterval: 0.7)
    let after = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let menus = after.filter { $0[kCGWindowOwnerPID as String] as? pid_t == process.processIdentifier && $0[kCGWindowLayer as String] as? Int == 101 }
    precondition(!menus.isEmpty, "元アプリのメニューが実際に表示されていません")
    checked = true
}

precondition(checked, "検証用アイコンを発見できませんでした")
print("収納した別プロセスのアイコンから実メニューが開くことを確認")
