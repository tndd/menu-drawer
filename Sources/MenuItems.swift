import Cocoa
import ApplicationServices

struct MenuEntry {
    let id: CGWindowID
    let pid: pid_t
    let name: String
    let frame: CGRect
    var image: NSImage?
    var element: AXUIElement? = nil
    var selectionKey: String = ""
    var canStore: Bool = true
}

enum MenuItems {
    static func entries(divider: CGRect, ownPID: pid_t) -> [MenuEntry] {
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        var childrenByPID: [pid_t: [AXUIElement]] = [:]
        return rows.compactMap { row -> MenuEntry? in
            guard row[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)),
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  DrawerGeometry.containsItem(frame, divider: divider) else { return nil }
            if childrenByPID[pid] == nil { childrenByPID[pid] = menuBarChildren(pid: pid) }
            // AX側でも実在を確認し、非表示の古いウィンドウを一覧へ混ぜない。
            guard let element = matchingElement(in: childrenByPID[pid] ?? [], frame: frame) else { return nil }
            let application = NSRunningApplication(processIdentifier: pid)
            let owner = application?.bundleIdentifier == "com.apple.TextInputMenuAgent" ? "入力メニュー" : application?.localizedName ?? "アプリ"
            let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }.first { !$0.isEmpty }
            let name = label.map { $0 == owner || application?.bundleIdentifier == "com.apple.controlcenter" ? $0 : "\(owner) · \($0)" } ?? owner
            let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? ""
            let children = childrenByPID[pid] ?? []
            let index = children.firstIndex { CFEqual($0, element) } ?? 0
            let key = (application?.bundleIdentifier ?? application?.bundleURL?.path ?? owner) + "#" + (identifier.isEmpty ? String(index) : identifier)
            let fixed = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"].contains(identifier)
            return MenuEntry(id: id, pid: pid, name: name, frame: frame, image: nil, element: element, selectionKey: key, canStore: !fixed)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func all(menuY: CGFloat, ownPID: pid_t) -> [MenuEntry] {
        entries(divider: CGRect(x: -100000, y: menuY - 18.5, width: 200000, height: 37), ownPID: ownPID)
    }

    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func menuBarChildren(pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let raw = attribute(application, kAXExtrasMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
        let bar = unsafeBitCast(raw, to: AXUIElement.self)
        return attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func matchingElement(in children: [AXUIElement], frame: CGRect) -> AXUIElement? {
        let matches = children.filter { child in
            guard let raw = attribute(child, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID(),
                  let rawSize = attribute(child, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return false }
            var position = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &position)
            AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
            return abs(position.x + size.width / 2 - frame.midX) < 3 && abs(position.y + size.height / 2 - frame.midY) < 3
        }
        return matches.count == 1 ? matches.first : nil
    }

}
