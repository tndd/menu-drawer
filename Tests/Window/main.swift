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
        let icons = names.enumerated().map { MenuIcon(id:CGWindowID($0.offset+1),pid:getpid(),bundleID:"fixture",name:$0.element,detail:"",frame:.zero,stableKey:nil) } + [
            MenuIcon(id:6,pid:getpid(),bundleID:"com.apple.TextInputMenuAgent",name:"入力メニュー",detail:"",frame:.zero,stableKey:nil),
            MenuIcon(id:7,pid:getpid(),bundleID:"com.apple.controlcenter",name:"音量",detail:"Sound",frame:.zero,stableKey:nil),
            MenuIcon(id:8,pid:getpid(),bundleID:"com.apple.controlcenter",name:"時計",detail:"Clock",frame:CGRect(x:0,y:0,width:150,height:24),stableKey:nil)
        ]
        panel.update(items:icons,selected:[1,2],working:false,notice:nil,hideMenuIcon:true,showSystemItems:false,trusted:true)
        panel.present()
        try await Task.sleep(nanoseconds:200_000_000)
        let root = panel.window!.contentView!
        func button(_ id: String) throws -> NSButton {
            guard let b = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == id }) else { throw SwitchFailure(message:"ボタンがありません："+id) }
            return b
        }
        func table(_ id: String) throws -> NSTableView {
            guard let table = descendants(root).compactMap({ $0 as? NSTableView }).first(where: { $0.accessibilityIdentifier() == id }) else { throw SwitchFailure(message:"一覧がありません："+id) }
            return table
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
            for id in ["reload","restore-all","hide-menubar-icon","show-system-items","quit"] {
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
        try require((try button("show-system-items")).state == .off && (try table("list-available")).numberOfRows == 3,"初期状態でmacOS標準項目が候補から外れていません")
        var systemPreference: Bool?
        panel.onSystemItems = { systemPreference = $0 }
        try button("show-system-items").performClick(nil)
        try require(systemPreference == true,"macOS標準項目の表示をオンにできません")
        panel.update(items:icons,selected:[1,2],working:false,notice:nil,hideMenuIcon:true,showSystemItems:true,trusted:true)
        try await Task.sleep(nanoseconds:100_000_000)
        try require((try table("list-available")).numberOfRows == 5,"オンにしても入力メニュー・音量が候補に出ません、または保護項目まで表示されました")
        panel.window!.display()
        try await Task.sleep(nanoseconds:200_000_000)
        if let captured = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(panel.window!.windowNumber),[.boundsIgnoreFraming,.bestResolution]) {
            try NSBitmapImageRep(cgImage:captured).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"build/tests/window-system-items.png"))
        }
        try button("show-system-items").performClick(nil)
        try require(systemPreference == false,"macOS標準項目の表示をオフにできません")
        panel.update(items:icons,selected:[1,2,6],working:false,notice:nil,hideMenuIcon:true,showSystemItems:false,trusted:true)
        try await Task.sleep(nanoseconds:100_000_000)
        try require((try table("list-available")).numberOfRows == 3 && (try table("list-hidden")).numberOfRows == 3,"オフにすると収納中の標準項目が一覧から消えます")
        try require((try button("status-6")).toolTip?.contains("取り出す") == true,"オフのまま収納中の標準項目を取り出せません")
        try button("status-6").performClick(nil)
        try require(move?.0 == 6 && move?.1 == false,"オフのまま標準項目の取り出し操作を送れません")
        panel.update(items:icons,selected:[1,2],working:false,notice:nil,hideMenuIcon:true,showSystemItems:false,trusted:true)
        try await Task.sleep(nanoseconds:100_000_000)
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
        panel.update(items:icons,selected:[1,2],working:true,notice:nil,hideMenuIcon:true,showSystemItems:false,trusted:true)
        try await Task.sleep(nanoseconds:100_000_000)
        try require(!(try button("status-1")).isEnabled && !(try button("hide-menubar-icon")).isEnabled && !(try button("show-system-items")).isEnabled,"処理中も操作できます")
        panel.window!.setContentSize(NSSize(width:720,height:378))
        panel.update(items:icons,selected:[],working:false,notice:nil,hideMenuIcon:true,showSystemItems:false,trusted:false)
        try await Task.sleep(nanoseconds:100_000_000)
        try layout()
        try require(!(try button("permission")).isHidden && !(try button("status-1")).isEnabled,"未許可時の案内と操作制限がありません")
        panel.window!.close()
        try require(panel.window?.isVisible == false,"画面を閉じられません")
        panel.present()
        try require(panel.window?.isVisible == true,"閉じた画面を再表示できません")
        panel.window!.close()
        print("標準項目の表示切替・収納中の標準項目の取り出し維持、左右同寸法、下部チェック、小さいマークの双方向操作、処理中の操作制限、最小幅・未許可時の表示を確認")
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let delegate = WindowProbe(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
