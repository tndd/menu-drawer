import Cocoa
import ApplicationServices

// Ice 11edd391のBridgingと同じWindowServer API。画像取得は行わない。
@_silgen_name("CGSMainConnectionID") private func mainConnection() -> Int32
@_silgen_name("CGSGetProcessMenuBarWindowList") private func statusWindows(_ connection: Int32, _ owner: Int32, _ capacity: Int32, _ ids: UnsafeMutablePointer<CGWindowID>, _ count: UnsafeMutablePointer<Int32>) -> CGError
@_silgen_name("CGSGetScreenRectForWindow") private func windowRect(_ connection: Int32, _ id: CGWindowID, _ rect: UnsafeMutablePointer<CGRect>) -> CGError

struct MenuIcon: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let name: String
    let detail: String
    let frame: CGRect
    let stableKey: String?
    let identifier: String
    init(id:CGWindowID,pid:pid_t,bundleID:String,name:String,detail:String,frame:CGRect,stableKey:String?,identifier:String="") {
        self.id=id; self.pid=pid; self.bundleID=bundleID; self.name=name; self.detail=detail; self.frame=frame; self.stableKey=stableKey; self.identifier=identifier
    }
    var title: String { detail.isEmpty || detail == name ? name : "\(name) — \(detail)" }
    var protectedReason: String? {
        if bundleID.lowercased() == "com.apple.siri" { return "SiriはmacOSが移動を禁止しています" }
        guard bundleID == "com.apple.controlcenter" else { return nil }
        let key = (identifier + " " + detail).lowercased()
        if frame.width > 100 || key.contains("clock") || key.contains("時計") { return "時計はmacOSが移動を禁止しています" }
        if key.contains("bentobox") || key.contains("control center") || key.contains("menuextra.controlcenter") || key.contains("コントロールセンター") { return "コントロールセンター本体はmacOSが移動を禁止しています" }
        if key.contains("audiovideo") || key.contains("facetime") || key.contains("musicrecognition") || key.contains("録画") || key.contains("プライバシー") { return "録画・録音の表示はmacOSが保護しています" }
        return nil
    }
}

enum StatusWindows {
    static func frame(_ id: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        guard windowRect(mainConnection(),id,&rect) == .success, rect.width > 0 else { return nil }
        return rect
    }
    @MainActor static func waitForFrame(_ id: CGWindowID) async throws -> CGRect {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if let rect = frame(id) { return rect }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw SwitchFailure(message:"メニューバーのウィンドウを確認できません：ID=\(id)")
    }
    private static func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e,key as CFString,&value) == .success else { return nil }
        return value
    }
    private static func labels(pid: pid_t) -> [(CGRect,String,String)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.15)
        guard let raw = value(app,kAXExtrasMenuBarAttribute) else { return [] }
        let bar = unsafeBitCast(raw,to: AXUIElement.self)
        return (value(bar,kAXChildrenAttribute) as? [AXUIElement] ?? []).compactMap { child in
            guard let p = value(child,kAXPositionAttribute), let s = value(child,kAXSizeAttribute) else { return nil }
            var point = CGPoint.zero; var size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p,to: AXValue.self),.cgPoint,&point), AXValueGetValue(unsafeBitCast(s,to: AXValue.self),.cgSize,&size) else { return nil }
            let identifier = value(child,kAXIdentifierAttribute) as? String ?? ""
            let label = [kAXDescriptionAttribute,kAXTitleAttribute,kAXIdentifierAttribute].compactMap { value(child,$0) as? String }.first { !$0.isEmpty } ?? ""
            return (CGRect(origin: point,size: size),label,identifier)
        }
    }
    @MainActor static func list(excludingPID: pid_t? = nil) -> [MenuIcon] {
        var ids = [CGWindowID](repeating: 0,count: 4096); var count: Int32 = 0
        guard statusWindows(mainConnection(),0,4096,&ids,&count) == .success else { return [] }
        let metadata = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
        let byID = Dictionary(uniqueKeysWithValues: metadata.compactMap { m -> (CGWindowID,[String:Any])? in
            guard let id = m[kCGWindowNumber as String] as? CGWindowID else { return nil }; return (id,m)
        })
        var ax: [pid_t:[(CGRect,String,String)]] = [:]
        var result: [MenuIcon] = []
        for id in ids.prefix(max(0,min(Int(count),ids.count))) {
            guard let m = byID[id], m[kCGWindowLayer as String] as? Int == 25,
                  let pid = m[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID,
                  let frame = frame(id), frame.height < 100,
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if ax[pid] == nil { ax[pid] = AXIsProcessTrusted() ? labels(pid: pid) : [] }
            // AXはアイコン内容の範囲、WindowServerは左右の余白を含む範囲を返す。
            // 実測で一致した中心座標を使って対応付ける。
            let accessibility = ax[pid]?.first { abs($0.0.midX-frame.midX) < 2 && abs($0.0.midY-frame.midY) < 2 }
            let label = accessibility?.1 ?? (m[kCGWindowName as String] as? String ?? "")
            let identity = accessibility?.2 ?? label
            result.append(MenuIcon(id: id,pid: pid,bundleID: app.bundleIdentifier ?? "pid:\(pid)",name: app.localizedName ?? (m[kCGWindowOwnerName as String] as? String ?? "アプリ"),detail: label,frame: frame,stableKey: identity.isEmpty ? nil : (app.bundleIdentifier ?? "") + ":" + identity,identifier:accessibility?.2 ?? ""))
        }
        // 単一アイコンはアプリID、複数は一意のラベルがある場合だけ再起動後も識別する。
        return result.map { item in
            let siblings = result.filter { $0.bundleID == item.bundleID }
            let sameLabel = siblings.filter { $0.stableKey == item.stableKey }
            let stable: String? = item.bundleID.hasPrefix("pid:") ? nil : siblings.count == 1 ? item.bundleID : item.stableKey != nil && sameLabel.count == 1 ? item.stableKey : nil
            return MenuIcon(id:item.id,pid:item.pid,bundleID:item.bundleID,name:item.name,detail:item.detail,frame:item.frame,stableKey:stable,identifier:item.identifier)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }
}
