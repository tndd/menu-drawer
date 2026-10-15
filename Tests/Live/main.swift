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
func title(_ e:AXUIElement) -> String { [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap { attribute(e,$0) as? String }.first { !$0.isEmpty } ?? "" }
@main struct MenuTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("実メニュー検証失敗：\(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { throw SwitchFailure(message:"Macがロック中") }
        guard var drawer = NSRunningApplication.runningApplications(withBundleIdentifier:"local.codex.MenuDrawer").first else { throw SwitchFailure(message:"MenuDrawer未起動") }
        var app = AXUIElementCreateApplication(drawer.processIdentifier); AXUIElementSetMessagingTimeout(app,0.3)
        guard let raw = attribute(app,kAXExtrasMenuBarAttribute) else { throw SwitchFailure(message:"メニューバーなし") }
        var bar = unsafeBitCast(raw,to:AXUIElement.self)
        guard var toggle = find(bar,{ title($0) == "アイコン収納" }) else { throw SwitchFailure(message:"新しい収納ボタンなし") }
        AXUIElementSetMessagingTimeout(toggle,0.3)
        func checkAlert() throws {
            let windows = attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in windows {
                if let message = find(window,{ title($0).contains("完了できませんでした") }) {
                    let detail = find(window,{ attribute($0,kAXRoleAttribute) as? String == kAXStaticTextRole && title($0) != title(message) })
                    let text = title(message) + "：" + (detail.map(title) ?? "")
                    if let ok = find(window,{ title($0) == "OK" }) { _ = AXUIElementPerformAction(ok,kAXPressAction as CFString) }
                    throw SwitchFailure(message:text)
                }
            }
        }
        func wait(_ name:String,_ predicate:()->Bool) async throws {
            let until = Date().addingTimeInterval(10)
            while Date()<until { try checkAlert(); if predicate() { return }; try await Task.sleep(nanoseconds:50_000_000) }
            throw SwitchFailure(message:name)
        }
        func menuIsVisible() -> Bool {
            guard let menu = find(bar,{ attribute($0,kAXRoleAttribute) as? String == kAXMenuRole }), let raw = attribute(menu,kAXSizeAttribute) else { return false }
            var size = CGSize.zero
            return AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cgSize,&size) && size.width > 0 && size.height > 0
        }
        func openMenu() async throws {
            try await wait("前の一覧が閉じません") { !menuIsVisible() }
            _ = AXUIElementPerformAction(toggle,kAXPressAction as CFString)
            try await wait("一覧が開きません") { menuIsVisible() }
        }
        func closeMenu() async throws {
            if let menu = find(bar,{ attribute($0,kAXRoleAttribute) as? String == kAXMenuRole }) { _ = AXUIElementPerformAction(menu,kAXCancelAction as CFString) }
            try await wait("一覧が閉じません") { !menuIsVisible() }
        }
        func row(_ id:CGWindowID) -> AXUIElement? { find(bar,{ attribute($0,kAXIdentifierAttribute) as? String == "status-\(id)" }) }
        func checkSection(_ item:AXUIElement,_ hidden:Bool) throws {
            guard let rawParent = attribute(item,kAXParentAttribute) else { throw SwitchFailure(message:"メニューの親がありません") }
            let parent = unsafeBitCast(rawParent,to:AXUIElement.self)
            let children = attribute(parent,kAXChildrenAttribute) as? [AXUIElement] ?? []
            let ids = children.map { attribute($0,kAXIdentifierAttribute) as? String ?? "" }
            let itemID = attribute(item,kAXIdentifierAttribute) as? String ?? ""
            guard let upper = ids.firstIndex(of:"section-hidden"), let lower = ids.firstIndex(of:"section-available"), let index = ids.firstIndex(of:itemID), upper < lower,
                  hidden ? (upper < index && index < lower) : lower < index else { throw SwitchFailure(message:"収納中が上段、収納可能が下段になっていません") }
        }
        let initial = StatusWindows.list(excludingPID:drawer.processIdentifier)
        let initialWithDrawer = StatusWindows.list()
        let originalDrawerPID = drawer.processIdentifier
        let originalOrder = initialWithDrawer.map { $0.pid == drawer.processIdentifier ? "drawer" : String($0.id) }
        func sameOrderWithDrawer() -> Bool {
            let current = StatusWindows.list().filter { icon in icon.pid == drawer.processIdentifier || initial.contains { $0.id == icon.id } }
            return current.map { $0.pid == drawer.processIdentifier ? "drawer" : String($0.id) } == originalOrder
        }
        func checkRestoredPositions() throws {
            let current = StatusWindows.list()
            let before = initialWithDrawer
            let after = before.compactMap { old in current.first { item in old.pid == originalDrawerPID ? item.pid == drawer.processIdentifier : item.id == old.id } }
            guard current.count == before.count, before.count == after.count, let oldRight = before.last, let newRight = after.last else { throw SwitchFailure(message:"検証中に対象アイコンが増減しました") }
            var widthChange: CGFloat = 0
            var largest: CGFloat = 0
            for index in before.indices.reversed() {
                widthChange += after[index].frame.width-before[index].frame.width
                // 時計やバッテリーの表示幅が変わった分の自然な詰めだけを補正する。
                let expected = before[index].frame.minX + newRight.frame.maxX-oldRight.frame.maxX-widthChange
                largest = max(largest,abs(after[index].frame.minX-expected))
            }
            guard largest <= 1.5 else { throw SwitchFailure(message:"元の位置に戻っていません：最大\(largest)ポイント") }
            print("座標復元：表示幅の変動を除く最大差\(largest)ポイント")
        }
        let targets = ["com.openai.codex","com.apple.TextInputMenuAgent"].compactMap { b in initial.first { $0.bundleID == b } }
        guard targets.count == 2 else { throw SwitchFailure(message:"ChatGPTと入力メニューの実アイコンが必要です") }
        func outside(_ id:CGWindowID) -> Bool { StatusWindows.frame(id).map { $0.maxX<=0 } ?? false }
        func choose(_ icon:MenuIcon,_ hidden:Bool) async throws {
            try await openMenu()
            guard let item = row(icon.id) else { throw SwitchFailure(message:"アイコンの項目がありません：\(icon.title)") }
            guard (attribute(item,kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { try? await closeMenu(); throw SwitchFailure(message:"収納操作が無効です。固定署名版の初回アクセシビリティ許可が必要です") }
            let before = attribute(item,kAXMenuItemMarkCharAttribute) as? String ?? ""
            guard before.isEmpty == hidden else { try? await closeMenu(); throw SwitchFailure(message:"検証前のチェック状態が想定外です。設定は変更しません") }
            try checkSection(item,!hidden)
            // 実際のメニュー操作を行う。コアエンジンへの直接呼び出しでは代用しない。
            let cursorBefore = CGEvent(source:nil)?.location
            let result = AXUIElementPerformAction(item,kAXPickAction as CFString)
            guard result == .success else { try? await closeMenu(); throw SwitchFailure(message:"メニュー項目の選択に失敗しました：\(result.rawValue)") }
            try await wait("収納状態を確認できません：\(icon.title)") { outside(icon.id) == hidden }
            try await Task.sleep(nanoseconds:2_000_000_000)
            try checkAlert()
            guard let start = cursorBefore, let end = CGEvent(source:nil)?.location, hypot(start.x-end.x,start.y-end.y) <= 1.5 else { throw SwitchFailure(message:"操作後にカーソル位置が変わりました：\(String(describing:cursorBefore))→\(String(describing:CGEvent(source:nil)?.location))") }
            let controls = StatusWindows.list().filter { $0.pid == drawer.processIdentifier && $0.frame.width < 100 }
            guard controls.count == 1, let control = controls.first, let screen = NSScreen.screens.first,
                  control.frame.minX >= (screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX), control.frame.maxX <= screen.frame.maxX else {
                throw SwitchFailure(message:"MenuDrawer自身のボタンが表示領域にありません")
            }
            try await openMenu()
            guard let fresh = row(icon.id), (attribute(fresh,kAXMenuItemMarkCharAttribute) as? String ?? "").isEmpty != hidden else { try? await closeMenu(); throw SwitchFailure(message:"チェック状態が実際の収納と一致しません") }
            try checkSection(fresh,hidden)
            try await closeMenu()
            print("実メニュー：\(icon.title)を\(hidden ? "収納して上段へ" : "取り出して下段へ")、チェック状態と実ウィンドウ位置が一致")
            fflush(stdout)
        }
        var changed:[MenuIcon] = []
        do {
            if let button = initialWithDrawer.first(where:{ $0.pid == drawer.processIdentifier }), let left = initial.last(where:{ $0.frame.minX < button.frame.minX && $0.protectedReason == nil }) {
                try await choose(left,true); changed.append(left)
                try await choose(left,false); changed.removeAll { $0.id == left.id }
                guard sameOrderWithDrawer() else { throw SwitchFailure(message:"左側の項目とMenuDrawerボタンが入れ替わりました") }
                try checkRestoredPositions()
                print("MenuDrawerボタンの左側の項目を出し入れしても、ボタンを含む並びを維持")
            } else { throw SwitchFailure(message:"左側の復元を検証するための一時アイコンがありません") }
            for icon in targets.reversed() { try await choose(icon,true); changed.append(icon) }
            let others = initial.filter { icon in !targets.contains { $0.id == icon.id } }
            guard others.allSatisfy({ !outside($0.id) }) else { throw SwitchFailure(message:"未選択アイコンまで収納されました") }
            for icon in targets.reversed() { try await choose(icon,false); changed.removeAll { $0.id == icon.id } }
            guard sameOrderWithDrawer() else { throw SwitchFailure(message:"右の項目から収納・取り出しすると並びが変わりました") }
            try checkRestoredPositions()
            // 通常終了で戻し、保存した選択が背景での再起動後にも反映されることを確認する。
            let saved = targets[0]
            try await choose(saved,true); changed.append(saved)
            guard drawer.terminate() else { throw SwitchFailure(message:"通常終了の要求に失敗しました") }
            try await wait("通常終了後にアイコンが復帰しません") { drawer.isTerminated && !outside(saved.id) }
            let afterQuit = StatusWindows.list(excludingPID:drawer.processIdentifier).filter { icon in initial.contains { $0.id == icon.id } }
            guard afterQuit.map(\.id) == initial.map(\.id) else { throw SwitchFailure(message:"通常終了で元の並びに戻りません") }
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            drawer = try await NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:"/Applications/MenuDrawer.app"),configuration:config)
            app = AXUIElementCreateApplication(drawer.processIdentifier); AXUIElementSetMessagingTimeout(app,0.3)
            try await wait("再起動後のメニューバーが取得できません") { attribute(app,kAXExtrasMenuBarAttribute) != nil }
            guard let freshBar = attribute(app,kAXExtrasMenuBarAttribute) else { throw SwitchFailure(message:"再起動後のメニューバーなし") }
            bar = unsafeBitCast(freshBar,to:AXUIElement.self)
            try await wait("再起動後の収納ボタンがありません") { find(bar,{ title($0) == "アイコン収納" }) != nil }
            guard let freshToggle = find(bar,{ title($0) == "アイコン収納" }) else { throw SwitchFailure(message:"再起動後の収納ボタンなし") }
            toggle = freshToggle; AXUIElementSetMessagingTimeout(toggle,0.3)
            try await wait("保存した選択が再起動後に反映されません") { outside(saved.id) }
            try await choose(saved,false); changed.removeAll { $0.id == saved.id }
            print("通常終了で復帰し、背景での再起動後に保存した選択を再収納：成功")
            let final = StatusWindows.list(excludingPID:drawer.processIdentifier).filter { icon in initial.contains { $0.id == icon.id } }
            guard final.map(\.id) == initial.map(\.id), targets.allSatisfy({ icon in final.contains { $0.id == icon.id && $0.pid == icon.pid } }) else { throw SwitchFailure(message:"元の並びまたは対象アプリのPIDが一致しません") }
            guard sameOrderWithDrawer() else { throw SwitchFailure(message:"再起動後にMenuDrawerボタンとの並びが変わりました") }
            try checkRestoredPositions()
            print("インストール版の実メニュー検証：成功。対象アプリは再起動せず、元の並びへ復帰")
        } catch {
            try? await closeMenu()
            if !changed.isEmpty || initial.contains(where:{ outside($0.id) }) {
                try? await openMenu()
                if let all = find(bar,{ title($0) == "全て取り出す" }) { _ = AXUIElementPerformAction(all,kAXPickAction as CFString) }
                try? await Task.sleep(nanoseconds:1_000_000_000)
                try? await closeMenu()
            }
            throw error
        }
    }
}
