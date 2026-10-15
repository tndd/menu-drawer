import Cocoa
import ApplicationServices

@MainActor final class AppDelegate: NSObject,NSApplicationDelegate,NSMenuDelegate {
    private let engine = StorageEngine()
    private var toggle: NSStatusItem!
    private let menu = NSMenu()
    private var working = false
    private var terminating = false
    private var notice: String?
    private var observers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        toggle = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        toggle.autosaveName = "DrawerToggle"
        toggle.button?.image = Brand.menuIcon()
        toggle.button?.setAccessibilityLabel("アイコン収納")
        toggle.button?.toolTip = "隠すアイコンを選ぶ"
        menu.autoenablesItems = false; menu.delegate = self; toggle.menu = menu
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                    await self?.reconcile()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in await self?.reconcile() }
        })
        refresh()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds:500_000_000)
            await reconcile()
        }
    }
    private func info(_ title: String,identifier: String? = nil) {
        let row = NSMenuItem(title:title,action:nil,keyEquivalent:""); row.isEnabled = false
        if let identifier { row.identifier = NSUserInterfaceItemIdentifier(identifier) }
        menu.addItem(row)
    }
    private func command(_ title: String,_ action: Selector) {
        let row = NSMenuItem(title:title,action:action,keyEquivalent:""); row.target = self; row.isEnabled = !working; menu.addItem(row)
    }
    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { refresh() } }
    private func refresh() {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        info(working ? "アイコンを処理しています…" : notice ?? "隠すアイコンを選択（✓は収納中）")
        if !trusted { command("アクセシビリティを許可…",#selector(requestPermission)) }
        info("再起動・画面収録は不要です")
        menu.addItem(.separator())
        let items = engine.items().filter { $0.protectedReason == nil }
        let titles = Dictionary(grouping:items,by: \.title)
        var occurrences: [String:Int] = [:]
        for hidden in [true,false] {
            let group = items.filter { engine.selectedIDs.contains($0.id) == hidden }
            info("\(hidden ? "収納中" : "収納できるアイコン")（\(group.count)）",identifier:hidden ? "section-hidden" : "section-available")
            if group.isEmpty { info(hidden ? "まだ収納していません" : "収納できるアイコンはありません") }
            for icon in group {
                occurrences[icon.title,default:0] += 1
                var title = icon.title
                if (titles[title]?.count ?? 0) > 1 { title += " [\(occurrences[icon.title]!)]" }
                let row = NSMenuItem(title:title,action:#selector(toggleItem(_:)),keyEquivalent:"")
                row.identifier = NSUserInterfaceItemIdentifier("status-\(icon.id)")
                row.target = self; row.representedObject = icon; row.state = hidden ? .on : .off
                row.isEnabled = trusted && !working
                row.toolTip = hidden ? "選ぶと元の並びへ取り出します" : "このアイコンだけを収納します"
                if let url = NSRunningApplication(processIdentifier:icon.pid)?.bundleURL {
                    let image = NSWorkspace.shared.icon(forFile:url.path); image.size = NSSize(width:18,height:18); row.image = image
                }
                menu.addItem(row)
            }
            if hidden { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        command("全て取り出す",#selector(restoreAll))
        command("一覧を再読み込み",#selector(reload))
        command("MenuDrawerを終了",#selector(quitApp))
        toggle.button?.toolTip = working ? "アイコンを処理しています…" : "収納中：\(engine.count)個"
    }
    @objc private func requestPermission() {
        menu.cancelTracking()
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc private func toggleItem(_ sender: NSMenuItem) {
        guard let icon = sender.representedObject as? MenuIcon, !working else { return }
        let hidden = !engine.selectedIDs.contains(icon.id)
        run {
            try await self.engine.setHidden(icon,hidden)
            self.notice = "\(icon.title)：\(hidden ? "収納しました" : "元へ戻しました")"
        }
    }
    @objc private func restoreAll() { run { try await self.engine.restoreAll(keepSelection:false); self.notice = "全て取り出しました" } }
    @objc private func reload() { run { try await self.engine.reconcile(); self.notice = nil } }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        menu.cancelTracking(); working = true; refresh()
        Task { @MainActor in
            do { try await operation() }
            catch {
                notice = error.localizedDescription
                let alert = NSAlert(); alert.messageText = "処理を完了できませんでした"; alert.informativeText = error.localizedDescription + "\n収納を解除し、透明な収納境界を撤去しました。"
                alert.runModal()
            }
            working = false; refresh()
        }
    }
    private func reconcile() async {
        guard AXIsProcessTrusted(), !working, !terminating else { return }
        working = true
        do { try await engine.reconcile() }
        catch { notice = error.localizedDescription }
        working = false; refresh()
    }
    @objc private func quitApp() { if !working { NSApp.terminate(nil) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if working { return .terminateCancel }
        if engine.count == 0 { return .terminateNow }
        terminating = true; working = true
        Task { @MainActor in
            do { try await engine.restoreAll(keepSelection:true) }
            catch {
                try? await engine.revealAllTemporarily()
                let alert = NSAlert(); alert.messageText = "元の並びへの復元を完了できませんでした"; alert.informativeText = error.localizedDescription + "\n収納は解除して終了します。"; alert.runModal()
            }
            NSApp.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
