import Cocoa
import ApplicationServices

final class IconButton: NSButton, NSDraggingSource {
    var invoke: (() -> Void)?
    var takeOut: (() -> Void)?
    private var originPanelFrame: NSRect = .zero
    init(entry: MenuEntry) {
        super.init(frame: NSRect(x: 0, y: 0, width: max(30, entry.frame.width), height: 36))
        image = entry.image
        imageScaling = .scaleNone
        imagePosition = .imageOnly
        title = ""
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

final class SelectionView: NSView {
    override var isFlipped: Bool { true }
}

final class DrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var toggle: NSStatusItem!
    var divider: NSStatusItem?
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
    var selectedKeys = Set(UserDefaults.standard.stringArray(forKey: "SelectedItems") ?? [])
    var draftKeys: Set<String> = []
    var selectionList: NSScrollView?
    var selectionButtons: [NSButton] = []
    var saveButton: NSButton?
    var selectionSnapshot: [String] = []
    var homeOrder = UserDefaults.standard.stringArray(forKey: "HomeOrder") ?? []
    var imageCache: [String: NSImage] = [:]
    var panelTimer: Timer?
    let cover = BarCover()


    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--fixture") { startFixture(); return }
        if isPreview { renderPreview(); return }
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "NSStatusItem Preferred Position DrawerToggle") == nil {
            defaults.set(0, forKey: "NSStatusItem Preferred Position DrawerToggle")
            defaults.set(1, forKey: "NSStatusItem Preferred Position DrawerDivider")
        }
        defaults.set(100000, forKey: "NSStatusItem Preferred Position DrawerDivider")
        toggle = NSStatusBar.system.statusItem(withLength: 28)
        toggle.autosaveName = "DrawerToggle"
        toggle.button?.image = Brand.menuIcon()
        toggle.button?.setAccessibilityLabel("収納したアイコン")
        toggle.button?.toolTip = "メニュードロワー（右クリックで設定）"
        toggle.button?.target = self
        toggle.button?.action = #selector(togglePanel)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if !selectedKeys.isEmpty, AXIsProcessTrusted(), StatusImages.permitted {
            draftKeys = selectedKeys
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.storeItems() }
        } else { showSetup() }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.panel?.orderOut(nil) }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.panel?.orderOut(nil); return nil }; return event
        }) { monitors.append(monitor) }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc func displayChanged() { panel?.orderOut(nil) }

    func dividerFrame() -> CGRect? {
        guard let window = (divider ?? toggle)?.button?.window else { return nil }
        return NativeItems.frame(CGWindowID(window.windowNumber))
    }

    func inventory() -> [MenuEntry] {
        guard let frame = dividerFrame() else { return [] }
        return MenuItems.all(menuY: frame.midY, ownPID: getpid())
    }

    func ensureDivider() {
        guard divider == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = "DrawerDivider"
        item.button?.title = ""
        item.button?.isEnabled = false
        item.button?.setAccessibilityElement(false)
        divider = item
    }

    func removeDivider() {
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        divider = nil
        isStored = false
    }

    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp { showSetup(); return }
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        guard isStored else { showSetup(); return }
        guard AXIsProcessTrusted(), StatusImages.permitted else { showSetup(); return }
        var entries = inventory().filter { selectedKeys.contains($0.selectionKey) }
        for index in entries.indices {
            if let image = StatusImages.image(for: entries[index]) { imageCache[entries[index].selectionKey] = image }
            entries[index].image = imageCache[entries[index].selectionKey]
        }
        showPanel(entries: entries)
    }

    func panelContent(entries: [MenuEntry]) -> NSView {
        let widths = entries.map { max(30, $0.image?.size.width ?? $0.frame.width) }
        let width: CGFloat = entries.isEmpty ? 200 : widths.reduce(0, +) + 20
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: entries.isEmpty ? 68 : 48))
        root.material = .popover
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        if entries.isEmpty {
            let label = NSTextField(labelWithString: "収納した項目がありません")
            label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: 10, y: 24, width: width - 20, height: 22)
            root.addSubview(label)
        } else {
            var x: CGFloat = 10
            for (index, entry) in entries.enumerated() {
                let button = IconButton(entry: entry)
                button.frame = NSRect(x: x, y: 6, width: widths[index], height: 36)
                button.identifier = NSUserInterfaceItemIdentifier(entry.selectionKey)
                button.setAccessibilityIdentifier("status-image:" + entry.selectionKey)
                if entry.image == nil {
                    button.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
                    button.toolTip = entry.name + " — 画像を取得できません。画面収録の権限を確認してください"
                } else { button.toolTip = entry.name + " — クリックで操作・外へドラッグで取り出す" }
                button.invoke = { [weak self] in self?.activate(entry) }
                button.takeOut = { [weak self] in self?.takeOut(entry) }
                root.addSubview(button)
                x += widths[index]
            }
        }
        return root
    }

    func showPanel(entries: [MenuEntry]) {
        guard let button = toggle.button, let window = button.window else { return }
        currentEntries = entries
        let view = panelContent(entries: entries)
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let anchor = CGRect(x: buttonFrame.minX, y: window.frame.minY, width: buttonFrame.width, height: window.frame.height)
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
        panelTimer?.invalidate()
        panelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.panel?.isVisible == true, !self.isOperating else { timer.invalidate(); return }
            for entry in self.inventory() where self.selectedKeys.contains(entry.selectionKey) {
                guard let image = StatusImages.image(for: entry), let button = self.panel?.contentView?.subviews.compactMap({ $0 as? IconButton }).first(where: { $0.identifier?.rawValue == entry.selectionKey }) else { continue }
                self.imageCache[entry.selectionKey] = image
                button.image = image
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--validation-output"), CommandLine.arguments.indices.contains(index + 1) {
            let destination = CommandLine.arguments[index + 1]
            writeViewImage(view, to: destination)
            let area = screen.auxiliaryTopRightArea ?? CGRect(x: screen.frame.midX, y: screen.frame.maxY - 37, width: screen.frame.width / 2, height: 37)
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            let bounds = CGDisplayBounds(displayID)
            let region = CGRect(x: bounds.minX + area.minX - screen.frame.minX, y: bounds.minY, width: area.width, height: 37 + view.frame.height + 12)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard next.isVisible else { return }
                if let image = MDBarImage(region) { StatusImages.validationImage(image, suffix: ".bar.png") }
                let detail = CGRect(x: bounds.minX + next.frame.minX - screen.frame.minX - 8, y: bounds.minY, width: next.frame.width + 16, height: region.height)
                if let image = MDBarImage(detail) { StatusImages.validationImage(image, suffix: ".dropdown.png") }
            }
        }
    }

    func returnAnchor(for entry: MenuEntry) -> NativeItems.Anchor? {
        guard let index = currentEntries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let next = currentEntries.dropFirst(index + 1).first?.id ?? divider?.button?.window.map { CGWindowID($0.windowNumber) }
        return next.map { NativeItems.Anchor(id: $0, rightSide: false) }
    }

    func activate(_ entry: MenuEntry) { expose(entry) }
    func takeOut(_ entry: MenuEntry) {
        draftKeys = selectedKeys.subtracting([entry.selectionKey])
        storeItems()
    }

    func expose(_ entry: MenuEntry) {
        guard !isOperating, let toggleWindow = toggle.button?.window, let anchor = returnAnchor(for: entry) else { return }
        let oldTemporary = temporary
        temporary = nil
        returnTimer?.invalidate()
        panel?.orderOut(nil)
        isOperating = true
        cover.show(on: toggleWindow.screen ?? NSScreen.main!)
        let destination = NativeItems.Anchor(id: CGWindowID(toggleWindow.windowNumber), rightSide: false)
        operations.async { [weak self] in
            do {
                if let oldTemporary { try NativeItems.move(oldTemporary.entry, to: oldTemporary.anchor) }
                try NativeItems.move(entry, to: destination)
                let before = NativeItems.visibleWindows(pid: entry.pid)
                try NativeItems.click(entry)
                var added: [CGWindowID: Int] = [:]
                let deadline = Date().addingTimeInterval(0.8)
                repeat {
                    added = NativeItems.visibleWindows(pid: entry.pid).filter { before[$0.key] == nil }
                    if !added.isEmpty { break }
                    Thread.sleep(forTimeInterval: 0.05)
                } while Date() < deadline
                let menuWindows = Set(added.filter { $0.value > 0 }.keys)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isOperating = false
                    self.temporary = (entry, anchor)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.cover.recordVisibleState() }
                    self.returnTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                        let visible = Set(NativeItems.visibleWindows(pid: entry.pid).keys)
                        if menuWindows.isDisjoint(with: visible) { self?.putTemporaryBack() }
                    }
                }
            } catch {
                // 一時表示の失敗でも元の収納位置への復帰を試み、固定画像を必ず撤去する。
                try? NativeItems.move(entry, to: anchor)
                DispatchQueue.main.async { [weak self] in
                    self?.isOperating = false
                    self?.cover.hide()
                    self?.showError("「\(entry.name)」を操作できませんでした。設定からこの項目を取り出して再試行してください。")
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
                self?.cover.hide()
                if case .failure = result, NativeItems.frame(temporary.entry.id) != nil {
                    self?.showError("このアイコンを収納へ戻せませんでした。設定からこの項目を取り出してください。")
                }
            }
        }
    }

    // 元の隣接関係を記録し、選択解除時は生きている最寄りの項目へ戻す。
    func recordHomeOrder(_ entries: [MenuEntry]) {
        if selectedKeys.isEmpty || homeOrder.isEmpty { homeOrder = entries.map(\.selectionKey) }
        else {
            for (index, entry) in entries.enumerated() where !homeOrder.contains(entry.selectionKey) {
                let next = entries.dropFirst(index + 1).first { homeOrder.contains($0.selectionKey) }
                let position = next.flatMap { homeOrder.firstIndex(of: $0.selectionKey) } ?? homeOrder.count
                homeOrder.insert(entry.selectionKey, at: position)
            }
        }
        UserDefaults.standard.set(homeOrder, forKey: "HomeOrder")
    }

    func homeAnchor(_ entry: MenuEntry, entries: [MenuEntry], remaining: Set<String>, toggleID: CGWindowID) -> NativeItems.Anchor {
        let index = homeOrder.firstIndex(of: entry.selectionKey) ?? 0
        let byKey = Dictionary(entries.map { ($0.selectionKey, $0) }, uniquingKeysWith: { first, _ in first })
        for key in homeOrder.dropFirst(index + 1) where !remaining.contains(key) {
            if let neighbor = byKey[key], NativeItems.frame(neighbor.id) != nil { return NativeItems.Anchor(id: neighbor.id, rightSide: false) }
        }
        for key in homeOrder.prefix(index).reversed() where !remaining.contains(key) {
            if let neighbor = byKey[key], NativeItems.frame(neighbor.id) != nil { return NativeItems.Anchor(id: neighbor.id, rightSide: true) }
        }
        return NativeItems.Anchor(id: toggleID, rightSide: false)
    }

    @objc func storeItems() {
        guard AXIsProcessTrusted(), !isOperating, let toggleWindow = toggle.button?.window else { showSetup(); return }
        let entries = inventory()
        recordHomeOrder(entries)
        let desired = draftKeys
        guard StatusImages.permitted || desired.isSubset(of: selectedKeys) else { showSetup(); return }
        let chosen = entries.filter { desired.contains($0.selectionKey) && $0.canStore }.sorted {
            (homeOrder.firstIndex(of: $0.selectionKey) ?? Int.max) < (homeOrder.firstIndex(of: $1.selectionKey) ?? Int.max)
        }
        let removed = entries.filter { selectedKeys.contains($0.selectionKey) && !desired.contains($0.selectionKey) }
        for entry in chosen {
            if let image = StatusImages.image(for: entry) { imageCache[entry.selectionKey] = image }
        }
        let oldTemporary = temporary
        temporary = nil
        returnTimer?.invalidate()
        panel?.orderOut(nil)
        cover.show(on: toggleWindow.screen ?? NSScreen.main!)
        if !chosen.isEmpty { ensureDivider() }
        let boundary = divider?.button?.window.map { NativeItems.Anchor(id: CGWindowID($0.windowNumber), rightSide: false) }
        let toggleID = CGWindowID(toggleWindow.windowNumber)
        isOperating = true
        saveButton?.isEnabled = false
        selectionButtons.forEach { $0.isEnabled = false }
        operations.async { [weak self] in
            guard let self else { return }
            do {
                if let oldTemporary { try NativeItems.move(oldTemporary.entry, to: oldTemporary.anchor) }
                for entry in removed.reversed() {
                    try NativeItems.move(entry, to: self.homeAnchor(entry, entries: entries, remaining: desired, toggleID: toggleID))
                }
                if let boundary {
                    var next = boundary
                    for entry in chosen.reversed() {
                        if let item = NativeItems.frame(entry.id), let current = NativeItems.frame(next.id), abs(item.maxX - current.minX) > 1 {
                            try NativeItems.move(entry, to: next)
                        }
                        next = NativeItems.Anchor(id: entry.id, rightSide: false)
                    }
                }
                DispatchQueue.main.async {
                    self.selectedKeys = desired
                    UserDefaults.standard.set(Array(desired), forKey: "SelectedItems")
                    if chosen.isEmpty { self.removeDivider() }
                    else { self.divider?.length = 10000; self.isStored = true }
                    self.isOperating = false
                    self.saveButton?.isEnabled = true
                    self.selectionSnapshot = []
                    self.cover.hide()
                    self.setup?.orderOut(nil)
                    self.timer?.invalidate()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isOperating = false
                    self.saveButton?.isEnabled = true
                    self.selectionSnapshot = []
                    self.refreshSelectionList()
                    self.cover.hide()
                    self.showError("選択したアイコンの移動に失敗しました。設定から該当項目を取り出して再試行してください。")
                }
            }
        }
    }

    @objc func restoreAll() {
        draftKeys = []
        storeItems()
    }

    @objc func selectionChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let key = raw.hasPrefix("select:") ? String(raw.dropFirst(7)) : raw
        if sender.state == .on { draftKeys.insert(key) } else { draftKeys.remove(key) }
        updatePermissionStatus()
    }

    func refreshSelectionList() {
        guard let frame = dividerFrame(), let scroll = selectionList else { return }
        var entries = AXIsProcessTrusted() ? MenuItems.all(menuY: frame.midY, ownPID: getpid()) : []
        let liveKeys = Set(entries.map(\.selectionKey))
        for key in selectedKeys.subtracting(liveKeys).sorted() {
            entries.append(MenuEntry(id: 0, pid: 0, name: "停止中：" + key.components(separatedBy: "#")[0], frame: .zero, image: nil, selectionKey: key))
        }
        let snapshot = entries.map { $0.selectionKey + $0.name }
        if snapshot == selectionSnapshot && !selectionButtons.isEmpty { return }
        selectionSnapshot = snapshot
        selectionButtons = []
        let content = SelectionView(frame: NSRect(x: 0, y: 0, width: 416, height: CGFloat(max(1, entries.count)) * 38))
        for (index, entry) in entries.enumerated() {
            let button = NSButton(checkboxWithTitle: entry.name, target: self, action: #selector(selectionChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(entry.selectionKey)
            button.setAccessibilityIdentifier("select:" + entry.selectionKey)
            button.state = draftKeys.contains(entry.selectionKey) ? .on : .off
            button.isEnabled = entry.canStore
            button.toolTip = entry.canStore ? "チェックした項目だけを収納します" : "macOSの固定項目はそのまま表示します"
            button.frame = NSRect(x: 8, y: CGFloat(index) * 38 + 7, width: 400, height: 26)
            content.addSubview(button)
            selectionButtons.append(button)
        }
        if entries.isEmpty {
            let label = NSTextField(wrappingLabelWithString: "アクセシビリティを許可すると、選べるアイコンが表示されます。")
            label.frame = NSRect(x: 8, y: 0, width: 400, height: 38)
            content.addSubview(label)
        }
        scroll.documentView = content
        content.scroll(.zero)
        if let index = CommandLine.arguments.firstIndex(of: "--validation-output"), CommandLine.arguments.indices.contains(index + 1), let view = setup?.contentView {
            writeViewImage(view, to: CommandLine.arguments[index + 1] + ".settings.png")
        }
    }

    @objc func showSetup() {
        guard !isOperating else { return }
        panel?.orderOut(nil)
        draftKeys = selectedKeys
        selectionSnapshot = []
        if setup == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "メニュードロワーの設定"
            window.isReleasedWhenClosed = false
            let content = window.contentView!
            let title = NSTextField(labelWithString: "しまうアイコンを選ぶ")
            title.font = .systemFont(ofSize: 20, weight: .semibold)
            title.frame = NSRect(x: 24, y: 447, width: 442, height: 30)
            content.addSubview(title)
            let explanation = NSTextField(wrappingLabelWithString: "チェックした項目だけを収納します。\nほかのアイコンは上に残ります。選択は次回の起動にも保存されます。")
            explanation.font = .systemFont(ofSize: 13)
            explanation.frame = NSRect(x: 24, y: 394, width: 442, height: 44)
            content.addSubview(explanation)
            let scroll = NSScrollView(frame: NSRect(x: 24, y: 108, width: 442, height: 276))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            content.addSubview(scroll)
            selectionList = scroll
            let status = NSTextField(labelWithString: "")
            status.frame = NSRect(x: 24, y: 76, width: 442, height: 22)
            status.font = .systemFont(ofSize: 12)
            content.addSubview(status)
            statusLabel = status
            for (title, action, x, width) in [("権限を設定", #selector(requestPermissions), 24.0, 120.0), ("選択を保存", #selector(storeItems), 170.0, 136.0), ("終了", #selector(quit), 350.0, 100.0)] {
                let button = NSButton(title: title, target: self, action: action)
                button.bezelStyle = .rounded
                button.frame = NSRect(x: x, y: 25, width: width, height: 32)
                content.addSubview(button)
                if title == "選択を保存" { saveButton = button }
            }
            let restore = NSButton(title: "すべて戻す", target: self, action: #selector(restoreAll))
            restore.bezelStyle = .rounded
            restore.controlSize = .small
            restore.frame = NSRect(x: 342, y: 444, width: 120, height: 28)
            restore.setAccessibilityIdentifier("restore-all")
            content.addSubview(restore)
            window.center()
            setup = window
        }
        refreshSelectionList()
        DispatchQueue.main.async { [weak self] in self?.refreshSelectionList() }
        updatePermissionStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updatePermissionStatus() }
        setup?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updatePermissionStatus() {
        saveButton?.isEnabled = AXIsProcessTrusted() && (StatusImages.permitted || draftKeys.isSubset(of: selectedKeys)) && !isOperating
        if AXIsProcessTrusted() && !isOperating { refreshSelectionList() }
        statusLabel?.stringValue = "アクセシビリティ：\(AXIsProcessTrusted() ? "許可済み" : "未許可")　画面収録：\(StatusImages.permitted ? "許可済み" : "未許可")"
    }
    @objc func requestPermissions() {
        if !StatusImages.permitted { StatusImages.request() }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
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
        let entries = inventory()
        if let toggleWindow = toggle?.button?.window {
            cover.show(on: toggleWindow.screen ?? NSScreen.main!)
            operations.sync {
                for entry in entries.reversed() where selectedKeys.contains(entry.selectionKey) {
                    try? NativeItems.move(entry, to: homeAnchor(entry, entries: entries, remaining: [], toggleID: CGWindowID(toggleWindow.windowNumber)))
                }
            }
        }
        removeDivider()
        cover.hide()
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
        UserDefaults.standard.set(10000, forKey: "NSStatusItem Preferred Position FixtureIcon")
        UserDefaults.standard.set(100000, forKey: "NSStatusItem Preferred Position FixtureSpacer")
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
                self.operations.async {
                    guard let window = item.button?.window, let boundary = spacer.button?.window,
                          let frame = NativeItems.frame(CGWindowID(window.windowNumber)) else { return }
                    let entry = MenuEntry(id: CGWindowID(window.windowNumber), pid: getpid(), name: "T", frame: frame, image: nil)
                    do {
                        try NativeItems.move(entry, to: NativeItems.Anchor(id: CGWindowID(boundary.windowNumber), rightSide: false))
                        DispatchQueue.main.async { spacer.length = 10000 }
                    } catch { NSLog("検証用の収納を開始できませんでした") }
                }
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
