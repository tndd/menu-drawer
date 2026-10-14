import Cocoa
import ApplicationServices

final class IconButton: NSButton {
    var invoke: (() -> Void)?
    init(entry: MenuEntry) {
        super.init(frame: NSRect(x: 0, y: 0, width: 272, height: 44))
        let icon = (entry.image?.copy() as? NSImage) ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        icon?.size = NSSize(width: 24, height: 24)
        image = icon
        imageScaling = .scaleProportionallyDown
        imagePosition = .imageLeft
        title = "  " + entry.name
        alignment = .left
        font = .systemFont(ofSize: 13)
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13)])
        cell?.lineBreakMode = .byTruncatingTail
        bezelStyle = .texturedRounded
        isBordered = false
        toolTip = entry.name
        setAccessibilityLabel(entry.name)
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func activate() { invoke?() }
}

final class DrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var toggle: NSStatusItem!
    var divider: NSStatusItem!
    var panel: DrawerPanel?
    var setup: NSWindow?
    var monitors: [Any] = []
    var isStored = false
    var isPreview = CommandLine.arguments.contains("--preview")
    var timer: Timer?
    var statusLabel: NSTextField?
    var fixtureItems: [NSStatusItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--fixture") { startFixture(); return }
        if isPreview { renderPreview(); return }
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "NSStatusItem Preferred Position DrawerToggle") == nil {
            defaults.set(0, forKey: "NSStatusItem Preferred Position DrawerToggle")
            defaults.set(1, forKey: "NSStatusItem Preferred Position DrawerDivider")
        }
        toggle = NSStatusBar.system.statusItem(withLength: 28)
        toggle.autosaveName = "DrawerToggle"
        toggle.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "収納したアイコン")
        toggle.button?.toolTip = "メニュードロワー（右クリックで設定）"
        toggle.button?.target = self
        toggle.button?.action = #selector(togglePanel)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        divider = NSStatusBar.system.statusItem(withLength: 18)
        divider.autosaveName = "DrawerDivider"
        divider.button?.title = "│"
        divider.button?.toolTip = "この区切りより左のアイコンを収納します"
        divider.button?.target = self
        divider.button?.action = #selector(showSetup)
        if defaults.bool(forKey: "Configured"), AXIsProcessTrusted() {
            storeItems()
        } else { showSetup() }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.panel?.orderOut(nil) }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.panel?.orderOut(nil); return nil }; return event
        }) { monitors.append(monitor) }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc func displayChanged() { panel?.orderOut(nil) }

    func dividerFrame() -> CGRect? {
        guard let window = divider.button?.window else { return nil }
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let row = rows.first(where: { $0[kCGWindowNumber as String] as? Int == window.windowNumber }),
              let bounds = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        guard isStored else { showSetup(); return }
        guard AXIsProcessTrusted() else { restoreItems(); showSetup(); return }
        guard let frame = dividerFrame() else { showError("区切りの位置を取得できませんでした。配置を確認してください。"); return }
        let entries = MenuItems.entries(divider: frame, ownPID: getpid())
        showPanel(entries: entries)
    }

    func panelContent(entries: [MenuEntry]) -> NSView {
        let rows = max(1, entries.count)
        let height: CGFloat = entries.isEmpty ? 112 : CGFloat(min(rows, 8)) * 44 + 48
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 304, height: height))
        root.material = .popover
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        let title = NSTextField(labelWithString: "収納したアイコン")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 16, y: height - 30, width: 180, height: 18)
        root.addSubview(title)
        if entries.isEmpty {
            let label = NSTextField(wrappingLabelWithString: "操作できるアイコンがありません。\n配置設定でアイコンを区切りの左へ移動してください。")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 16, y: 14, width: 272, height: 58)
            root.addSubview(label)
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 12, y: 8, width: 280, height: height - 44))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = rows > 8
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 272, height: CGFloat(rows) * 44))
            for (index, entry) in entries.enumerated() {
                let button = IconButton(entry: entry)
                button.frame.origin = CGPoint(x: 0, y: CGFloat(rows - index - 1) * 44)
                button.invoke = { [weak self] in self?.activate(entry) }
                content.addSubview(button)
            }
            scroll.documentView = content
            content.scroll(NSPoint(x: 0, y: content.bounds.height))
            root.addSubview(scroll)
        }
        return root
    }

    func showPanel(entries: [MenuEntry]) {
        guard let button = toggle.button, let window = button.window else { return }
        let view = panelContent(entries: entries)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main!
        let next = DrawerPanel(contentRect: DrawerGeometry.panel(anchor: anchor, visible: screen.visibleFrame, size: view.frame.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        next.title = "収納したアイコン"
        next.isOpaque = false
        next.backgroundColor = .clear
        next.hasShadow = true
        next.level = .popUpMenu
        next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        next.contentView = view
        next.isReleasedWhenClosed = false
        panel?.orderOut(nil)
        panel = next
        next.orderFrontRegardless()
        next.makeKey()
        if let index = CommandLine.arguments.firstIndex(of: "--validation-output"), CommandLine.arguments.indices.contains(index + 1) {
            writeViewImage(view, to: CommandLine.arguments[index + 1])
        }
    }

    func activate(_ entry: MenuEntry) {
        panel?.orderOut(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MenuItems.press(entry)
            if result != .success {
                DispatchQueue.main.async { self?.showError("「\(entry.name)」のメニューを開けませんでした（\(result.rawValue)）。配置設定から元のアイコンを表示して操作できます。") }
            }
        }
    }

    @objc func storeItems() {
        guard AXIsProcessTrusted() else { showSetup(); return }
        if !isStored, let dividerWindow = divider.button?.window, let toggleWindow = toggle.button?.window,
           dividerWindow.frame.midX >= toggleWindow.frame.midX {
            showError("区切り「│」を、⌘キーを押しながらトレイボタンの左へ移動してください。")
            return
        }
        panel?.orderOut(nil)
        divider.button?.title = ""
        divider.length = max(10000, NSScreen.screens.map { $0.frame.width }.max() ?? 10000)
        isStored = true
        UserDefaults.standard.set(true, forKey: "Configured")
        setup?.orderOut(nil)
        timer?.invalidate()
    }

    func restoreItems() {
        panel?.orderOut(nil)
        divider.length = 18
        divider.button?.title = "│"
        isStored = false
    }

    @objc func showSetup() {
        restoreItems()
        if setup == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "メニュードロワーの設定"
            window.isReleasedWhenClosed = false
            let content = window.contentView!
            let title = NSTextField(labelWithString: "右上をすっきり、アイコンは下へ")
            title.font = .systemFont(ofSize: 20, weight: .semibold)
            title.frame = NSRect(x: 24, y: 292, width: 442, height: 30)
            content.addSubview(title)
            let explanation = NSTextField(wrappingLabelWithString: "1. アクセシビリティだけを許可してください。\nアイコンの名前を読み取り、選んだメニューを開くために使います。画面収録の許可は不要です。\n\n2. ⌘ を押しながら、収納するアイコンを上部の「│」より左へ移動します。「│」はトレイボタンの左に置きます。\n\n3. 「収納を開始」を押します。次からはトレイボタンで開閉できます。右クリックでこの設定を開けます。")
            explanation.font = .systemFont(ofSize: 13)
            explanation.frame = NSRect(x: 24, y: 110, width: 442, height: 174)
            content.addSubview(explanation)
            let status = NSTextField(labelWithString: "")
            status.frame = NSRect(x: 24, y: 76, width: 442, height: 22)
            status.font = .systemFont(ofSize: 12)
            content.addSubview(status)
            statusLabel = status
            for (title, action, x, width) in [("権限を設定", #selector(requestPermissions), 24.0, 120.0), ("収納を開始", #selector(storeItems), 170.0, 136.0), ("終了", #selector(quit), 350.0, 100.0)] {
                let button = NSButton(title: title, target: self, action: action)
                button.bezelStyle = .rounded
                button.frame = NSRect(x: x, y: 25, width: width, height: 32)
                content.addSubview(button)
            }
            window.center()
            setup = window
        }
        updatePermissionStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updatePermissionStatus() }
        setup?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updatePermissionStatus() {
        statusLabel?.stringValue = "アクセシビリティ：\(AXIsProcessTrusted() ? "許可済み" : "未許可")　画面収録は使用しません"
    }
    @objc func requestPermissions() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
    func showContextMenu() {
        let menu = NSMenu()
        for (title, selector) in [("配置・権限の設定…", #selector(showSetup)), ("終了して元に戻す", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let button = toggle.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
    }
    func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "メニュードロワー"
        alert.informativeText = text
        alert.runModal()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if divider != nil { divider.length = 18 }
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    func renderPreview() {
        let entries = [("Safari", "safari"), ("メモ", "note.text"), ("カレンダー", "calendar"), ("ミュージック", "music.note"), ("設定", "gearshape")].enumerated().map { index, item in
            MenuEntry(id: UInt32(index), pid: 0, name: item.0, frame: .zero, image: NSImage(systemSymbolName: item.1, accessibilityDescription: item.0))
        }
        let view = panelContent(entries: entries)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.appearance = NSAppearance(named: .aqua)
        view.display()
        if let destination = CommandLine.arguments.last { writeViewImage(view, to: destination) }
        NSApp.terminate(nil)
    }

    func writeViewImage(_ view: NSView, to destination: String) {
        view.display()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: destination))
            }
        }
    }

    func startFixture() {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(CommandLine.arguments.contains("--fixture-hidden") ? 1 : 10000, forKey: "NSStatusItem Preferred Position FixtureIcon")
        UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position FixtureSpacer")
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.autosaveName = "FixtureIcon"
        item.button?.title = "T"
        let menu = NSMenu()
        let action = NSMenuItem(title: "検証用メニュー", action: #selector(fixtureClicked), keyEquivalent: "")
        action.target = self
        menu.addItem(action)
        item.menu = menu
        fixtureItems.append(item)
        if CommandLine.arguments.contains("--fixture-hidden") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let spacer = NSStatusBar.system.statusItem(withLength: 18)
                spacer.autosaveName = "FixtureSpacer"
                spacer.button?.title = "│"
                self.fixtureItems.append(spacer)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { spacer.length = 10000 }
            }
        }
    }
    @objc func fixtureClicked() { NSLog("MenuDrawer fixture action") }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
