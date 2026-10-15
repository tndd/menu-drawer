import Cocoa
import ApplicationServices

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func find(_ root: AXUIElement, depth: Int = 0, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    guard depth < 14 else { return nil }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let match = find(child, depth: depth + 1, predicate) { return match }
    }
    return nil
}
func label(_ e: AXUIElement) -> String { [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(e, $0) as? String }.joined(separator: " ") }
@main struct LiveTests {
    @MainActor static func main() async {
        do { try await run() } catch { print("実メニュー検証失敗：\(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { throw SwitchFailure(message: "Macがロック中です") }
        guard CommandLine.arguments.count == 3 else { throw SwitchFailure(message: "検証用アプリ2個が必要です") }
        let paths = Array(CommandLine.arguments.dropFirst())
        guard paths.allSatisfy({ $0.contains("/build/tests/fixtures.") }) else { throw SwitchFailure(message: "検証用以外のアプリは操作できません") }
        let entries = paths.compactMap { AppCatalog.entry(at: URL(fileURLWithPath: $0)) }
        guard entries.count == 2, entries.allSatisfy({ $0.id.hasPrefix("local.codex.MenuDrawerTest.") }) else { throw SwitchFailure(message: "検証対象が一致しません") }
        let targets = entries.map { ApplicationTarget(entry: $0) }
        let domain = "local.codex.MenuDrawer" as CFString
        let savedKeys = ["managedApplicationPaths", "verifiedVisibilityOperations"]
        let savedValues = savedKeys.map { CFPreferencesCopyAppValue($0 as CFString, domain) }
        let cursor = CGEvent(source: nil)!.location
        guard let drawer = NSRunningApplication.runningApplications(withBundleIdentifier: domain as String).first else { throw SwitchFailure(message: "MenuDrawer未起動") }
        let app = AXUIElementCreateApplication(drawer.processIdentifier)
        guard let raw = attribute(app, kAXExtrasMenuBarAttribute) else { throw SwitchFailure(message: "操作ボタンなし") }
        let bar = unsafeBitCast(raw, to: AXUIElement.self)
        guard let toggle = find(bar, { label($0).contains("アプリのアイコン表示") }) else { throw SwitchFailure(message: "新しいアプリではありません") }
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetMessagingTimeout(toggle, 0.3)
        func wait(_ description: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SwitchFailure(message: description)
        }
        func openMenu() async throws {
            _ = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
            try await wait("一覧が開きません") { find(bar) { label($0).contains("アプリを追加…") } != nil }
        }
        func closeMenu() {
            if let menu = find(bar, { attribute($0,kAXRoleAttribute) as? String == kAXMenuRole }) { _ = AXUIElementPerformAction(menu,kAXCancelAction as CFString) }
        }
        func clean() async throws {
            closeMenu()
            for target in targets { try await target.stop() }
            for (key,value) in zip(savedKeys,savedValues) { CFPreferencesSetAppValue(key as CFString, value, domain) }
            CFPreferencesAppSynchronize(domain)
            for entry in entries {
                if let keys = CFPreferencesCopyKeyList(entry.id as CFString,kCFPreferencesCurrentUser,kCFPreferencesAnyHost) as? [String] {
                    for key in keys { CFPreferencesSetAppValue(key as CFString,nil,entry.id as CFString) }
                    CFPreferencesAppSynchronize(entry.id as CFString)
                }
            }
        }
        do {
            // 全操作は実際のMenuDrawerメニューから。設定の直書きで成功を代用しない。
            for (index,target) in targets.enumerated() {
                let other = targets[1-index]
                let otherPID = other.application?.processIdentifier
                let otherSetting = other.savedVisibility
                let otherCount = other.visibleIconCount
                for visible in [false, true] {
                    try await openMenu()
                    guard let row = find(bar, { label($0).hasPrefix(target.entry.name + " —") }) else { throw SwitchFailure(message: "対象が一覧にありません：\(target.entry.name)") }
                    _ = AXUIElementPerformAction(row, kAXPressAction as CFString)
                    var action: AXUIElement?
                    try await wait("サブメニューが開きません") { action = find(row) { label($0).hasPrefix(visible ? "表示する…" : "非表示にする…") }; return action != nil }
                    let pid = target.application?.processIdentifier
                    _ = AXUIElementPerformAction(action!, kAXPickAction as CFString)
                    var confirm: AXUIElement?
                    try await wait("再起動前の確認がありません") { confirm = find(app) { label($0) == "再起動して適用" }; return confirm != nil }
                    if index == 0 && !visible {
                        let setting = target.savedVisibility
                        let count = target.visibleIconCount
                        guard let cancel = find(app,{ label($0) == "キャンセル" }) else { throw SwitchFailure(message: "キャンセルがありません") }
                        _ = AXUIElementPerformAction(cancel,kAXPressAction as CFString)
                        try await Task.sleep(nanoseconds: 500_000_000)
                        guard target.application?.processIdentifier == pid, target.savedVisibility == setting, target.visibleIconCount == count else { throw SwitchFailure(message: "キャンセルで対象が変更されました") }
                        print("再起動前のキャンセル：PID・設定・表示は不変")
                        try await openMenu()
                        guard let retry = find(bar,{ label($0).hasPrefix(target.entry.name + " —") }) else { throw SwitchFailure(message: "対象が消えました") }
                        _ = AXUIElementPerformAction(retry,kAXPressAction as CFString)
                        guard let action = find(retry,{ label($0).hasPrefix("非表示にする…") }) else { throw SwitchFailure(message: "再選択できません") }
                        _ = AXUIElementPerformAction(action,kAXPickAction as CFString)
                        try await wait("再確認がありません") { confirm = find(app) { label($0) == "再起動して適用" }; return confirm != nil }
                    }
                    _ = AXUIElementPerformAction(confirm!, kAXPressAction as CFString)
                    try await wait("結果を確認できません：\(target.entry.name)") {
                        target.isRunning && target.application?.processIdentifier != pid && target.savedVisibility == visible && (target.visibleIconCount > 0) == visible
                    }
                    try await Task.sleep(nanoseconds: 4_500_000_000)
                    try await openMenu()
                    let operation = visible ? "表示" : "非表示"
                    guard find(bar,{ label($0).contains("\(target.entry.name)：\(operation)を確認しました") }) != nil else { throw SwitchFailure(message: "操作完了が表示されません") }
                    let expected = visible ? "表示・非表示確認済み" : "一部確認済み"
                    guard find(bar,{ label($0).hasPrefix(target.entry.name + " — " + expected) }) != nil else { throw SwitchFailure(message: "対応確認の表示が一致しません") }
                    closeMenu()
                    guard other.application?.processIdentifier == otherPID, other.savedVisibility == otherSetting, other.visibleIconCount == otherCount else { throw SwitchFailure(message: "別のアプリが変化しました：\(other.entry.name)、PID \(otherPID ?? 0)→\(other.application?.processIdentifier ?? 0)、設定 \(String(describing: otherSetting))→\(String(describing: other.savedVisibility))、表示数 \(otherCount)→\(other.visibleIconCount)") }
                    print("\(target.entry.name)：\(operation)成功、対象だけ再起動、他アプリのPID・設定・表示は不変")
                    fflush(stdout)
                }
            }
            let end = CGEvent(source: nil)!.location
            print("カーソル：開始\(cursor)、終了\(end)")
            try await clean()
            print("検証用アプリ停止・設定削除・MenuDrawerの検証前設定へ復元済み")
        } catch {
            // 製品の復旧と競合させない。確認が残っていればキャンセルする。
            if let cancel = find(app,{ label($0) == "キャンセル" }) { _ = AXUIElementPerformAction(cancel,kAXPressAction as CFString) }
            try await Task.sleep(nanoseconds: 15_000_000_000)
            if let ok = find(app,{ label($0) == "OK" }) { _ = AXUIElementPerformAction(ok,kAXPressAction as CFString) }
            try await clean()
            throw error
        }
    }
}
