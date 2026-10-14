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
    if checkbox {
        var parent = element
        for _ in 0..<12 {
            if attribute(parent,kAXRoleAttribute) as? String == kAXWindowRole {
                _ = AXUIElementPerformAction(parent,kAXRaiseAction as CFString)
                let windowFrame = rect(parent)
                let titlePoint = CGPoint(x:windowFrame.midX,y:windowFrame.minY+12)
                mouse(.leftMouseDown,at:titlePoint);Thread.sleep(forTimeInterval:0.08);mouse(.leftMouseUp,at:titlePoint);Thread.sleep(forTimeInterval:0.2)
                break
            }
            guard let raw=attribute(parent,kAXParentAttribute) else { break }
            parent=unsafeBitCast(raw,to:AXUIElement.self)
        }
    }
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
    try require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow", "Macのロックを解除してからUI検証を実行してください")
    let preferences = UserDefaults(suiteName: "local.codex.MenuDrawer")!
    try require((preferences.stringArray(forKey: "SelectedItems") ?? []).isEmpty, "検証前に選択を空にしてください")
    let cursor = CGEvent(source: nil)?.location
    defer { if let cursor { CGWarpMouseCursorPosition(cursor) } }
    guard let drawer=NSRunningApplication.runningApplications(withBundleIdentifier:"local.codex.MenuDrawer").first else { throw NSError(domain:"MenuDrawerUI",code:1) }
    let app = AXUIElementCreateApplication(drawer.processIdentifier)
    let entries = MenuItems.all(menuY: 18.5, ownPID: drawer.processIdentifier).filter { $0.canStore }
    let originalOrder = entries.map(\.selectionKey)
    try require(!entries.isEmpty, "実アイコンがありません")
    func toggleButton() -> AXUIElement? {
        guard let raw = attribute(app,kAXExtrasMenuBarAttribute) else { return nil }
        return find(unsafeBitCast(raw,to:AXUIElement.self)) { text($0).contains("収納したアイコン") }
    }
    func openSettings() throws {
        guard let toggle = toggleButton() else { throw NSError(domain:"MenuDrawerUI",code:1) }
        let frame = rect(toggle)
        for type in [CGEventType.rightMouseDown,.rightMouseUp] {
            let e=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:CGPoint(x:frame.midX,y:frame.midY),mouseButton:.right)!
            e.flags=[];e.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.08)
        }
        try require(waitUntil { find(app) { text($0)=="選択を保存" } != nil }, "右クリックで選択画面を開けません")
    }
    var previous: MenuEntry?
    for entry in entries.filter({ entry in ["ChatGPT", "入力メニュー", "バッテリー", "Wi‑Fi"].contains { entry.name.contains($0) } }) {
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
        try require(waitUntil { check = find(app) { attribute($0,kAXIdentifierAttribute) as? String == "select:" + entry.selectionKey };return check.flatMap { attribute($0,kAXValueAttribute) as? Int } == 1 }, "チェックできません: \(entry.name)")
        press(find(app) { text($0)=="選択を保存" }!)
        try require(waitUntil { (NativeItems.frame(entry.id)?.maxX ?? 1)<0 && toggleButton().flatMap { attribute($0,kAXEnabledAttribute) as? Bool } == true }, "選択した項目が収納されません: \(entry.name)")
        let visible = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        try require(entries.filter { $0.id != entry.id }.allSatisfy { visible.contains($0.id) }, "未選択の実アイコンも隠れました")
        let toggle = toggleButton()!

        try require(waitUntil { attribute(toggle, kAXEnabledAttribute) as? Bool == true }, "前の操作が完了しません")
        press(toggle)
        var row: AXUIElement?
        try require(waitUntil {
            guard let panel = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first(where: { text($0) == "収納したアイコン" }) else { return false }
            row = find(panel) { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).contains(entry.name) }
            return row != nil
        }, "実アイコンが一覧にありません: \(entry.name)")
        Thread.sleep(forTimeInterval: 0.4)
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
    try openSettings()
    func clear(_ e: AXUIElement) { if attribute(e,kAXRoleAttribute) as? String == kAXCheckBoxRole, attribute(e,kAXValueAttribute) as? Int == 1 { press(e) }; for c in attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { clear(c) } }
    clear(app)
    let pair = entries.filter { $0.name.contains("ChatGPT") || $0.name.contains("Wi‑Fi") }
    try require(pair.count == 2, "二項目同時表示の検証対象が足りません")
    for entry in pair {
        guard let check = find(app,where: { attribute($0,kAXIdentifierAttribute) as? String == "select:" + entry.selectionKey }) else { throw NSError(domain:"二項目選択",code:1) }
        press(check)
    }
    press(find(app) { text($0)=="選択を保存" }!)
    try require(waitUntil { pair.allSatisfy { (NativeItems.frame($0.id)?.maxX ?? 1) < 0 } && toggleButton().flatMap { attribute($0,kAXEnabledAttribute) as? Bool } == true }, "二項目を同時に収納できません")
    press(toggleButton()!)
    var pairPanel: AXUIElement?
    try require(waitUntil { pairPanel = (attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).first { text($0)=="収納したアイコン" };return pairPanel != nil }, "二項目のドロップダウンを開けません")
    let buttons = (attribute(pairPanel!,kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { (attribute($0,kAXIdentifierAttribute) as? String ?? "").hasPrefix("status-image:") }
    try require(buttons.count == 2, "二つの実アイコンが並んでいません")
    try require(abs(rect(buttons[0]).midY - rect(buttons[1]).midY)<1 && rect(pairPanel!).minY >= 37, "実アイコンがメニューバーの下に並びません")
    CGWarpMouseCursorPosition(CGPoint(x: 900, y: 240))
    Thread.sleep(forTimeInterval: 0.6)
    let output = FileManager.default.currentDirectoryPath + "/build/tests/"
    let snapshot = output + "panel-v05.png.dropdown.png"
    if FileManager.default.fileExists(atPath: snapshot) {
        let target = output + "pair-dropdown.png"
        try? FileManager.default.removeItem(atPath: target)
        try FileManager.default.copyItem(atPath: snapshot,toPath: target)
    }
    print("ChatGPTとWi‑Fiの二項目を同時に下へ表示: 成功")
    for entry in pair {
        if entry.id != pair.first!.id { press(toggleButton()!) }
        var row: AXUIElement?
        try require(waitUntil {
            guard let panel = (attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).first(where: { text($0)=="収納したアイコン" }) else {return false}
            row=find(panel) {attribute($0,kAXIdentifierAttribute) as? String == "status-image:" + entry.selectionKey};return row != nil
        }, "二項目の操作対象がありません")
        Thread.sleep(forTimeInterval:0.3)
        let before=NativeItems.visibleWindows(pid:entry.pid)
        press(row!)
        try require(waitUntil {!NativeItems.visibleWindows(pid:entry.pid).filter {before[$0.key]==nil && $0.value>0}.isEmpty}, "二項目収納から元のメニューを開けません: \(entry.name)")
        Thread.sleep(forTimeInterval:0.8)
        for down in [true,false] {CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:down)?.postToPid(entry.pid)}
        try require(waitUntil {pair.allSatisfy {(NativeItems.frame($0.id)?.maxX ?? 1)<0} && toggleButton().flatMap{attribute($0,kAXEnabledAttribute) as? Bool}==true}, "隣の収納項目を基準に再収納できません")
    }
    try openSettings()
    let chat=pair.first { $0.name.contains("ChatGPT") }!
    press(find(app) {attribute($0,kAXIdentifierAttribute) as? String == "select:" + chat.selectionKey}!)
    press(find(app) {text($0)=="選択を保存"}!)
    let wifi=pair.first {$0.id != chat.id}!
    try require(waitUntil {(NativeItems.frame(chat.id)?.minX ?? -1)>=0 && (NativeItems.frame(wifi.id)?.maxX ?? 1)<0 && toggleButton().flatMap{attribute($0,kAXEnabledAttribute) as? Bool}==true}, "片方だけを取り出せません")
    print("二項目から元メニューを操作・隣の項目の前へ再収納・片方だけを元へ戻す: 成功")
    // 検証に使った選択だけを解除し、空の選択で終了する。
    try openSettings()
    clear(app)
    press(find(app) { text($0)=="選択を保存" }!)
    try require(waitUntil { statusWindows(drawer.processIdentifier).filter { abs(windowRect($0).midY - 18.5) < 5 }.count == 1 }, "選択解除で区切りが撤去されません")
    let restored = MenuItems.all(menuY: 18.5, ownPID: drawer.processIdentifier).filter { $0.canStore }.map(\.selectionKey)
    let common = Set(restored).intersection(originalOrder)
    try require(restored.filter { common.contains($0) } == originalOrder.filter { common.contains($0) }, "元のネイティブ順序が戻りません")
    print("実アプリの選択解除後、元の順序へ復帰・区切り撤去: 成功")
}
do { try run() } catch { print(error.localizedDescription); exit(1) }
