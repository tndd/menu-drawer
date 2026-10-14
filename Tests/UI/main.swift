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
func rect(_ element: AXUIElement) -> CGRect {
    var point = CGPoint.zero
    var size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) }
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) }
    return CGRect(origin: point, size: size)
}
func mouse(_ type: CGEventType, at point: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}
func press(_ element: AXUIElement) {
    let frame = rect(element)
    let point = CGPoint(x: frame.midX, y: frame.midY)
    mouse(.leftMouseDown, at: point)
    Thread.sleep(forTimeInterval: 0.08)
    mouse(.leftMouseUp, at: point)
}
func statusWindows(_ pid: pid_t) -> [[String: Any]] {
    (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 25 }
}
func windowRect(_ row: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: row[kCGWindowBounds as String] as! NSDictionary)! }
func popupExists(pid: pid_t) -> Bool {
    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return rows.contains { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 101 }
}
func run() throws {
    let cursor = CGEvent(source: nil)?.location
    defer { if let cursor { CGWarpMouseCursorPosition(cursor) } }
    try require(AXIsProcessTrusted(), "端末のアクセシビリティ権限が必要です")
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.MenuDrawer") { app.terminate() }
    try require(waitUntil { NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.MenuDrawer").isEmpty }, "旧版の終了待ちがタイムアウトしました")
    try? FileManager.default.removeItem(atPath: CommandLine.arguments[2])
    let executable = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixture = Process()
    fixture.executableURL = executable
    fixture.arguments = CommandLine.arguments.contains("--action") ? ["--fixture", "--fixture-action"] : ["--fixture"]
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
        return start != nil || statusWindows(drawer.processIdentifier).contains { windowRect($0).width > 1000 }
    }, "アプリが起動しませんでした")
    // 未設定時は実際の設定画面から開始する。設定済みなら自動収納を検証する。
    if let start { press(start) }
    try require(waitUntil { statusWindows(drawer.processIdentifier).contains { windowRect($0).width > 1000 } }, "収納を開始できませんでした")
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
    let actionMode = CommandLine.arguments.contains("--action")
    let fixtureAX = AXUIElementCreateApplication(fixture.processIdentifier)
    press(fixtureButton!)
    try require(waitUntil {
        if actionMode { return (attribute(fixtureAX, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains { text($0) == "検証用アプリ画面" } }
        return popupExists(pid: fixture.processIdentifier)
    }, "実クリックで元アプリのメニュー・画面が開きませんでした")
    if !actionMode {
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.postToPid(fixture.processIdentifier)
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.postToPid(fixture.processIdentifier)
    }
    try require(waitUntil {
        statusWindows(fixture.processIdentifier).contains { windowRect($0).width < 100 && windowRect($0).maxX < 0 } && attribute(toggle, kAXEnabledAttribute) as? Bool == true
    }, "メニューを閉じた後にアイコンが収納へ戻りませんでした")
    press(toggle)
    var dragButton: AXUIElement?
    try require(waitUntil {
        let panels = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let live = panels.first(where: { text($0) == "収納したアイコン" }) else { return false }
        dragButton = find(live) { (attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole && text($0).contains(" · T") }
        return dragButton != nil
    }, "戻ったアイコンが一覧にありません")
    let source = rect(dragButton!)
    let dragStart = CGPoint(x: source.midX, y: source.midY)
    let destination = CGPoint(x: min(1450, rect(panel).maxX + 60), y: rect(panel).maxY + 50)
    mouse(.leftMouseDown, at: dragStart)
    Thread.sleep(forTimeInterval: 0.1)
    for step in 1...8 {
        let fraction = CGFloat(step) / 8
        mouse(.leftMouseDragged, at: CGPoint(x: dragStart.x + (destination.x - dragStart.x) * fraction, y: dragStart.y + (destination.y - dragStart.y) * fraction))
        Thread.sleep(forTimeInterval: 0.08)
    }
    mouse(.leftMouseUp, at: destination)
    try require(waitUntil {
        statusWindows(fixture.processIdentifier).contains { windowRect($0).width < 100 && ($0[kCGWindowIsOnscreen as String] as? Bool ?? false) && windowRect($0).minX >= rect(toggle).maxX } && attribute(toggle, kAXEnabledAttribute) as? Bool == true
    }, "一覧の外への実ドラッグでアイコンを取り出せませんでした")
    press(toggle)
    var restore: AXUIElement?
    try require(waitUntil { restore = find(app) { attribute($0, kAXIdentifierAttribute) as? String == "restore-all" }; return restore != nil }, "すべて戻すボタンが見つかりません")
    press(restore!)
    try require(waitUntil { !statusWindows(drawer.processIdentifier).contains { windowRect($0).width > 1000 } }, "すべて戻す操作で収納が解除されませんでした")
    try require(find(app, where: { text($0).contains("の移動を確認できなかった") }) == nil, "移動エラーが出ています")
    print("実クリック → 元\(actionMode ? "アプリ画面" : "メニュー") → 自動収納 → 実ドラッグで取り出し → すべて戻す: 成功")

}
do { try run() } catch { print(error.localizedDescription); exit(1) }
