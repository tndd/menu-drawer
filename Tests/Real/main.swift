import Cocoa
import ApplicationServices

@MainActor final class RealProbe: NSObject,NSApplicationDelegate {
    let engine = StorageEngine()
    var control: NSStatusItem?
    var passed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let saved = UserDefaults.standard.object(forKey:"selectedStatusIdentities")
            UserDefaults.standard.removeObject(forKey:"selectedStatusIdentities")
            do { try await check(); passed = true; print("実アイコンの選択収納：成功") }
            catch { print("実アイコンの選択収納：失敗：\(error.localizedDescription)") }
            do { try await engine.restoreAll(keepSelection:false) }
            catch { try? await engine.revealAllTemporarily(); passed = false; print("復元失敗：\(error.localizedDescription)") }
            UserDefaults.standard.set(saved,forKey:"selectedStatusIdentities")
            if let control { NSStatusBar.system.removeStatusItem(control) }
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
        guard AXIsProcessTrusted() else { throw SwitchFailure(message:"検証プロセスのAX未許可") }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { throw SwitchFailure(message:"Macがロック中") }
        control = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        control?.button?.title = "T"
        if let number = control?.button?.window?.windowNumber { _ = try await StatusWindows.waitForStableFrame(CGWindowID(number)) }
        let initial = engine.items()
        let bundles = ["com.openai.codex","com.apple.TextInputMenuAgent"]
        let targets = bundles.compactMap { bundle in initial.first { $0.bundleID == bundle } }
        try require(targets.count == 2,"起動中のChatGPTと入力メニューのアイコンが必要です")
        let a = targets[0]; let b = targets[1]
        let notSelected = initial.filter { !targets.map(\.id).contains($0.id) }.map(\.id)
        try await engine.setHidden(a,true); try cursor()
        try require(outside(a.id) && !outside(b.id),"最初の選択収納に失敗")
        try await engine.setHidden(b,true); try cursor()
        try require(outside(a.id) && outside(b.id),"複数の選択収納に失敗")
        let during = engine.items().filter { notSelected.contains($0.id) }
        try require(during.map(\.id) == notSelected,"未選択アイコンの並びが変わりました")
        try require(during.allSatisfy { !outside($0.id) },"未選択アイコンまで収納されました")
        print("ChatGPTと入力メニューだけを収納。未選択アイコンは表示と並びを維持")
        try await engine.setHidden(a,false); try cursor()
        try require(!outside(a.id) && outside(b.id),"ChatGPTだけの取り出しに失敗")
        try await engine.restoreAll(keepSelection:false); try cursor()
        try await Task.sleep(nanoseconds:100_000_000)
        let final = engine.items().filter { item in initial.contains { $0.id == item.id } }
        try require(final.map(\.id) == initial.map(\.id),"元の全アイコンの並びに戻っていません")
        try require(targets.allSatisfy { f in final.contains { $0.id == f.id && $0.pid == f.pid } },"対象アプリのPIDが変わりました")
        print("1個ずつ復帰、元の並びと対象アプリのPIDを確認。再起動なし・画面収録なし")
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let probe = RealProbe(); app.delegate = probe
    withExtendedLifetime(probe) { app.run() }
}
