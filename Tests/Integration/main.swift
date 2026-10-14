import Cocoa
import ApplicationServices
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "MenuDrawerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func run() throws {
    try require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow", "Macのロックを解除してからUI検証を実行してください")
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
          let rect = CGRect(dictionaryRepresentation: dictionary), rect.width > 1000, abs(rect.midY - 18.5) < 5 else { return nil }
    return rect
}).first else { throw NSError(domain: "MenuDrawerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "収納用の区切りが見つかりません"]) }
let entries = MenuItems.entries(divider: divider, ownPID: getpid()).filter { $0.pid == process.processIdentifier }
try require(entries.count == 1, "収納した実アイコンを過不足なく取得できませんでした")
for entry in entries {
    try require(entry.name.contains("T"), "アクセシビリティから項目名を取得できませんでした")
    try require(entry.image == nil, "通常のアプリアイコンを実アイコンの代用にしています")
    try require(entry.element != nil, "クリック対象が特定されていません")
    let row = candidates.first { $0[kCGWindowNumber as String] as? CGWindowID == entry.id }!
    try require((row[kCGWindowIsOnscreen as String] as? Bool ?? false) == false && entry.frame.maxX < 0, "検証アイコンは収納されている必要があります")
    let dividerID = candidates.first { row in
        guard let bounds = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
        return frame.width > 1000
    }![kCGWindowNumber as String] as! CGWindowID
    print("検証: 画面外から取り出す")
    try NativeItems.move(entry, to: NativeItems.Anchor(id: dividerID, rightSide: true))
    print("移動後の座標", NativeItems.frame(entry.id) ?? .zero, "メニュー層", NativeItems.visibleWindows(pid: entry.pid).values.sorted())
    try NativeItems.click(entry)
    let deadline = Date().addingTimeInterval(3)
    var sawMenu = false
    while Date() < deadline && !sawMenu {
        sawMenu = NativeItems.visibleWindows(pid: entry.pid).values.contains(101)
        if !sawMenu { Thread.sleep(forTimeInterval: 0.05) }
    }
    try require(sawMenu, "本物のアイコンをクリックしてもメニューが表示されません")
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.postToPid(entry.pid)
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.postToPid(entry.pid)
    let closeDeadline = Date().addingTimeInterval(2)
    while NativeItems.visibleWindows(pid: entry.pid).values.contains(101), Date() < closeDeadline { Thread.sleep(forTimeInterval: 0.05) }
    Thread.sleep(forTimeInterval: 0.3)
    print("検証: メニューを閉じて再収納する")
    try NativeItems.move(entry, to: NativeItems.Anchor(id: dividerID, rightSide: false))
    try require((NativeItems.frame(entry.id)?.maxX ?? 1) < 0, "元の収納位置に戻りませんでした")
}

print("名前と操作対象の取得、本物のアイコンの取り出し・クリック・再収納を確認")

}
do { try run() } catch { print(error.localizedDescription); exit(1) }
