import Cocoa

@MainActor private final class ActionButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, identifier: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame:.zero)
        self.title = title; bezelStyle = .rounded
        setAccessibilityIdentifier(identifier)
        target = self; action = #selector(invokeHandler)
    }
    required init?(coder: NSCoder) { fatalError("未対応") }
    @objc private func invokeHandler() { handler() }
}

@MainActor private final class IconList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    let heading = NSTextField(labelWithString:"")
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString:"")
    private let hidden: Bool
    private var icons: [MenuIcon] = []
    private var enabled = false
    var onMove: (MenuIcon,Bool) -> Void = { _,_ in }
    init(hidden: Bool) {
        self.hidden = hidden
        super.init()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("icon"))
        column.resizingMask = .autoresizingMask; column.width = 330
        table.addTableColumn(column); table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 52; table.intercellSpacing = .zero; table.style = .plain
        table.selectionHighlightStyle = .none; table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.setAccessibilityIdentifier(hidden ? "list-hidden" : "list-available")
        scroll.documentView = table
        heading.font = .systemFont(ofSize:13,weight:.semibold)
        heading.setAccessibilityIdentifier(hidden ? "section-hidden" : "section-available")
        empty.stringValue = hidden ? "まだ収納していません" : "収納できるアイコンはありません"
        empty.font = .systemFont(ofSize:12); empty.textColor = .secondaryLabelColor
        for child in [heading,scroll,empty] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo:view.leadingAnchor), heading.topAnchor.constraint(equalTo:view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo:heading.bottomAnchor,constant:10), scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo:scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo:scroll.centerYAnchor)
        ])
    }
    func update(_ icons: [MenuIcon],enabled: Bool) {
        self.icons = icons; self.enabled = enabled
        heading.stringValue = "\(hidden ? "収納中" : "収納できるアイコン")（\(icons.count)）"
        empty.isHidden = !icons.isEmpty
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { icons.count }
    func tableView(_ tableView: NSTableView,shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let icon = icons[row]
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = NSRunningApplication(processIdentifier:icon.pid)?.icon
        image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString:icon.title)
        cell.textField = label; cell.imageView = image
        label.textColor = .labelColor
        label.font = .systemFont(ofSize:13); label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        label.setContentHuggingPriority(.defaultLow,for:.horizontal)
        label.toolTip = icon.title
        let description = "\(icon.title)を\(hidden ? "取り出す" : "収納する")"
        let shouldHide = !hidden
        let button = ActionButton("",identifier:"status-\(icon.id)") { [weak self] in self?.onMove(icon,shouldHide) }
        button.image = NSImage(systemSymbolName:hidden ? "arrow.left" : "arrow.right",accessibilityDescription:description)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:14,weight:.regular).applying(.init(paletteColors:[.systemBlue])))
        button.isBordered = false
        button.controlSize = .small; button.imagePosition = .imageOnly; button.contentTintColor = .controlAccentColor
        button.setAccessibilityLabel(description); button.toolTip = description
        button.isEnabled = enabled
        let stack = NSStackView(views:hidden ? [button,image,label] : [image,label,button])
        stack.orientation = .horizontal; stack.spacing = 12; stack.alignment = .centerY; stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:12), stack.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-12),
            stack.centerYAnchor.constraint(equalTo:cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant:28), image.heightAnchor.constraint(equalToConstant:28),
            button.widthAnchor.constraint(equalToConstant:24), button.heightAnchor.constraint(equalToConstant:24)
        ])
        return cell
    }
}

@MainActor final class DrawerWindow: NSWindowController {
    var onMove: (MenuIcon,Bool) -> Void = { _,_ in }
    var onRestore: () -> Void = {}
    var onReload: () -> Void = {}
    var onQuit: () -> Void = {}
    var onPermission: () -> Void = {}
    var onVisibility: (Bool) -> Void = { _ in }
    private let hiddenList = IconList(hidden:true)
    private let availableList = IconList(hidden:false)
    private let status = NSTextField(labelWithString:"")
    private var statusRow: NSStackView!
    private var hideIcon: NSButton!
    private var commands: [NSButton] = []
    private var permission: NSButton!
    init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:390),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "MenuDrawer"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width:720,height:370)
        super.init(window:window)
        if !window.setFrameUsingName("DrawerWindow") { window.center() }; window.setFrameAutosaveName("DrawerWindow")
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:22), root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-22),
            root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20), root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16)
        ])
        status.font = .systemFont(ofSize:12); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("operation-status")
        permission = ActionButton("アクセシビリティを許可…",identifier:"permission") { [weak self] in self?.onPermission() }
        statusRow = NSStackView(views:[status,NSView(),permission])
        statusRow.orientation = .horizontal; statusRow.spacing = 8; statusRow.alignment = .centerY
        status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let columns = NSStackView(views:[availableList.view,hiddenList.view])
        columns.orientation = .horizontal; columns.spacing = 24; columns.distribution = .fillEqually; columns.alignment = .top
        root.addArrangedSubview(columns)
        columns.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        hiddenList.view.heightAnchor.constraint(equalTo:columns.heightAnchor).isActive = true
        availableList.view.heightAnchor.constraint(equalTo:columns.heightAnchor).isActive = true
        columns.heightAnchor.constraint(greaterThanOrEqualToConstant:190).isActive = true
        root.addArrangedSubview(statusRow); statusRow.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        hideIcon = ActionButton("メニューバーアイコンを非表示",identifier:"hide-menubar-icon") { [weak self] in
            guard let self else { return }; self.onVisibility(self.hideIcon.state == .on)
        }
        hideIcon.setButtonType(.switch)
        let separator = NSBox(); separator.boxType = .separator
        root.addArrangedSubview(separator); separator.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        let reload = ActionButton("一覧を再読み込み",identifier:"reload") { [weak self] in self?.onReload() }
        let restore = ActionButton("全て取り出す",identifier:"restore-all") { [weak self] in self?.onRestore() }
        let quit = ActionButton("MenuDrawerを終了",identifier:"quit") { [weak self] in self?.onQuit() }
        commands = [reload,restore,quit]
        let spacer = NSView()
        let footer = NSStackView(views:[reload,restore,spacer,hideIcon,quit])
        footer.orientation = .horizontal; footer.spacing = 8; footer.alignment = .centerY
        root.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        hiddenList.onMove = { [weak self] in self?.onMove($0,$1) }
        availableList.onMove = { [weak self] in self?.onMove($0,$1) }
    }
    required init?(coder: NSCoder) { fatalError("未対応") }
    func update(items: [MenuIcon],selected: Set<CGWindowID>,working: Bool,notice: String?,hideMenuIcon: Bool,trusted: Bool) {
        let allowed = items.filter { $0.protectedReason == nil }
        hiddenList.update(allowed.filter { selected.contains($0.id) },enabled:trusted && !working)
        availableList.update(allowed.filter { !selected.contains($0.id) },enabled:trusted && !working)
        hideIcon.state = hideMenuIcon ? .on : .off; hideIcon.isEnabled = !working
        commands.forEach { $0.isEnabled = !working }
        permission.isHidden = trusted; permission.isEnabled = !working
        status.stringValue = working ? "アイコンを処理しています…" : notice ?? ""
        statusRow.isHidden = trusted && !working && notice == nil
    }
    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps:true)
        window?.makeKeyAndOrderFront(nil)
    }
}
