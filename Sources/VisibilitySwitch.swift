import Foundation

@MainActor protocol VisibilityTarget: AnyObject {
    var isRunning: Bool { get }
    var savedVisibility: Bool? { get }
    func stop() async throws
    func writeVisibility(_ value: Bool?) throws
    func start() async throws
    func verifyVisibility(_ visible: Bool) async throws
}

struct SwitchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// 設定一個だけを変更する。失敗した場合は設定の有無も含めて元に戻す。
@MainActor enum VisibilitySwitch {
    static func apply(visible: Bool, to target: VisibilityTarget) async throws {
        let wasRunning = target.isRunning
        let previous = target.savedVisibility
        try await target.stop() // 終了を拒否されたら、設定には触れない。
        do {
            try target.writeVisibility(visible)
            try await target.start()
            try await target.verifyVisibility(visible)
        } catch {
            let failure = error.localizedDescription
            do {
                try await target.stop()
                try target.writeVisibility(previous)
                if wasRunning { try await target.start() }
            } catch {
                throw SwitchFailure(message: "切り替えに失敗しました：\(failure)\n元の状態への復旧も完了していません：\(error.localizedDescription)")
            }
            throw SwitchFailure(message: "切り替えに失敗したため、元の設定へ戻しました。\n\(failure)")
        }
    }
}
