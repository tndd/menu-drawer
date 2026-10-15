import Cocoa

struct AppEntry {
    let id: String
    let name: String
    let url: URL
    let version: String
    let keys: [String]
    var blockReason: String? {
        if id.hasPrefix("com.apple.") { return "システム項目はmacOSの設定で変更してください" }
        if id == Bundle.main.bundleIdentifier { return "MenuDrawer自身は対象外です" }
        if keys.isEmpty { return "対応する表示設定が見つかりません" }
        if keys.count > 1 { return "複数アイコンの対応関係を確認できないため、この方式では非対応です" }
        return nil
    }
    var preferenceKey: String? { blockReason == nil ? keys.first : nil }
    var verificationID: String { [id, version, keys.joined(separator: "|"), ProcessInfo.processInfo.operatingSystemVersionString].joined(separator: "::") }
}

enum AppCatalog {
    static func visibilityKeys(_ keys: [String]) -> [String] {
        let visible = "NSStatusItem Visible "
        let position = "NSStatusItem Preferred Position "
        return Set(keys.compactMap { key -> String? in
            if key.hasPrefix(visible), key.count > visible.count { return key }
            if key.hasPrefix(position), key.count > position.count { return visible + key.dropFirst(position.count) }
            return nil
        }).sorted()
    }
    static func entry(at url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        CFPreferencesAppSynchronize(id as CFString)
        let keys = CFPreferencesCopyKeyList(id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明") + " (" + (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "不明") + ")"
        return AppEntry(id: id, name: name, url: url, version: version, keys: visibilityKeys(keys))
    }
    @MainActor static func discover(added: [String]) -> [AppEntry] {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let owners = Set(windows.filter { $0[kCGWindowLayer as String] as? Int == 25 }.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        let running = NSWorkspace.shared.runningApplications.filter { owners.contains($0.processIdentifier) }.compactMap(\.bundleURL)
        let remembered = added.map { URL(fileURLWithPath: $0) }
        let folders = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let installed = folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "app" }
        let explicit = Set((running + remembered).map(\.path))
        var entries: [String: AppEntry] = [:]
        for url in installed + running + remembered {
            guard let entry = entry(at: url), entry.id != Bundle.main.bundleIdentifier,
                  !entry.id.hasPrefix("com.apple."), explicit.contains(url.path) || !entry.keys.isEmpty else { continue }
            entries[entry.id] = entry
        }
        return entries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
