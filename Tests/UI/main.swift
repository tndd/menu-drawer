import Cocoa
import ApplicationServices

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "MenuDrawerUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func text(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }.joined(separator: " ")
}
func find(_ root: AXUIElement, depth: Int = 0, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    guard depth < 7 else { return nil }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let match = find(child, depth: depth + 1, where: predicate) { return match }
    }
    return nil
}
func waitUntil(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}
func press(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, 1)
    _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
}
func popupExists(pid: pid_t) -> Bool {
    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return rows.contains { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 101 }
}
func run() throws {
    try require(AXIsProcessTrusted(), "端末のアクセシビリティ権限が必要です")
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.MenuDrawer") { app.terminate() }
    try require(waitUntil { NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.MenuDrawer").isEmpty }, "旧版の終了待ちがタイムアウトしました")
    let executable = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixture = Process()
    fixture.executableURL = executable
    fixture.arguments = ["--fixture"]
    try fixture.run()
    defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
    Thread.sleep(forTimeInterval: 1)
    let drawer = Process()
    drawer.executableURL = executable
    drawer.arguments = ["--validation-output", CommandLine.arguments[2]]
    try drawer.run()
    defer { if drawer.isRunning { drawer.terminate(); drawer.waitUntilExit() } }
    let app = AXUIElementCreateApplication(drawer.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    var start: AXUIElement?
    try require(waitUntil {
        start = find(app) { text($0) == "収納を開始" }
        return start != nil || attribute(app, kAXExtrasMenuBarAttribute) != nil
    }, "アプリが起動しませんでした")
    // 未設定時は実際の設定画面から開始する。設定済みなら自動収納を検証する。
    if let start { press(start) }
    Thread.sleep(forTimeInterval: 0.5)
    guard let rawBar = attribute(app, kAXExtrasMenuBarAttribute) else { throw NSError(domain: "MenuDrawerUI", code: 2) }
    let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
    guard let toggle = find(bar, where: { text($0).contains("収納したアイコン") }) else { throw NSError(domain: "MenuDrawerUI", code: 3) }
    press(toggle)
    var panel: AXUIElement?
    try require(waitUntil {
        panel = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first { text($0) == "収納したアイコン" }
        return panel != nil
    }, "トレイボタンでパネルが開きませんでした")
    guard let panel else { return }
    if let value = attribute(panel, kAXPositionAttribute) {
        var position = CGPoint.zero
        AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &position)
        try require(position.y >= 37, "パネルがメニューバーの下に配置されていません")
        print("パネル位置: \(position)")
    }
    let fixtureButton = find(panel) { (attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole && text($0).contains(" · T") }
    try require(fixtureButton != nil, "収納した検証アイコンがパネルにありません")
    try require(FileManager.default.fileExists(atPath: CommandLine.arguments[2]), "実パネルの描画出力がありません")
    press(fixtureButton!)
    try require(waitUntil { popupExists(pid: fixture.processIdentifier) }, "パネルから元アプリのメニューが開きませんでした")
    // AXPress の応答期限は1.5秒。応答待ちの最中に検証プロセスを停止すると、
    // メニューは表示済みでも対象消失によるエラーになるため、応答完了を待って片付ける。
    Thread.sleep(forTimeInterval: 2)
    let alert = find(app) { text($0).contains("のメニューを開けませんでした") }
    try require(alert == nil, "メニュー表示後に操作エラーが出ました")
    print("設定 → 収納 → トレイボタン → 下方向のパネル → 元メニュー表示: 成功")
}
do { try run() } catch { print(error.localizedDescription); exit(1) }
