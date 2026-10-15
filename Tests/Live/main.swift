import Cocoa
import ApplicationServices

func attribute(_ e: AXUIElement,_ key: String) -> CFTypeRef? {
    var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(e,key as CFString,&value) == .success else { return nil }; return value
}
func find(_ root: AXUIElement,depth:Int=0,_ predicate:(AXUIElement)->Bool) -> AXUIElement? {
    if predicate(root) { return root }
    guard depth<12 else { return nil }
    for child in attribute(root,kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let match = find(child,depth:depth+1,predicate) { return match } }
    return nil
}
func title(_ e:AXUIElement) -> String { attribute(e,kAXTitleAttribute) as? String ?? attribute(e,kAXDescriptionAttribute) as? String ?? "" }
@main struct MenuTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("実メニュー検証失敗：\(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { throw SwitchFailure(message:"Macがロック中") }
        guard let drawer = NSRunningApplication.runningApplications(withBundleIdentifier:"local.codex.MenuDrawer").first else { throw SwitchFailure(message:"MenuDrawer未起動") }
        let app = AXUIElementCreateApplication(drawer.processIdentifier); AXUIElementSetMessagingTimeout(app,0.3)
        guard let raw = attribute(app,kAXExtrasMenuBarAttribute) else { throw SwitchFailure(message:"メニューバーなし") }
        let bar = unsafeBitCast(raw,to:AXUIElement.self)
        guard let toggle = find(bar,{ title($0) == "アイコン収納" }) else { throw SwitchFailure(message:"新しい収納ボタンなし") }
        AXUIElementSetMessagingTimeout(toggle,0.3)
        func wait(_ name:String,_ predicate:()->Bool) async throws {
            let until = Date().addingTimeInterval(10)
            while Date()<until { if predicate() { return }; try await Task.sleep(nanoseconds:50_000_000) }
            throw SwitchFailure(message:name)
        }
        func openMenu() async throws {
            _ = AXUIElementPerformAction(toggle,kAXPressAction as CFString)
            try await wait("一覧が開きません") { find(bar,{ title($0) == "全て取り出す" }) != nil }
        }
        func closeMenu() {
            if let menu = find(bar,{ attribute($0,kAXRoleAttribute) as? String == kAXMenuRole }) { _ = AXUIElementPerformAction(menu,kAXCancelAction as CFString) }
        }
        func row(_ id:CGWindowID) -> AXUIElement? { find(bar,{ attribute($0,kAXIdentifierAttribute) as? String == "status-\(id)" }) }
        let initial = StatusWindows.list(excludingPID:drawer.processIdentifier)
        let targets = ["com.openai.codex","com.apple.TextInputMenuAgent"].compactMap { b in initial.first { $0.bundleID == b } }
        guard targets.count == 2 else { throw SwitchFailure(message:"ChatGPTと入力メニューの実アイコンが必要です") }
        func outside(_ id:CGWindowID) -> Bool { StatusWindows.frame(id).map { $0.maxX<=0 } ?? false }
        func choose(_ icon:MenuIcon,_ hidden:Bool) async throws {
            try await openMenu()
            guard let item = row(icon.id) else { throw SwitchFailure(message:"アイコンの項目がありません：\(icon.title)") }
            guard (attribute(item,kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { closeMenu(); throw SwitchFailure(message:"収納操作が無効です。固定署名版の初回アクセシビリティ許可が必要です") }
            let before = attribute(item,kAXMenuItemMarkCharAttribute) as? String ?? ""
            guard before.isEmpty == hidden else { closeMenu(); throw SwitchFailure(message:"検証前のチェック状態が想定外です。設定は変更しません") }
            // 実際のメニュー操作を行う。コアエンジンへの直接呼び出しでは代用しない。
            _ = AXUIElementPerformAction(item,kAXPressAction as CFString)
            try await wait("収納状態を確認できません：\(icon.title)") { outside(icon.id) == hidden }
            try await Task.sleep(nanoseconds:200_000_000)
            try await openMenu()
            guard let fresh = row(icon.id), (attribute(fresh,kAXMenuItemMarkCharAttribute) as? String ?? "").isEmpty != hidden else { closeMenu(); throw SwitchFailure(message:"チェック状態が実際の収納と一致しません") }
            closeMenu()
            print("実メニュー：\(icon.title)を\(hidden ? "収納" : "復帰")、チェック状態と実ウィンドウ位置が一致")
            fflush(stdout)
        }
        var changed:[MenuIcon] = []
        do {
            for icon in targets { try await choose(icon,true); changed.append(icon) }
            let others = initial.filter { icon in !targets.contains { $0.id == icon.id } }
            guard others.allSatisfy({ !outside($0.id) }) else { throw SwitchFailure(message:"未選択アイコンまで収納されました") }
            for icon in targets { try await choose(icon,false); changed.removeAll { $0.id == icon.id } }
            let final = StatusWindows.list(excludingPID:drawer.processIdentifier).filter { icon in initial.contains { $0.id == icon.id } }
            guard final.map(\.id) == initial.map(\.id), targets.allSatisfy({ icon in final.contains { $0.id == icon.id && $0.pid == icon.pid } }) else { throw SwitchFailure(message:"元の並びまたは対象アプリのPIDが一致しません") }
            print("インストール版の実メニュー検証：成功。対象アプリは再起動せず、元の並びへ復帰")
        } catch {
            closeMenu()
            if !changed.isEmpty {
                try? await openMenu()
                if let all = find(bar,{ title($0) == "全て取り出す" }) { _ = AXUIElementPerformAction(all,kAXPressAction as CFString) }
                try? await Task.sleep(nanoseconds:1_000_000_000)
                closeMenu()
            }
            throw error
        }
    }
}
