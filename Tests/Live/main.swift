import Cocoa
import ApplicationServices
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }; return value }
func find(_ root: AXUIElement, depth: Int = 0, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    guard depth < 10 else { return nil }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let match = find(child, depth: depth + 1, predicate) { return match } }
    return nil
}
func label(_ e: AXUIElement) -> String { [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(e, $0) as? String }.joined(separator: " ") }
@main struct LiveTests {
    @MainActor static func main() async {
        do { try await run() } catch { print(error.localizedDescription); exit(1) }
    }
    @MainActor static func run() async throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { throw SwitchFailure(message: "ロック中") }
        let target = TypelessTarget()
        let originallyRunning = target.isRunning
        let originalSetting = target.savedVisibility
        let originalCursor = CGEvent(source: nil)!.location
        guard let drawer = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.MenuDrawer").first else { throw SwitchFailure(message: "MenuDrawer未起動") }
        let app = AXUIElementCreateApplication(drawer.processIdentifier)
        guard let raw = attribute(app, kAXExtrasMenuBarAttribute) else { throw SwitchFailure(message: "操作ボタンなし") }
        let bar = unsafeBitCast(raw, to: AXUIElement.self)
        guard let toggle = find(bar, { label($0).contains("Typelessのアイコン表示") }) else { throw SwitchFailure(message: "旧版が起動しています") }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(16)
            while Date() < deadline { if predicate() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
            throw SwitchFailure(message: "操作が完了しません")
        }
        func restore() async throws {
            try await target.stop(); try target.writeVisibility(originalSetting)
            if originallyRunning { try await target.start() }
        }
        do {
            for visible in [false, true, false, true] {
                AXUIElementSetMessagingTimeout(toggle, 0.3)
                _ = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
                var action: AXUIElement?
                try await wait { action = find(bar) { label($0).hasPrefix(visible ? "表示して" : "非表示にして") }; return action != nil }
                let previousPID = target.application?.processIdentifier
                guard AXUIElementPerformAction(action!, kAXPickAction as CFString) == .success else { throw SwitchFailure(message: "メニューを押せません") }
                var lastState = ""
                try await wait {
                    let state = "pid=\(target.application?.processIdentifier ?? 0) setting=\(target.savedVisibility.map(String.init) ?? "nil") icons=\(target.visibleIconCount)"
                    if state != lastState { print(state); fflush(stdout); lastState = state }
                    return target.isRunning && target.application?.processIdentifier != previousPID && target.savedVisibility == visible && (target.visibleIconCount > 0) == visible
                }
                // 完了表示と操作の再有効化も確認する。
                try await Task.sleep(nanoseconds: 4_500_000_000)
                _ = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
                try await wait { find(bar) { label($0).hasPrefix(visible ? "表示して" : "非表示にして") && attribute($0,kAXEnabledAttribute) as? Bool == true } != nil }
                let expected = visible ? "Typelessのアイコン：表示中" : "Typelessのアイコン：非表示"
                guard find(bar, { label($0).contains(expected) }) != nil else { throw SwitchFailure(message: "結果の表示が実状態と一致しません") }
                // AXCancelでメニューを閉じる。物理マウスは使用しない。
                if let menu = find(bar, { attribute($0,kAXRoleAttribute) as? String == kAXMenuRole }) { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
                print("UIから\(visible ? "表示" : "非表示")：成功、PID \(target.application!.processIdentifier)、表示アイコン \(target.visibleIconCount)")
                fflush(stdout)
            }
            let cursor = CGEvent(source: nil)!.location
            print("カーソル開始 \(originalCursor)、終了 \(cursor)（テストもマウスイベントなし）")
            try await restore()
            print("検証前のTypeless設定・起動状態に復元済み")
        } catch {
            try await restore()
            throw error
        }
    }
}
