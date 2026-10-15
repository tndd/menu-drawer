import Cocoa

@MainActor final class TypelessTarget: VisibilityTarget {
    static let bundleID = "now.typeless.desktop"
    private let preferenceKey = "NSStatusItem Visible Item-0" as CFString
    private var domain: CFString { Self.bundleID as CFString }
    var application: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first }
    var isRunning: Bool { application != nil }
    var savedVisibility: Bool? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(preferenceKey, domain) as? Bool
    }
    var visibleIconCount: Int {
        guard let application else { return 0 }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter {
            $0[kCGWindowOwnerPID as String] as? pid_t == application.processIdentifier &&
            $0[kCGWindowLayer as String] as? Int == 25
        }.count
    }
    var status: String {
        guard isRunning else { return "Typeless：起動していません" }
        if visibleIconCount > 0 { return "Typelessのアイコン：表示中" }
        if savedVisibility == false { return "Typelessのアイコン：非表示" }
        return "Typelessのアイコン：状態を確認できません"
    }
    func stop() async throws {
        guard let application else { return }
        guard application.terminate() else { throw SwitchFailure(message: "Typelessが終了を受け付けませんでした。音声入力を終了して再試行してください。") }
        let deadline = Date().addingTimeInterval(8)
        // NSWorkspaceの一覧から消えた直後も終了処理が残ることがある。
        // 古いプロセスの設定書き戻しと競合させないよう、実プロセスの終了も待つ。
        let pid = application.processIdentifier
        func alive() -> Bool { kill(pid, 0) == 0 || errno == EPERM }
        while (isRunning || !application.isTerminated || alive()) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        guard !isRunning && application.isTerminated && !alive() else { throw SwitchFailure(message: "Typelessの終了を確認できませんでした。強制終了は行っていません。") }
    }
    func writeVisibility(_ value: Bool?) throws {
        CFPreferencesSetAppValue(preferenceKey, value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }, domain)
        guard CFPreferencesAppSynchronize(domain), savedVisibility == value else { throw SwitchFailure(message: "Typelessの表示設定を保存できませんでした。") }
    }
    func start() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { throw SwitchFailure(message: "Typelessが見つかりません。先にインストールしてください。") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    func verifyVisibility(_ visible: Bool) async throws {
        // 起動途中の「まだアイコンがない」を非表示成功と扱わない。
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let deadline = Date().addingTimeInterval(6)
        var consecutive = 0
        while Date() < deadline {
            if isRunning && savedVisibility == visible && (visibleIconCount > 0) == visible { consecutive += 1 }
            else { consecutive = 0 }
            if consecutive >= 4 { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SwitchFailure(message: "起動後にアイコンの\(visible ? "表示" : "非表示")を確認できませんでした。観測値：起動=\(isRunning)、設定=\(savedVisibility.map(String.init) ?? "未設定")、表示アイコン=\(visibleIconCount)。")
    }
}
