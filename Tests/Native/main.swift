import Cocoa
import ApplicationServices

@MainActor final class Probe: NSObject,NSApplicationDelegate {
    let engine = StorageEngine()
    var toggle: NSStatusItem!
    var passed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let saved = UserDefaults.standard.object(forKey:"selectedStatusIdentities")
            UserDefaults.standard.removeObject(forKey:"selectedStatusIdentities")
            do { try await check(); passed = true; print("選択収納エンジン：成功") }
            catch { print("選択収納エンジン：失敗：\(error.localizedDescription)") }
            do { try await engine.restoreAll(keepSelection:false) }
            catch { try? await engine.revealAllTemporarily(); passed = false; print("後片付け失敗：\(error.localizedDescription)") }
            UserDefaults.standard.set(saved,forKey:"selectedStatusIdentities")
            if let toggle { NSStatusBar.system.removeStatusItem(toggle) }
            fflush(stdout); exit(passed ? 0 : 1)
        }
    }
    func require(_ ok: Bool,_ message: String) throws { if !ok { throw SwitchFailure(message:message) } }
    func outside(_ id: CGWindowID) -> Bool { StatusWindows.frame(id).map { $0.maxX <= 0 } ?? false }
    func cursor() throws {
        if let r = engine.lastCursor {
            try require(hypot(r.start.x-r.end.x,r.start.y-r.end.y)<1,"カーソルが復元されていません")
            print("カーソル \(r.start)→\(r.end)")
        }
    }
    func check() async throws {
        print("AX許可=\(AXIsProcessTrusted())、画面収録=\(CGPreflightScreenCaptureAccess())")
        guard AXIsProcessTrusted() else { throw SwitchFailure(message:"検証プロセスのアクセシビリティ未許可") }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { throw SwitchFailure(message:"Macがロック中") }
        // 製品と同じく、保存位置を持つ操作ボタンの後から境界が作られる条件を再現する。
        UserDefaults.standard.set(400,forKey:"NSStatusItem Preferred Position RecoveryTestToggle")
        toggle = NSStatusBar.system.statusItem(withLength:24)
        toggle.autosaveName = "RecoveryTestToggle"; toggle.button?.title = "T"
        try await Task.sleep(nanoseconds:100_000_000)
        let fixtures = engine.items().filter { $0.bundleID.hasPrefix("local.codex.MenuDrawerTest.") }
        try require(fixtures.count == 2,"検証アイコンが2個必要です：\(fixtures.count)")
        let a = fixtures[0]; let b = fixtures[1]
        let controlID = CGWindowID(toggle.button!.window!.windowNumber)
        // MenuDrawer自身のボタンの左にある項目を出し入れする条件を作る。
        print("事前配置を開始"); fflush(stdout)
        try await IconMover().move(a,beside:controlID,left:true)
        let initial = engine.items()
        let original = StatusWindows.list().map(\.id)
        func sameOrder() -> Bool { StatusWindows.list().map(\.id).filter { original.contains($0) } == original }
        print("最初の収納を開始"); fflush(stdout)
        try await engine.setHidden(a,true)
        try require(!outside(controlID),"収納と同時に操作ボタンまで画面外へ消えました")
        // メニュー選択後の短いマウス移動を、取り出し前のフレーム安定待ち中に再現する。
        try await Task.sleep(nanoseconds:400_000_000)
        print("入力再開付きの取り出しを開始"); fflush(stdout)
        let movement = Timer(timeInterval:0.08,repeats:false) { _ in
            print("マウス移動を再現"); fflush(stdout)
            if let point = CGEvent(source:nil)?.location {
                CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
            }
        }
        RunLoop.main.add(movement,forMode:.common)
        defer { movement.invalidate() }
        try await engine.setHidden(a,false)
        print("取り出し前の短いマウス移動後も、入力停止を待って復帰")
        try require(sameOrder(),"自身のボタンとアイコンが入れ替わりました")
        print("自身のボタンの左の項目を出し入れしても並びを維持")
        for (icon,hidden) in [(b,true),(a,true),(b,false),(a,false)] {
            print("逆順操作：\(icon.id)を\(hidden ? "収納" : "復帰")"); fflush(stdout)
            do { try await engine.setHidden(icon,hidden) }
            catch { print("失敗時の並び：",StatusWindows.list().map { "\($0.id):\($0.frame.minX),\($0.frame.width)" }.joined(separator:" ")); throw error }
        }
        try require(sameOrder(),"右の項目から収納・取り出しすると並びが変わりました")
        print("収納・取り出しの順番を変えても、自身のボタンを含め元の並びに復帰")
        let pids = Dictionary(uniqueKeysWithValues:fixtures.map { ($0.id,$0.pid) })
        try await engine.setHidden(a,true); try cursor()
        try require(!outside(controlID),"操作ボタンが消えました")
        try require(outside(a.id) && !outside(b.id),"一つだけの選択収納に失敗")
        print("1個目だけ収納、未選択アイコンは表示")
        var surfaced = false
        let monitor = Timer(timeInterval:0.01,repeats:true) { [self] _ in
            MainActor.assumeIsolated { if !outside(a.id) { surfaced = true } }
        }
        RunLoop.main.add(monitor,forMode:.common)
        do {
            try await engine.setHidden(b,true); try cursor()
            try require(!outside(controlID),"追加収納で操作ボタンが消えました")
            try require(outside(a.id) && outside(b.id),"2個の選択収納に失敗")
            try await engine.setHidden(b,false); try cursor()
            try require(outside(a.id) && !outside(b.id),"個別の取り出しに失敗")
        } catch { monitor.invalidate(); throw error }
        monitor.invalidate()
        try require(!surfaced,"別のアイコンの操作中に既存の収納を展開しました")
        print("2個目を収納・取り出し。1個目は操作中も画面外を維持")
        // 新規アプリが左端へ現れても、未選択なら収納側に残さない。
        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("FixtureC.app")
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            let cApp = try await NSWorkspace.shared.openApplication(at:url,configuration:config)
            var c: MenuIcon?
            let until = Date().addingTimeInterval(3)
            while Date() < until {
                c = engine.items().first { $0.pid == cApp.processIdentifier }
                if c != nil { break }; try await Task.sleep(nanoseconds:100_000_000)
            }
            guard let c else { throw SwitchFailure(message:"新規アプリのアイコンなし") }
            try await engine.reconcile(); try cursor()
            try require(!outside(c.id) && outside(a.id),"新規アイコンが選択なしで収納されました")
            print("新規アプリの未選択アイコンを表示、既存の選択収納は維持")
        }
        try await engine.setHidden(a,false); try cursor()
        try await Task.sleep(nanoseconds:100_000_000)
        let final = engine.items().filter { item in initial.contains { $0.id == item.id } }
        try require(final.map(\.id) == initial.map(\.id),"復帰後の並びが元と違います")
        try require(fixtures.allSatisfy { f in final.contains { $0.id == f.id && $0.pid == pids[f.id] } },"アプリが再起動されました")
        try require(engine.count == 0,"選択が残っています")
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        let own = windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == getpid() && $0[kCGWindowLayer as String] as? Int == 25 }
        try require(own.count == 1,"空の収納境界が残っています：\(own.count)")
        print("元の並びに復帰、対象アプリのPIDは不変、収納が空なら区切りウィンドウなし")
        // 入力が止まらない場合は、待機上限で中止してドラッグしないことも確認する。
        let blockedMover = IconMover()
        let beforeInput = StatusWindows.frame(a.id)
        let continuousInput = Timer(timeInterval:0.05,repeats:true) { _ in
            if let point = CGEvent(source:nil)?.location {
                CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
            }
        }
        RunLoop.main.add(continuousInput,forMode:.common); continuousInput.fire()
        defer { continuousInput.invalidate() }
        do {
            try await blockedMover.move(a,beside:b.id,left:true)
            throw SwitchFailure(message:"入力継続中に移動処理が成功扱いになりました")
        } catch let failure as SwitchFailure {
            try require(failure.message == "マウスと修飾キーを離してから再試行してください", "入力継続時の中止理由が違います：\(failure.message)")
        }
        try require(blockedMover.lastCursor == nil && StatusWindows.frame(a.id) == beforeInput,"入力継続中にドラッグを開始しました")
        print("入力が続く場合は待機上限で中止し、ドラッグも位置変更もなし")
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let probe = Probe(); app.delegate = probe
    withExtendedLifetime(probe) { app.run() }
}
