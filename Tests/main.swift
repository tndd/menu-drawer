import Foundation
@MainActor final class FakeTarget: VisibilityTarget {
    var isRunning: Bool
    var savedVisibility: Bool?
    var calls = [String]()
    var refuseStop = false
    var failStart = false
    var failVerify = false
    var failWrite = false
    init(running: Bool, saved: Bool?) { isRunning = running; savedVisibility = saved }
    func stop() async throws { calls.append("stop"); if refuseStop { throw SwitchFailure(message: "終了拒否") }; isRunning = false }
    func writeVisibility(_ value: Bool?) throws { calls.append("write:\(value.map(String.init) ?? "nil")"); savedVisibility = value; if failWrite { failWrite = false; throw SwitchFailure(message: "書込失敗") } }
    func start() async throws { calls.append("start"); if failStart { failStart = false; throw SwitchFailure(message: "起動失敗") }; isRunning = true }
    func verifyVisibility(_ visible: Bool) async throws { calls.append("verify"); if failVerify { throw SwitchFailure(message: "表示不一致") } }
}
@main struct Tests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1; print("成功：\(label)") }
        let hidden = FakeTarget(running: true, saved: nil)
        try await VisibilitySwitch.apply(visible: false, to: hidden)
        check(hidden.calls == ["stop", "write:false", "start", "verify"] && hidden.isRunning && hidden.savedVisibility == false, "終了後に非表示を書き、起動と実表示を検証")
        try await VisibilitySwitch.apply(visible: true, to: hidden)
        check(hidden.savedVisibility == true && hidden.isRunning, "表示へ戻す")
        let refused = FakeTarget(running: true, saved: nil); refused.refuseStop = true
        do { try await VisibilitySwitch.apply(visible: false, to: refused); fatalError("終了拒否を無視") } catch {}
        check(refused.calls == ["stop"] && refused.isRunning && refused.savedVisibility == nil, "終了拒否では設定を変更しない")
        for failure in ["write", "start", "verify"] {
            let target = FakeTarget(running: true, saved: nil)
            target.failWrite = failure == "write"; target.failStart = failure == "start"; target.failVerify = failure == "verify"
            do { try await VisibilitySwitch.apply(visible: false, to: target); fatalError("失敗が必要") } catch {}
            check(target.isRunning && target.savedVisibility == nil, "\(failure)失敗で元の未設定値と起動状態を復元")
        }
        let stopped = FakeTarget(running: false, saved: true); stopped.failVerify = true
        do { try await VisibilitySwitch.apply(visible: false, to: stopped); fatalError("失敗が必要") } catch {}
        check(!stopped.isRunning && stopped.savedVisibility == true, "元が停止中なら復旧後も停止")
        let rollback = FakeTarget(running: true, saved: false); rollback.failVerify = true
        do { try await VisibilitySwitch.apply(visible: true, to: rollback); fatalError("失敗が必要") } catch {}
        check(rollback.savedVisibility == false && rollback.isRunning, "元の非表示設定も復元")
        print("\(count)検証に成功")
    }
}
