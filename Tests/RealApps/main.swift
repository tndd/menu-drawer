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
    guard depth < 10 else { return nil }
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
    let checkbox = attribute(element,kAXRoleAttribute) as? String == kAXCheckBoxRole
    let initial = attribute(element,kAXValueAttribute) as? Int
    let point = CGPoint(x: checkbox ? frame.minX + 8 : frame.midX, y: frame.midY)
    func click() { mouse(.leftMouseDown,at:point);Thread.sleep(forTimeInterval:0.08);mouse(.leftMouseUp,at:point);Thread.sleep(forTimeInterval:0.15) }
    click()
    if checkbox && attribute(element,kAXValueAttribute) as? Int == initial { click() }
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
    let preferences = UserDefaults(suiteName: "local.codex.MenuDrawer")!
    let originalSelection = preferences.stringArray(forKey: "SelectedItems") ?? []
    preferences.set([], forKey: "SelectedItems")
    preferences.synchronize()
    defer { preferences.set(originalSelection,forKey:"SelectedItems");preferences.synchronize() }
    let cursor = CGEvent(source: nil)?.location
    defer { if let cursor { CGWarpMouseCursorPosition(cursor) } }
    var drawer = Process()
    func launch() throws {
        drawer = Process()
        drawer.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        drawer.arguments = ["--validation-output", CommandLine.arguments[2]]
        try drawer.run()
    }
    try launch()
    defer { if drawer.isRunning { drawer.terminate(); drawer.waitUntilExit() } }
    var app = AXUIElementCreateApplication(drawer.processIdentifier)
    try require(waitUntil { find(app) { text($0) == "選択を保存" } != nil }, "選択設定が開きません")
    let frame = windowRect(statusWindows(drawer.processIdentifier).first!)
    let entries = MenuItems.all(menuY: frame.midY, ownPID: drawer.processIdentifier).filter { $0.canStore }
    try require(!entries.isEmpty, "実アイコンがありません")
    func toggleButton() -> AXUIElement? {
        guard let raw = attribute(app,kAXExtrasMenuBarAttribute) else { return nil }
        return find(unsafeBitCast(raw,to:AXUIElement.self)) { text($0).contains("収納したアイコン") }
    }
    func openSettings() throws {
        if find(app,where: { text($0) == "選択を保存" }) != nil { return }
        guard let toggle = toggleButton() else { throw NSError(domain:"MenuDrawerUI",code:1) }
        let frame = rect(toggle)
        for type in [CGEventType.rightMouseDown,.rightMouseUp] {
            let e=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:CGPoint(x:frame.midX,y:frame.midY),mouseButton:.right)!
            e.flags=[];e.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.08)
        }
        try require(waitUntil { find(app) { text($0)=="選択を保存" } != nil }, "右クリックで選択画面を開けません")
    }
    var previous: MenuEntry?
    for (index, entry) in entries.enumerated() {
        try openSettings()
        if let previous { try require((NativeItems.frame(previous.id)?.maxX ?? 1) < 0, "設定を開いただけで収納が解除されました") }
        var check: AXUIElement?
        try require(waitUntil { check=find(app) { attribute($0,kAXIdentifierAttribute) as? String == "select:" + entry.selectionKey }; return check != nil }, "選択できません: \(entry.name)")
        func update(_ e: AXUIElement) {
            if attribute(e,kAXRoleAttribute) as? String == kAXCheckBoxRole, attribute(e,kAXValueAttribute) as? Int == 1 { press(e) }
            for c in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { update(c) }
        }
        update(app)
        press(check!)
        try require(waitUntil { attribute(check!,kAXValueAttribute) as? Int == 1 }, "チェックできません: \(entry.name)")
        press(find(app) { text($0)=="選択を保存" }!)
        try require(waitUntil { (NativeItems.frame(entry.id)?.maxX ?? 1)<0 && toggleButton().flatMap { attribute($0,kAXEnabledAttribute) as? Bool } == true }, "選択した項目が収納されません: \(entry.name)")
        let visible = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        try require(entries.filter { $0.id != entry.id }.allSatisfy { visible.contains($0.id) }, "未選択の実アイコンも隠れました")
        if index == 0 {
            drawer.terminate();drawer.waitUntilExit()
            try launch();app=AXUIElementCreateApplication(drawer.processIdentifier)
            try require(waitUntil { (NativeItems.frame(entry.id)?.maxX ?? 1)<0 && toggleButton().flatMap { attribute($0,kAXEnabledAttribute) as? Bool } == true }, "再起動後に選択が保持されません")
            print("再起動後も選択した一項目だけを収納: 成功")
        }
        let toggle = toggleButton()!

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
        previous = entry
        print("選択した実アイコン確認: \(entry.name) — クリックで表示・閉じた後に再収納")
    }
    // 検証に使った選択だけを解除し、空の選択で終了する。
    try openSettings()
    func clear(_ e: AXUIElement) { if attribute(e,kAXRoleAttribute) as? String == kAXCheckBoxRole, attribute(e,kAXValueAttribute) as? Int == 1 { press(e) }; for c in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { clear(c) } }
    clear(app)
    press(find(app) { text($0)=="選択を保存" }!)
    try require(waitUntil { !statusWindows(drawer.processIdentifier).contains { windowRect($0).width>1000 } }, "選択解除で表示に戻りません")
}
do { try run() } catch { print(error.localizedDescription); exit(1) }
