import Cocoa
import ApplicationServices

struct MenuEntry {
    let id: CGWindowID
    let pid: pid_t
    let name: String
    let frame: CGRect
    let image: NSImage?
}

enum MenuItems {
    static func entries(divider: CGRect, ownPID: pid_t) -> [MenuEntry] {
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row -> MenuEntry? in
            guard row[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)),
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  DrawerGeometry.containsItem(frame, divider: divider) else { return nil }
            let owner = row[kCGWindowOwnerName as String] as? String ?? "アプリ"
            let title = row[kCGWindowName as String] as? String ?? ""
            let name = title.isEmpty || title == owner ? owner : "\(owner) · \(title)"
            let image = MDImageForWindow(id).map { NSImage(cgImage: $0.takeRetainedValue(), size: frame.size) }
            return MenuEntry(id: id, pid: pid, name: name, frame: frame, image: image)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    static func press(_ entry: MenuEntry) -> AXError {
        let application = AXUIElementCreateApplication(entry.pid)
        AXUIElementSetMessagingTimeout(application, 1.5)
        guard let raw = attribute(application, kAXExtrasMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .noValue }
        let bar = unsafeBitCast(raw, to: AXUIElement.self)
        let children = attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let matches = children.filter { child in
            guard let raw = attribute(child, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            var position = CGPoint.zero
            AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &position)
            guard let rawSize = attribute(child, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return false }
            var size = CGSize.zero
            AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
            return abs(position.x + size.width / 2 - entry.frame.midX) < 3 && abs(position.y + size.height / 2 - entry.frame.midY) < 3
        }
        // 座標が一致する対象だけを操作し、曖昧な場合に別のアイコンを押さない。
        guard matches.count == 1, let element = matches.first else { return .invalidUIElement }
        let before = popupWindows(pid: entry.pid)
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        // NSMenu は選択待ちの間 AXPress を返さない。タイムアウト時は実際の
        // メニューウィンドウが新しく表示された場合だけ成功として扱う。
        if result == .cannotComplete && !popupWindows(pid: entry.pid).subtracting(before).isEmpty { return .success }
        return result
    }

    private static func popupWindows(pid: pid_t) -> Set<CGWindowID> {
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(rows.compactMap { row in
            guard row[kCGWindowOwnerPID as String] as? pid_t == pid,
                  row[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)) else { return nil }
            return row[kCGWindowNumber as String] as? CGWindowID
        })
    }
}
