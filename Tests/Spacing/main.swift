import Cocoa
import ApplicationServices

@MainActor final class SpacingProbe: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var report: String
            do { report = "成功\n" + (try await check()) }
            catch { report = "失敗：" + error.localizedDescription }
            try? report.write(toFile:CommandLine.arguments[1],atomically:true,encoding:.utf8)
            exit(report.hasPrefix("成功") ? 0 : 1)
        }
    }
    func require(_ ok: Bool,_ message: String) throws {
        if !ok { throw SwitchFailure(message:message) }
    }
    func check() async throws -> String {
        // 許可のない独立アプリから呼び、移動イベントを生成する前の失敗だけを検証する。
        guard !AXIsProcessTrusted() else { throw SwitchFailure(message:"AX許可を継承したため、移動せず中止しました") }
        let item = NSStatusBar.system.statusItem(withLength:28)
        item.button?.image = Brand.menuIcon()
        defer { NSStatusBar.system.removeStatusItem(item) }
        guard let number = item.button?.window?.windowNumber, number > 0 else { throw SwitchFailure(message:"検証項目がありません") }
        let id = CGWindowID(number)
        let old = try await StatusWindows.waitForStableFrame(id)
        item.length = NSStatusItem.variableLength
        let standard = try await StatusWindows.waitForStableFrame(id)
        try require(standard.width < old.width,"標準幅へ縮まりませんでした")
        guard let target = StatusWindows.list().first(where:{ $0.bundleID == CommandLine.arguments[2] }) else { throw SwitchFailure(message:"専用の検証アイコンがありません") }
        let before = try await StatusWindows.waitForStableFrame(target.id)
        let engine = StorageEngine()
        do {
            try await engine.setHidden(target,true)
            throw SwitchFailure(message:"未許可なのに収納処理が成功しました")
        } catch {
            try require(error.localizedDescription.contains("アクセシビリティ"),"想定外の失敗：" + error.localizedDescription)
        }
        try await Task.sleep(nanoseconds:200_000_000)
        try require(engine.count == 0,"収納状態が残りました")
        try require((UserDefaults.standard.stringArray(forKey:"selectedStatusIdentities") ?? []).isEmpty,"再収納する選択が残りました")
        try require(StatusWindows.list().filter { $0.pid == getpid() }.map(\.id) == [id],"透明な収納境界が残りました")
        try require(StatusWindows.frame(target.id) == before,"検証アイコンを動かしてしまいました")
        NSStatusBar.system.removeStatusItem(item)
        try await Task.sleep(nanoseconds:200_000_000)
        try require(!StatusWindows.list().contains { $0.pid == getpid() },"撤去後の空白領域が残りました")
        return "表示幅：\(old.width) → \(standard.width)ポイント\n失敗時の透明境界・収納状態・再収納設定：残存なし\n撤去後の自アプリ領域：0\n検証対象の位置：不変。移動イベントは未実行\n"
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let delegate = SpacingProbe(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
