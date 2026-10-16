import Cocoa
import ApplicationServices

@MainActor final class AppDelegate: NSObject,NSApplicationDelegate {
    private let engine = StorageEngine()
    private var toggle: NSStatusItem?
    private var panel: DrawerWindow!
    private var working = false
    private var terminating = false
    private var notice: String?
    private var observers: [NSObjectProtocol] = []
    private var hideMenuIcon: Bool {
        get { UserDefaults.standard.object(forKey:"hideMenuBarIcon") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue,forKey:"hideMenuBarIcon") }
    }
    private var showSystemItems: Bool {
        get { UserDefaults.standard.bool(forKey:"showSystemItems") }
        set { UserDefaults.standard.set(newValue,forKey:"showSystemItems") }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = DrawerWindow()
        panel.onMove = { [weak self] icon,hidden in self?.move(icon,hidden) }
        panel.onRestore = { [weak self] in self?.restoreAll() }
        panel.onReload = { [weak self] in self?.reload() }
        panel.onQuit = { [weak self] in if self?.working == false { NSApp.terminate(nil) } }
        panel.onPermission = {
            if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        panel.onVisibility = { [weak self] in self?.setMenuIconHidden($0) }
        panel.onSystemItems = { [weak self] show in
            guard let self, !self.working else { return }
            self.showSystemItems = show; self.refresh()
        }
        updateMenuIcon()
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
        refresh(); panel.present()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds:500_000_000)
            await reconcile()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil { refresh(); panel.present() }; return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func showPanel() { refresh(); panel.present() }
    private func updateMenuIcon() {
        engine.controlRequired = !hideMenuIcon
        if hideMenuIcon {
            if let toggle { NSStatusBar.system.removeStatusItem(toggle) }
            toggle = nil
        } else if toggle == nil {
            // 非表示から戻す項目を、収納境界の右側へ配置する。
            UserDefaults.standard.set(0,forKey:"NSStatusItem Preferred Position DrawerToggle")
            let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            item.autosaveName = "DrawerToggle"; item.button?.image = Brand.menuIcon()
            item.button?.setAccessibilityLabel("MenuDrawerを開く")
            item.button?.target = self; item.button?.action = #selector(showPanel)
            toggle = item
        }
    }
    private func setMenuIconHidden(_ hidden: Bool) {
        guard !working else { return }
        hideMenuIcon = hidden; updateMenuIcon()
        run {
            if let number = self.toggle?.button?.window?.windowNumber, number > 0 {
                _ = try await StatusWindows.waitForStableFrame(CGWindowID(number))
            }
            try await self.engine.rehide()
        }
    }
    private func refresh() {
        panel.update(items:engine.items(),selected:engine.selectedIDs,working:working,notice:notice,hideMenuIcon:hideMenuIcon,showSystemItems:showSystemItems,trusted:AXIsProcessTrusted())
        toggle?.button?.toolTip = working ? "アイコンを処理しています…" : "収納中：\(engine.count)個"
    }
    private func move(_ icon: MenuIcon,_ hidden: Bool) {
        run {
            try await self.engine.setHidden(icon,hidden)
            self.notice = nil
        }
    }
    private func restoreAll() { run { try await self.engine.restoreAll(keepSelection:false); self.notice = nil } }
    private func reload() { run { try await self.engine.reconcile(); self.notice = nil } }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true; refresh()
        Task { @MainActor in
            do { try await operation() }
            catch {
                notice = error.localizedDescription
                panel.present()
                let alert = NSAlert(); alert.messageText = "処理を完了できませんでした"
                alert.informativeText = error.localizedDescription + "\n収納を解除し、透明な収納境界を撤去しました。"
                alert.runModal()
            }
            working = false; refresh()
        }
    }
    private func reconcile() async {
        guard AXIsProcessTrusted(), !working, !terminating else { return }
        working = true; refresh()
        do { try await engine.reconcile() }
        catch { notice = error.localizedDescription }
        working = false; refresh()
    }
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
