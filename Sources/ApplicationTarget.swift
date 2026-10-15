import Cocoa

@MainActor final class ApplicationTarget: VisibilityTarget {
    let entry: AppEntry
    init(entry: AppEntry) { self.entry = entry }
    private var preferenceKey: CFString { (entry.preferenceKey ?? "") as CFString }
    private var domain: CFString { entry.id as CFString }
    var application: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: entry.id).first }
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
        guard isRunning else { return "\(entry.name)：起動していません" }
        if visibleIconCount > 0 { return "\(entry.name)のアイコン：表示中" }
        if savedVisibility == false { return "\(entry.name)のアイコン：非表示" }
        return "\(entry.name)のアイコン：状態を確認できません"
    }
    func stop() async throws {
        guard entry.preferenceKey != nil else { throw SwitchFailure(message: entry.blockReason ?? "対象外です") }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: entry.id)
        guard instances.count <= 1 else { throw SwitchFailure(message: "同じアプリが複数起動しているため、対象を特定できません。") }
        guard let application = instances.first else { return }
        guard application.bundleURL?.standardizedFileURL == entry.url.standardizedFileURL else { throw SwitchFailure(message: "選択したアプリとは別の場所の同名アプリが起動しています。一覧を再読み込みしてください。") }
        guard application.terminate() else { throw SwitchFailure(message: "\(entry.name)が終了を受け付けませんでした。作業を保存して再試行してください。") }
        let deadline = Date().addingTimeInterval(8)
        // NSWorkspaceの一覧から消えた直後も終了処理が残ることがある。
        // 古いプロセスの設定書き戻しと競合させないよう、実プロセスの終了も待つ。
        let pid = application.processIdentifier
        func alive() -> Bool { kill(pid, 0) == 0 || errno == EPERM }
        while (isRunning || !application.isTerminated || alive()) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        guard !isRunning && application.isTerminated && !alive() else { throw SwitchFailure(message: "\(entry.name)の終了を確認できませんでした。強制終了は行っていません。") }
    }
    func writeVisibility(_ value: Bool?) throws {
        guard entry.preferenceKey != nil else { throw SwitchFailure(message: entry.blockReason ?? "対象外です") }
        CFPreferencesSetAppValue(preferenceKey, value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }, domain)
        guard CFPreferencesAppSynchronize(domain), savedVisibility == value else { throw SwitchFailure(message: "\(entry.name)の表示設定を保存できませんでした。") }
    }
    func start() async throws {
        guard FileManager.default.fileExists(atPath: entry.url.path) else { throw SwitchFailure(message: "\(entry.name)が見つかりません。先にインストールしてください。") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
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
