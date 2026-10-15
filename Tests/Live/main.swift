import Cocoa
import ApplicationServices

func attribute(_ e: AXUIElement,_ key: String) -> CFTypeRef? {
    var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(e,key as CFString,&value) == .success else { return nil }; return value
}
func find(_ root: AXUIElement,depth: Int = 0,_ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    guard depth < 18 else { return nil }
    for child in attribute(root,kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let match = find(child,depth:depth+1,predicate) { return match } }
    return nil
}
func title(_ e: AXUIElement) -> String { [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap { attribute(e,$0) as? String }.first { !$0.isEmpty } ?? "" }

@main struct WindowTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("実ウィンドウ検証失敗：\(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
        guard AXIsProcessTrusted() else { throw SwitchFailure(message:"検証プロセスのアクセシビリティ未許可") }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { throw SwitchFailure(message:"Macがロック中") }
        guard var drawer = NSRunningApplication.runningApplications(withBundleIdentifier:"local.codex.MenuDrawer").first else { throw SwitchFailure(message:"MenuDrawer未起動") }
        var stage = "起動"
        var app = AXUIElementCreateApplication(drawer.processIdentifier)
        AXUIElementSetMessagingTimeout(app,0.3)
        func require(_ ok: Bool,_ message: String) throws { if !ok { throw SwitchFailure(message:message) } }
        func element(_ id: String) -> AXUIElement? { find(app) { attribute($0,kAXIdentifierAttribute) as? String == id } }
        func checkAlert() throws {
            for window in attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                if let message = find(window,{ title($0).contains("完了できませんでした") }) {
                    var messages = [title(message)]
                    _ = find(window) { item in
                        if attribute(item,kAXRoleAttribute) as? String == kAXStaticTextRole { messages.append(title(item)) }
                        return false
                    }
                    let detail = Array(Set(messages.filter { !$0.isEmpty })).sorted().joined(separator:" / ")
                    if let ok = find(window,{ title($0) == "OK" }) { _ = AXUIElementPerformAction(ok,kAXPressAction as CFString) }
                    throw SwitchFailure(message:detail)
                }
            }
        }
        func wait(_ message: String,_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                try checkAlert(); if predicate() { return }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            throw SwitchFailure(message:stage+"："+message)
        }
        func idle() async throws { try await wait("処理が完了しません") { element("reload").flatMap { attribute($0,kAXEnabledAttribute) as? Bool } == true } }
        func press(_ id: String) throws {
            guard let item = element(id), AXUIElementPerformAction(item,kAXPressAction as CFString) == .success else { throw SwitchFailure(message:"操作できません："+id) }
        }
        func outside(_ id: CGWindowID) -> Bool { StatusWindows.frame(id).map { $0.maxX <= 0 } ?? false }
        func onScreenWindows() -> [[String:Any]] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == drawer.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
        }
        func reopen() async throws {
            let configuration = NSWorkspace.OpenConfiguration()
            drawer = try await NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:"/Applications/MenuDrawer.app"),configuration:configuration)
            app = AXUIElementCreateApplication(drawer.processIdentifier); AXUIElementSetMessagingTimeout(app,0.3)
            try await wait("起動・再呼び出しで画面が表示されません") { !onScreenWindows().isEmpty && element("reload") != nil }
            try await idle()
        }
        func setHiddenPreference(_ hidden: Bool) async throws {
            try await idle()
            guard let box = element("hide-menubar-icon"), let value = attribute(box,kAXValueAttribute) as? Int else { throw SwitchFailure(message:"非表示チェックがありません") }
            if (value == 1) != hidden { try press("hide-menubar-icon"); try await idle() }
            try require((element("hide-menubar-icon").flatMap { attribute($0,kAXValueAttribute) as? Int } == 1) == hidden,"非表示チェックの状態が一致しません")
        }
        func choose(_ icon: MenuIcon,_ hidden: Bool) async throws {
            try await idle(); try press("status-\(icon.id)")
            try await wait("マークの操作が実アイコンの移動に反映されません") {
                outside(icon.id) == hidden && element("status-\(icon.id)").map { title($0).contains(hidden ? "取り出す" : "収納する") } == true
            }
            try await idle()
        }
        try await reopen()
        guard let initialValue = element("hide-menubar-icon").flatMap({ attribute($0,kAXValueAttribute) as? Int }) else { throw SwitchFailure(message:"非表示チェックなし") }
        guard find(app,{ title($0) == "収納中（0）" }) != nil else { throw SwitchFailure(message:"ユーザーの収納状態を変更しないため、収納が空の状態で実行してください") }
        let fixtures = StatusWindows.list().filter { $0.bundleID.hasPrefix("local.codex.MenuDrawerTest.") }
        try require(fixtures.count == 2,"専用の検証アイコンが2個必要です")
        let original = StatusWindows.list().map(\.id)
        func sameOrder() -> Bool { StatusWindows.list().map(\.id).filter { original.contains($0) } == original.filter { StatusWindows.frame($0) != nil } }
        do {
            try await setHiddenPreference(true)
            try require(drawer.activationPolicy == .accessory,"Dock非表示の構成ではありません")
            try require(!StatusWindows.list().contains { $0.pid == drawer.processIdentifier },"空の収納に自アプリのメニューバー領域が残っています")
            try await choose(fixtures[0],true)
            try require(find(app,{ title($0) == "収納中（1）" }) != nil,"収納側の件数が変わりません")
            let pid = drawer.processIdentifier
            guard let window = (attribute(app,kAXWindowsAttribute) as? [AXUIElement])?.first(where:{ title($0) == "MenuDrawer" }), let rawClose = attribute(window,kAXCloseButtonAttribute) else { throw SwitchFailure(message:"閉じるボタンなし") }
            try require(AXUIElementPerformAction(unsafeBitCast(rawClose,to:AXUIElement.self),kAXPressAction as CFString) == .success,"画面を閉じられません")
            try await wait("閉じた画面が残ります") { onScreenWindows().isEmpty }
            try await Task.sleep(nanoseconds:700_000_000)
            try require(!drawer.isTerminated && outside(fixtures[0].id),"画面を閉じると収納が解除されました")
            try await reopen()
            try require(drawer.processIdentifier == pid && outside(fixtures[0].id),"再呼び出しで別プロセスや別状態になりました")
            print("Dock・上部アイコンなし、画面を閉じても収納を維持、再呼び出しは同一PID：成功")
            stage = "収納中の操作アイコン表示"
            try await setHiddenPreference(false)
            try require(outside(fixtures[0].id) && StatusWindows.list().contains { $0.pid == drawer.processIdentifier && $0.frame.width < 100 && $0.frame.minX >= 0 },"収納中に操作アイコンを表示できません")
            stage = "収納中の操作アイコン非表示"
            try await setHiddenPreference(true)
            try require(outside(fixtures[0].id) && StatusWindows.list().filter { $0.pid == drawer.processIdentifier }.count == 1,"操作アイコンを消すと収納境界も消えるか、ボタンが残ります")
            stage = "個別・全体取り出し"
            try await choose(fixtures[1],true)
            try await choose(fixtures[0],false)
            try require(outside(fixtures[1].id),"別の収納アイコンも取り出されました")
            try await choose(fixtures[1],false)
            try require(sameOrder(),"個別の取り出しで元の並びに戻りません")
            try await choose(fixtures[0],true)
            try press("restore-all"); try await idle()
            try require(fixtures.allSatisfy { !outside($0.id) } && sameOrder(),"全て取り出すで元の並びに戻りません")
            try await setHiddenPreference(false)
            try await choose(fixtures[0],true)
            stage = "通常終了と再起動"
            let old = drawer
            guard let quit = element("quit") else { throw SwitchFailure(message:"終了ボタンがありません") }
            let quitResult = AXUIElementPerformAction(quit,kAXPressAction as CFString)
            // 終了でAXの接続自体が切れる場合は、実際の終了と復元を次の待機で検査する。
            try require(quitResult == .success || quitResult == .cannotComplete,"終了操作を送信できません")
            try await wait("通常終了でアイコンが復帰しません") { old.isTerminated && !outside(fixtures[0].id) }
            try await reopen()
            try await wait("再起動後に保存した収納が反映されません") { outside(fixtures[0].id) }
            try require(element("hide-menubar-icon").flatMap { attribute($0,kAXValueAttribute) as? Int } == 0,"非表示設定が再起動で変わりました")
            try await idle(); try press("restore-all"); try await idle()
            try await setHiddenPreference(initialValue == 1)
            try require(fixtures.allSatisfy { !outside($0.id) },"検証アイコンが収納されたままです")
            print("マークの双方向移動・個別/全体復元・収納中の表示切替・通常終了と再起動時の設定/収納復元：成功")
            print("専用の検証アイコンのみ操作。ユーザーの他アプリは収納せず、検証前の非表示設定へ復帰")
        } catch {
            try? await reopen(); try? press("restore-all"); try? await idle(); try? await setHiddenPreference(initialValue == 1)
            throw error
        }
    }
}
