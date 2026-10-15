import Cocoa

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var busy = false
    private var notice: String?
    private var added: [String] { UserDefaults.standard.stringArray(forKey: "managedApplicationPaths") ?? [] }
    private var verified: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "verifiedVisibilityOperations") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "verifiedVisibilityOperations") }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: 28)
        item.autosaveName = "DrawerToggle"
        item.button?.image = Brand.menuIcon()
        item.button?.setAccessibilityLabel("アプリのアイコン表示")
        item.button?.toolTip = "アプリごとのメニューバーアイコン表示"
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        refresh()
    }
    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { refresh() } }
    private func info(_ title: String, in menu: NSMenu) {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        menu.addItem(row)
    }
    private func command(_ title: String, action: Selector, in menu: NSMenu, object: Any? = nil) {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self; row.representedObject = object; row.isEnabled = !busy
        menu.addItem(row)
    }
    private func refresh() {
        menu.removeAllItems()
        info(notice ?? "アプリごとのアイコン表示", in: menu)
        info("切り替えには対象アプリの再起動が必要です", in: menu)
        menu.addItem(.separator())
        let entries = AppCatalog.discover(added: added)
        if entries.isEmpty { info("対象を「アプリを追加…」から選んでください", in: menu) }
        for entry in entries {
            let target = ApplicationTarget(entry: entry)
            let checks = Set(verified[entry.verificationID] ?? [])
            let support = entry.blockReason != nil ? "非対応" : checks == Set(["show", "hide"]) ? "表示・非表示確認済み" : checks.isEmpty ? "未検証" : "一部確認済み"
            let row = NSMenuItem(title: "\(entry.name) — \(support)", action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path); icon.size = NSSize(width: 18, height: 18); row.image = icon
            let sub = NSMenu(); sub.autoenablesItems = false
            info(target.status, in: sub)
            info("バージョン \(entry.version)", in: sub)
            if let reason = entry.blockReason { info(reason, in: sub) }
            else {
                info(checks.isEmpty ? "このアプリの動作は未検証です" : "このバージョンで実際に確認した結果です", in: sub)
                info("対象アプリだけを終了して起動し直します", in: sub)
                sub.addItem(.separator())
                command("非表示にする…", action: #selector(hideIcon(_:)), in: sub, object: target)
                command("表示する…", action: #selector(showIcon(_:)), in: sub, object: target)
                sub.addItem(.separator())
                info("別途再起動すると表示が戻る場合があります", in: sub)
            }
            row.submenu = sub; row.isEnabled = !busy; menu.addItem(row)
        }
        menu.addItem(.separator())
        command("アプリを追加…", action: #selector(addApplication), in: menu)
        command("一覧を再読み込み", action: #selector(reload), in: menu)
        command("MenuDrawerを終了", action: #selector(quitApp), in: menu)
    }
    @objc private func reload() { refresh() }
    @objc private func addApplication() {
        guard !busy else { return }
        menu.cancelTracking()
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "管理するアプリを選択してください。追加だけでは設定は変わりません。"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let entry = AppCatalog.entry(at: url) else { return }
        if entry.id.hasPrefix("com.apple.") || entry.id == Bundle.main.bundleIdentifier {
            let alert = NSAlert(); alert.messageText = "このアプリは対象外です"; alert.informativeText = entry.blockReason ?? ""; alert.runModal(); return
        }
        UserDefaults.standard.set(Array(Set(added + [url.path])).sorted(), forKey: "managedApplicationPaths")
        notice = "\(entry.name)を追加しました"; refresh()
    }
    @objc private func hideIcon(_ sender: NSMenuItem) { change(sender, visible: false) }
    @objc private func showIcon(_ sender: NSMenuItem) { change(sender, visible: true) }
    private func change(_ sender: NSMenuItem, visible: Bool) {
        guard !busy, let target = sender.representedObject as? ApplicationTarget else { return }
        menu.cancelTracking()
        let entry = target.entry
        let alert = NSAlert()
        alert.messageText = "\(entry.name)のアイコンを\(visible ? "表示" : "非表示")にしますか？"
        alert.informativeText = "\(entry.name)を終了して起動し直します。作業を保存し、録音や通信などを終えてから実行してください。\n\n変更後に表示状態を確認し、失敗した場合は元の設定へ戻します。"
        alert.addButton(withTitle: "再起動して適用"); alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; notice = "\(entry.name)を切り替えています…"; refresh()
        item.button?.toolTip = notice
        Task { @MainActor in
            do {
                try await VisibilitySwitch.apply(visible: visible, to: target)
                var checks = verified
                checks[entry.verificationID] = Array(Set((checks[entry.verificationID] ?? []) + [visible ? "show" : "hide"]))
                verified = checks
                UserDefaults.standard.set(Array(Set(added + [entry.url.path])).sorted(), forKey: "managedApplicationPaths")
                notice = "\(entry.name)：\(visible ? "表示" : "非表示")を確認しました"
            } catch {
                var checks = verified
                checks[entry.verificationID] = (checks[entry.verificationID] ?? []).filter { $0 != (visible ? "show" : "hide") }
                verified = checks
                notice = "\(entry.name)：切り替えに失敗しました"
                let failure = NSAlert(); failure.messageText = notice!; failure.informativeText = error.localizedDescription; failure.runModal()
            }
            busy = false; item.button?.toolTip = notice; refresh()
        }
    }
    @objc private func quitApp() { if !busy { NSApp.terminate(nil) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { busy ? .terminateCancel : .terminateNow }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
