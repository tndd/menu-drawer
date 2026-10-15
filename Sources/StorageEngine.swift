import Cocoa
import ApplicationServices

struct RestorePosition {
    let right: [CGWindowID]
    let left: [CGWindowID]
    func destination(available: Set<CGWindowID>, hidden: Set<CGWindowID>, boundary: CGWindowID) -> (CGWindowID,Bool) {
        if let id = right.first(where: { available.contains($0) && !hidden.contains($0) }) { return (id,true) }
        if let id = left.first(where: { available.contains($0) && !hidden.contains($0) }) { return (id,false) }
        return (boundary,false)
    }
}

@MainActor final class StorageEngine {
    private var boundary: NSStatusItem?
    private var selected: [CGWindowID:MenuIcon] = [:]
    private var positions: [CGWindowID:RestorePosition] = [:]
    private var insertionOrder: [CGWindowID] = []
    private let mover = IconMover()
    private(set) var isBusy = false
    var lastCursor: IconMover.CursorReport? { mover.lastCursor }
    var count: Int { selected.count }
    var selectedIDs: Set<CGWindowID> { Set(selected.keys) }
    var isCollapsed: Bool { boundary.map { $0.length > 100 } ?? false }
    private var savedKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey:"selectedStatusIdentities") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(),forKey:"selectedStatusIdentities") }
    }
    func items() -> [MenuIcon] {
        let live = StatusWindows.list(excludingPID:getpid())
        // 収納後にAXラベルが取得できなくなるアプリでも、選択時の名前を保持する。
        return live.map { icon in
            guard let saved = selected[icon.id] else { return icon }
            return MenuIcon(id:icon.id,pid:icon.pid,bundleID:icon.bundleID,name:saved.name,detail:saved.detail,frame:icon.frame,stableKey:saved.stableKey,identifier:saved.identifier)
        }
    }
    private func boundaryID() throws -> CGWindowID {
        guard let number = boundary?.button?.window?.windowNumber, number > 0 else { throw SwitchFailure(message:"収納境界が見つかりません") }
        return CGWindowID(number)
    }
    private func ensureBoundary() async throws -> CGWindowID {
        if boundary == nil {
            boundary = NSStatusBar.system.statusItem(withLength:8)
            boundary?.button?.setAccessibilityLabel("収納境界")
            boundary?.button?.isEnabled = false
        }
        let id = try boundaryID()
        _ = try await StatusWindows.waitForFrame(id)
        return id
    }
    private func expand() async throws {
        guard let boundary else { return }
        boundary.length = 8
        let id = try boundaryID()
        let until = Date().addingTimeInterval(1)
        while Date() < until {
            if let f = StatusWindows.frame(id), f.width < 100 { return }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw SwitchFailure(message:"収納境界の展開を確認できません")
    }
    private func collapse() async throws {
        guard let boundary else { return }
        if selected.isEmpty { NSStatusBar.system.removeStatusItem(boundary); self.boundary = nil; return }
        // 新規アプリが左端へ追加されても、未選択のものを一緒に収納しない。
        let id = try boundaryID()
        guard let divider = StatusWindows.frame(id) else { throw SwitchFailure(message:"収納境界の位置を確認できません") }
        let unselected = items().filter { !selectedIDs.contains($0.id) && abs($0.frame.midY-divider.midY)<2 && $0.frame.maxX <= divider.minX+1 }
        for icon in unselected.reversed() { try await mover.move(icon,beside:id,left:false) }
        let width = min(10_000,max(500,(NSScreen.screens.map(\.frame.width).max() ?? 1470)*2))
        boundary.length = width
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if selected.keys.allSatisfy({ key in
                guard let f = StatusWindows.frame(key) else { return false }
                return !NSScreen.screens.contains { screen in
                    let h = NSScreen.screens.first?.frame.height ?? 0
                    let bounds = CGRect(x:screen.frame.minX,y:h-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height)
                    return f.intersects(bounds)
                }
            }) { return }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        boundary.length = 8
        throw SwitchFailure(message:"選んだアイコンの画面外への収納を確認できません。取り出せる状態に戻しました。")
    }
    func setHidden(_ icon: MenuIcon,_ hidden: Bool) async throws {
        guard !isBusy else { throw SwitchFailure(message:"アイコンを処理中です") }
        isBusy = true; defer { isBusy = false }
        do { try await change(icon,hidden,persist:true) }
        catch { boundary?.length = 8; throw error }
    }
    private func change(_ icon: MenuIcon,_ hidden: Bool,persist: Bool) async throws {
        if hidden == selectedIDs.contains(icon.id) { return }
        guard icon.protectedReason == nil else { throw SwitchFailure(message:icon.protectedReason!) }
        let live = items()
        guard let current = live.first(where: { $0.id == icon.id && $0.pid == icon.pid }) else { throw SwitchFailure(message:"対象のアイコンが終了しました。一覧を開き直してください。") }
        if hidden {
            let visible = live.filter { !selectedIDs.contains($0.id) }
            guard let index = visible.firstIndex(where: { $0.id == icon.id }) else { throw SwitchFailure(message:"元の並びが見つかりません") }
            positions[icon.id] = RestorePosition(right:Array(visible.dropFirst(index+1).map(\.id)),left:Array(visible.prefix(index).reversed().map(\.id)))
            let id = try await ensureBoundary()
            try await mover.move(current,beside:id,left:true)
            selected[icon.id] = current; insertionOrder.append(icon.id)
            if persist, let key = current.stableKey { var keys = savedKeys; keys.insert(key); savedKeys = keys }
        } else {
            let id = try boundaryID()
            let destination = (positions[icon.id] ?? RestorePosition(right:[],left:[])).destination(available:Set(live.map(\.id)),hidden:selectedIDs.subtracting([icon.id]),boundary:id)
            try await mover.move(current,beside:destination.0,left:destination.1)
            selected.removeValue(forKey:icon.id); positions.removeValue(forKey:icon.id); insertionOrder.removeAll { $0 == icon.id }
            if persist, let key = current.stableKey { var keys = savedKeys; keys.remove(key); savedKeys = keys }
        }
        try await collapse()
    }
    func revealAllTemporarily() async throws {
        guard !isBusy else { return }
        try await expand()
    }
    func rehide() async throws {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await collapse() } catch { boundary?.length = 8; throw error }
    }
    func restoreAll(keepSelection: Bool) async throws {
        guard !isBusy else { throw SwitchFailure(message:"アイコンを処理中です") }
        isBusy = true; defer { isBusy = false }
        let saved = savedKeys
        defer { if keepSelection { savedKeys = saved } }
        for id in insertionOrder.reversed() {
            guard let icon = selected[id] else { continue }
            if StatusWindows.frame(id) == nil { selected.removeValue(forKey:id); continue }
            try await change(icon,false,persist:!keepSelection)
        }
        if let boundary { NSStatusBar.system.removeStatusItem(boundary); self.boundary = nil }
        selected.removeAll(); positions.removeAll(); insertionOrder.removeAll()
    }
    // 自動処理は起動・終了・ディスプレイ変更の通知時だけ。ユーザー操作と直列化する。
    func reconcile() async throws {
        guard !isBusy else { return }
        let live = items(); let available = Set(live.map(\.id))
        for id in Array(selected.keys) where !available.contains(id) { selected.removeValue(forKey:id); positions.removeValue(forKey:id); insertionOrder.removeAll { $0 == id } }
        for icon in live where !selectedIDs.contains(icon.id) && icon.stableKey.map(savedKeys.contains) == true && icon.protectedReason == nil {
            try await setHidden(icon,true)
        }
        if boundary != nil { try await rehide() }
    }
}
