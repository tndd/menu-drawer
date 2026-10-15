import Cocoa

@MainActor final class WindowProbe: NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await check(); print("独立ウィンドウの表示・操作・配置：成功"); exit(0) }
            catch { print("独立ウィンドウの検証失敗：\(error.localizedDescription)"); exit(1) }
        }
    }
    func require(_ ok: Bool,_ message: String) throws { if !ok { throw SwitchFailure(message:message) } }
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { descendants($0) } }
    func check() async throws {
        NSApp.appearance = NSAppearance(named:.aqua)
        UserDefaults.standard.removeObject(forKey:"NSWindow Frame DrawerWindow")
        let panel = DrawerWindow()
        panel.window?.appearance = NSAppearance(named:.aqua)
        let names = ["LinearMouse","英かな","ChatGPT","Dropbox","Raycast"]
        let icons = names.enumerated().map { MenuIcon(id:CGWindowID($0.offset+1),pid:getpid(),bundleID:"fixture",name:$0.element,detail:"",frame:.zero,stableKey:nil) }
        panel.update(items:icons,selected:[1,2],working:false,notice:nil,hideMenuIcon:true,trusted:true)
        panel.present()
        try await Task.sleep(nanoseconds:200_000_000)
        let root = panel.window!.contentView!
        func button(_ id: String) throws -> NSButton {
            guard let b = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == id }) else { throw SwitchFailure(message:"ボタンがありません："+id) }
            return b
        }
        func layout() throws {
            root.layoutSubtreeIfNeeded()
            let scrolls = descendants(root).compactMap { $0 as? NSScrollView }.filter { $0.documentView is NSTableView }
            try require(scrolls.count == 2,"一覧が2個必要です")
            try require(abs(scrolls[0].frame.width-scrolls[1].frame.width)<1 && abs(scrolls[0].frame.height-scrolls[1].frame.height)<1,"左右の一覧の大きさが一致しません")
            let check = try button("hide-menubar-icon"), restore = try button("restore-all")
            let checkRect = check.superview!.convert(check.alignmentRect(forFrame:check.frame),to:root)
            let restoreRect = restore.superview!.convert(restore.alignmentRect(forFrame:restore.frame),to:root)
            try require(checkRect.minX > root.bounds.midX && checkRect.minX > restoreRect.maxX && abs(checkRect.midY-restoreRect.midY)<2,"非表示チェックが右側の操作列にありません：\(checkRect) / \(restoreRect)")
            for id in ["reload","restore-all","hide-menubar-icon","quit"] {
                let b = try button(id), rect = b.convert(b.bounds,to:root)
                try require(root.bounds.contains(rect),"操作が画面外にあります："+id)
            }
        }
        root.layoutSubtreeIfNeeded()
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor(calibratedWhite:0.94,alpha:1).cgColor
        let image = root.bitmapImageRepForCachingDisplay(in:root.bounds)!
        root.cacheDisplay(in:root.bounds,to:image)
        try image.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"build/tests/window-native.png"))
        if let captured = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(panel.window!.windowNumber),[.boundsIgnoreFraming,.bestResolution]) {
            try NSBitmapImageRep(cgImage:captured).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"build/tests/window-screen.png"))
        } else { print("ウィンドウの撮影は利用不可。自アプリの描画画像を視覚検査に使用") }
        try layout()
        var move: (CGWindowID,Bool)?
        panel.onMove = { move = ($0.id,$1) }
        let take = try button("status-1")
        try require(take.alignmentRect(forFrame:take.frame).width <= 24.1 && take.image != nil && take.title.isEmpty && !take.isBordered,"小さい画像ボタンになっていません")
        take.performClick(nil)
        try require(move?.0 == 1 && move?.1 == false,"収納中のマークで取り出せません")
        try button("status-3").performClick(nil)
        try require(move?.0 == 3 && move?.1 == true,"収納可能のマークで収納できません")
        var preference: Bool?
        panel.onVisibility = { preference = $0 }
        try button("hide-menubar-icon").performClick(nil)
        try require(preference == false,"非表示チェックを切り替えられません")
        panel.update(items:icons,selected:[1,2],working:true,notice:nil,hideMenuIcon:true,trusted:true)
        try await Task.sleep(nanoseconds:100_000_000)
        try require(!(try button("status-1")).isEnabled && !(try button("hide-menubar-icon")).isEnabled,"処理中も操作できます")
        panel.window!.setContentSize(NSSize(width:720,height:342))
        panel.update(items:icons,selected:[],working:false,notice:nil,hideMenuIcon:true,trusted:false)
        try await Task.sleep(nanoseconds:100_000_000)
        try layout()
        try require(!(try button("permission")).isHidden && !(try button("status-1")).isEnabled,"未許可時の案内と操作制限がありません")
        panel.window!.close()
        try require(panel.window?.isVisible == false,"画面を閉じられません")
        panel.present()
        try require(panel.window?.isVisible == true,"閉じた画面を再表示できません")
        panel.window!.close()
        print("左右同寸法、下部チェック、小さいマークの双方向操作、処理中の操作制限、最小幅・未許可時の表示を確認")
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let delegate = WindowProbe(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
