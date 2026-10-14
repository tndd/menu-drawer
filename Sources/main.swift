import Cocoa
import ApplicationServices

final class IconButton: NSButton, NSDraggingSource {
    var invoke: (() -> Void)?
    var takeOut: (() -> Void)?
    private var originPanelFrame: NSRect = .zero
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
    override func mouseDown(with event: NSEvent) {
        let origin = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { performClick(nil); return }
            if hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) >= 5 {
                originPanelFrame = window?.frame ?? .zero
                let pasteboard = NSPasteboardItem()
                pasteboard.setString(toolTip ?? title, forType: .string)
                let item = NSDraggingItem(pasteboardWriter: pasteboard)
                item.setDraggingFrame(NSRect(origin: convert(origin, from: nil), size: NSSize(width: 24, height: 24)), contents: image)
                beginDraggingSession(with: [item], event: next, source: self).animatesToStartingPositionsOnCancelOrFail = false
                return
            }
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        if !originPanelFrame.contains(point) { takeOut?() }
    }
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
    let operations = DispatchQueue(label: "MenuDrawer.NativeItems")
    var isOperating = false { didSet { toggle?.button?.isEnabled = !isOperating } }
    var currentEntries: [MenuEntry] = []
    var returnTimer: Timer?
    var temporary: (entry: MenuEntry, anchor: NativeItems.Anchor)?
    var fixtureWindow: NSWindow?

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
        let restore = NSButton(title: "すべて戻す", target: self, action: #selector(showSetup))
        restore.bezelStyle = .rounded
        restore.controlSize = .small
        restore.setAccessibilityIdentifier("restore-all")
        restore.attributedTitle = NSAttributedString(string: "すべて戻す", attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11)])
        restore.frame = NSRect(x: 210, y: height - 33, width: 82, height: 24)
        root.addSubview(restore)
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
                button.takeOut = { [weak self] in self?.takeOut(entry) }
                button.toolTip = entry.name + " — クリックで開く・一覧の外へドラッグで取り出す"
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
        currentEntries = entries
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

    func returnAnchor(for entry: MenuEntry) -> NativeItems.Anchor? {
        guard let index = currentEntries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let next = currentEntries.dropFirst(index + 1).first?.id ?? divider.button?.window.map { CGWindowID($0.windowNumber) }
        return next.map { NativeItems.Anchor(id: $0, rightSide: false) }
    }

    func activate(_ entry: MenuEntry) { expose(entry, openMenu: true) }
    func takeOut(_ entry: MenuEntry) { expose(entry, openMenu: false) }

    func expose(_ entry: MenuEntry, openMenu: Bool) {
        guard !isOperating, let toggleWindow = toggle.button?.window else { return }
        let anchor = returnAnchor(for: entry)
        let oldTemporary = temporary
        temporary = nil
        returnTimer?.invalidate()
        panel?.orderOut(nil)
        isOperating = true
        let destination = NativeItems.Anchor(id: CGWindowID(toggleWindow.windowNumber), rightSide: true)
        operations.async { [weak self] in
            do {
                if let oldTemporary { try NativeItems.move(oldTemporary.entry, to: oldTemporary.anchor) }
                try NativeItems.move(entry, to: destination)
                let before = NativeItems.visibleWindows(pid: entry.pid)
                if openMenu { try NativeItems.click(entry) }
                var added: [CGWindowID: Int] = [:]
                if openMenu {
                    let deadline = Date().addingTimeInterval(1)
                    repeat {
                        added = NativeItems.visibleWindows(pid: entry.pid).filter { before[$0.key] == nil }
                        if !added.isEmpty || NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
                        Thread.sleep(forTimeInterval: 0.05)
                    } while Date() < deadline
                }
                let menuWindows = Set(added.filter { $0.value > 0 }.keys)
                let opened = !added.isEmpty || NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isOperating = false
                    if openMenu, opened, let anchor {
                        self.temporary = (entry, anchor)
                        self.returnTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                            let visible = Set(NativeItems.visibleWindows(pid: entry.pid).keys)
                            if menuWindows.isDisjoint(with: visible) { self?.putTemporaryBack() }
                        }
                    } else if openMenu {
                        self.showError("「\(entry.name)」はメニューバーへ取り出しました。メニューの表示を確認できなかったため、上の本物のアイコンから操作してください。")
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isOperating = false
                    self?.showSetup()
                    self?.showError("アイコンの移動を確認できなかったため、収納を解除しました。元のメニューバーから操作できます。")
                }
            }
        }
    }

    func putTemporaryBack() {
        guard !isOperating, let temporary else { return }
        self.temporary = nil
        returnTimer?.invalidate()
        isOperating = true
        operations.async { [weak self] in
            let result = Result { try NativeItems.move(temporary.entry, to: temporary.anchor) }
            DispatchQueue.main.async { [weak self] in
                self?.isOperating = false
                if case .failure = result, NativeItems.frame(temporary.entry.id) != nil {
                    self?.showSetup()
                }
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
        returnTimer?.invalidate()
        temporary = nil
        UserDefaults.standard.set(false, forKey: "Configured")
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
            let explanation = NSTextField(wrappingLabelWithString: "1. アクセシビリティだけを許可してください。\nアイコンの名前を読み取り、選んだメニューを開くために使います。画面収録の許可は不要です。\n\n2. ⌘ を押しながら、収納するアイコンを上部の「│」より左へ移動します。「│」はトレイボタンの左に置きます。\n\n3. 「収納を開始」を押します。次からはトレイボタンで開閉できます。一覧の外へドラッグで取り出せます。「すべて戻す」で収納を解除できます。")
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
        operations.sync { } // ドラッグのマウスアップを送り終えてから終了する。
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
        if CommandLine.arguments.contains("--fixture-action") {
            item.button?.target = self
            item.button?.action = #selector(openFixtureWindow)
        } else { item.menu = menu }
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
    @objc func openFixtureWindow() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "検証用アプリ画面"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fixtureWindow = window
    }
    @objc func fixtureClicked() { NSLog("MenuDrawer fixture action") }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
