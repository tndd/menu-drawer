import Cocoa

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let target = TypelessTarget()
    private let menu = NSMenu()
    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var hideItem: NSMenuItem!
    private var showItem: NSMenuItem!
    private var busy = false
    private var notice: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: 28)
        item.autosaveName = "DrawerToggle"
        item.button?.image = Brand.menuIcon()
        item.button?.setAccessibilityLabel("Typelessのアイコン表示")
        item.button?.toolTip = "Typelessのメニューバーアイコンを切り替える"
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        let explanation = NSMenuItem(title: "切り替え時はTypelessを再起動します", action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        menu.addItem(explanation)
        menu.addItem(.separator())
        hideItem = NSMenuItem(title: "非表示にする", action: #selector(hideIcon), keyEquivalent: "")
        showItem = NSMenuItem(title: "表示する", action: #selector(showIcon), keyEquivalent: "")
        for action in [hideItem!, showItem!] { action.target = self; menu.addItem(action) }
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Typelessを別途再起動すると表示が戻る場合があります", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        let quit = NSMenuItem(title: "MenuDrawerを終了", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        refresh()
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    private func refresh() {
        statusItem.title = busy ? "Typelessを切り替えています…" : target.status
        hideItem.isEnabled = !busy
        showItem.isEnabled = !busy
        hideItem.title = target.isRunning ? "非表示にして再起動" : "非表示にして起動"
        showItem.title = target.isRunning ? "表示して再起動" : "表示して起動"
        hideItem.state = !busy && target.isRunning && target.savedVisibility == false && target.visibleIconCount == 0 ? .on : .off
        showItem.state = !busy && target.visibleIconCount > 0 ? .on : .off
        menu.items.last?.isEnabled = !busy
        item.button?.toolTip = busy ? "Typelessを切り替えています…" : (notice ?? target.status)
    }
    @objc private func hideIcon() { change(visible: false) }
    @objc private func showIcon() { change(visible: true) }
    private func change(visible: Bool) {
        guard !busy else { return }
        menu.cancelTracking()
        busy = true; notice = nil; refresh()
        Task { @MainActor in
            do {
                try await VisibilitySwitch.apply(visible: visible, to: target)
                notice = "Typelessのアイコンを\(visible ? "表示" : "非表示")にしました"
            } catch {
                let alert = NSAlert()
                alert.messageText = "Typelessを切り替えられませんでした"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            busy = false; refresh()
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
