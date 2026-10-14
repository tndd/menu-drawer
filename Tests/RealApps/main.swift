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
    let drawer = Process()
    drawer.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    drawer.arguments = ["--validation-output", CommandLine.arguments[2]]
    try drawer.run()
    defer { if drawer.isRunning { drawer.terminate(); drawer.waitUntilExit() } }
    let app = AXUIElementCreateApplication(drawer.processIdentifier)
    var start: AXUIElement?
    try require(waitUntil { start = find(app) { text($0) == "収納を開始" }; return start != nil || statusWindows(drawer.processIdentifier).contains { windowRect($0).width > 1000 } }, "起動待ちに失敗しました")
    if let start { press(start) }
    try require(waitUntil { statusWindows(drawer.processIdentifier).contains { windowRect($0).width > 1000 } }, "収納できませんでした")
    let dividerRow = statusWindows(drawer.processIdentifier).first { windowRect($0).width > 1000 }!
    let entries = MenuItems.entries(divider: windowRect(dividerRow), ownPID: drawer.processIdentifier)
    try require(!entries.isEmpty, "検証対象の実アイコンがありません")
    let raw = attribute(app, kAXExtrasMenuBarAttribute)!
    let bar = unsafeBitCast(raw, to: AXUIElement.self)
    let toggle = find(bar) { text($0).contains("収納したアイコン") }!
    for entry in entries {
        try require(waitUntil { attribute(toggle, kAXEnabledAttribute) as? Bool == true }, "前の操作が完了しません")
        press(toggle)
        var row: AXUIElement?
        try require(waitUntil {
            guard let panel = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first(where: { text($0) == "収納したアイコン" }) else { return false }
            row = find(panel) { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).contains(entry.name) }
            return row != nil
        }, "実アイコンが一覧にありません: \(entry.name)")
        let before = NativeItems.visibleWindows(pid: entry.pid)
        let beforeActive = NSWorkspace.shared.frontmostApplication?.processIdentifier
        press(row!)
        var added: [CGWindowID: Int] = [:]
        try require(waitUntil {
            added = NativeItems.visibleWindows(pid: entry.pid).filter { before[$0.key] == nil }
            return !added.isEmpty || (beforeActive != entry.pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid)
        }, "実クリック後に元アプリの表示変化がありません: \(entry.name)")
        Thread.sleep(forTimeInterval: 0.8)
        let transient = Set(added.filter { $0.value > 0 }.keys)
        try require(transient.isEmpty || !transient.isDisjoint(with: Set(NativeItems.visibleWindows(pid: entry.pid).keys)), "メニューが操作前に閉じてしまいました: \(entry.name)")
        if added.values.contains(where: { $0 > 0 }) {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.postToPid(entry.pid)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.postToPid(entry.pid)
        }
        try require(waitUntil {
            guard let frame = NativeItems.frame(entry.id) else { return false }
            return frame.maxX < 0 && attribute(toggle, kAXEnabledAttribute) as? Bool == true
        }, "操作後に収納へ戻りません: \(entry.name)")
        try require(find(app, where: { text($0).contains("メニューの表示を確認できなかった") }) == nil, "表示確認のエラーが残っています")
        print("実アイコン確認: \(entry.name) — クリックで表示・閉じた後に再収納")
    }
}
do { try run() } catch { print(error.localizedDescription); exit(1) }
