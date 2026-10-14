import Cocoa
import ApplicationServices
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "MenuDrawerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func run() throws {
let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
process.arguments = ["--fixture", "--fixture-hidden"]
try process.run()
defer { process.terminate(); process.waitUntilExit() }
Thread.sleep(forTimeInterval: 3)
try require(AXIsProcessTrusted(), "検証を実行する端末のアクセシビリティ権限が必要です")
print("画面収録権限: \(CGPreflightScreenCaptureAccess() ? "許可あり" : "未許可")")
let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = rows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == process.processIdentifier && $0[kCGWindowLayer as String] as? Int == 25 }
guard let divider = candidates.compactMap({ row -> CGRect? in
    guard let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: dictionary), rect.width > 1000 else { return nil }
    return rect
}).first else { throw NSError(domain: "MenuDrawerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "収納用の区切りが見つかりません"]) }
let entries = MenuItems.entries(divider: divider, ownPID: getpid()).filter { $0.pid == process.processIdentifier }
try require(entries.count == 1, "収納した実アイコンを過不足なく取得できませんでした")
for entry in entries {
    try require(entry.name.contains("T"), "アクセシビリティから項目名を取得できませんでした")
    try require(entry.image != nil, "アプリの通常アイコンを取得できませんでした")
    try require(entry.element != nil, "クリック対象が特定されていません")
    let row = candidates.first { $0[kCGWindowNumber as String] as? CGWindowID == entry.id }!
    try require((row[kCGWindowIsOnscreen as String] as? Bool ?? false) == false && entry.frame.maxX < 0, "検証アイコンは収納されている必要があります")
    let operation = DispatchGroup()
    var result: AXError = .failure
    operation.enter()
    DispatchQueue.global().async { result = MenuItems.press(entry); operation.leave() }
    let deadline = Date().addingTimeInterval(4)
    var sawMenu = false
    while Date() < deadline && !sawMenu {
        let after = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        sawMenu = after.contains { $0[kCGWindowOwnerPID as String] as? pid_t == process.processIdentifier && $0[kCGWindowLayer as String] as? Int == 101 }
        if !sawMenu { Thread.sleep(forTimeInterval: 0.05) }
    }
    try require(operation.wait(timeout: .now() + 3) == .success, "メニュー操作が完了しませんでした")
    try require(result == .success, "収納したアイコンのメニュー操作に失敗しました")
    try require(sawMenu, "元アプリのメニューが実際に表示されていません")
}

print("通常アイコン・名前の取得、収納中の対象特定、元メニューの実表示を確認")

}
do { try run() } catch { print(error.localizedDescription); exit(1) }
