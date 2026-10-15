import Cocoa
import ApplicationServices

@MainActor final class IconMover {
    struct CursorReport { let start: CGPoint; let end: CGPoint }
    private let transport = ItemTransport()
    private(set) var lastCursor: CursorReport?
    private var moving = false
    private func userIsIdle() -> Bool {
        let modifiers = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift])
        return modifiers.isEmpty && !CGEventSource.buttonState(.combinedSessionState,button:.left) && !CGEventSource.buttonState(.combinedSessionState,button:.right) && CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.mouseMoved) > 0.25
    }

    func move(_ icon: MenuIcon, beside targetID: CGWindowID, left: Bool) async throws {
        guard AXIsProcessTrusted() else { throw SwitchFailure(message:"アイコンの移動にはアクセシビリティの許可が必要です") }
        guard !moving else { throw SwitchFailure(message:"アイコンを移動中です") }
        guard icon.protectedReason == nil else { throw SwitchFailure(message:icon.protectedReason!) }
        moving = true; defer { moving = false }
        // 入力停止とフレーム安定を同じ待機枠で確認する。安定待ち中の短い入力では、
        // 即座に失敗させず座標から確認し直し、操作中の位置へドラッグしない。
        let deadline = Date().addingTimeInterval(3)
        var initial = CGRect.zero
        var destination = CGRect.zero
        while Date() < deadline {
            if userIsIdle() {
                initial = try await StatusWindows.waitForStableFrame(icon.id)
                destination = try await StatusWindows.waitForStableFrame(targetID)
                if userIsIdle() { break }
            }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        guard Date() < deadline else { throw SwitchFailure(message:"マウスと修飾キーを離してから再試行してください") }
        if abs(left ? initial.maxX-destination.minX : initial.minX-destination.maxX) < 2 { return }
        guard let cursor = CGEvent(source:nil)?.location, let source = CGEventSource(stateID:.hidSystemState) else { throw SwitchFailure(message:"マウスの状態を取得できません") }
        let end = CGPoint(x:left ? destination.minX : destination.maxX,y:destination.midY)
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents,.permitLocalKeyboardEvents,.permitSystemDefinedEvents],state:.eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents,.permitLocalKeyboardEvents,.permitSystemDefinedEvents],state:.eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0
        let down = try transport.event(type:.leftMouseDown,point:CGPoint(x:20_000,y:20_000),window:icon.id,pid:icon.pid,source:source)
        let up = try transport.event(type:.leftMouseUp,point:end,window:targetID,pid:icon.pid,source:source)
        let fallback = try transport.event(type:.leftMouseUp,point:CGPoint(x:initial.midX,y:initial.midY),window:icon.id,pid:icon.pid,source:source)
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(cursor)
            CGDisplayShowCursor(CGMainDisplayID())
            lastCursor = CursorReport(start:cursor,end:CGEvent(source:nil)?.location ?? cursor)
        }
        do {
            try await transport.send(down,to:icon.pid)
            // 押下中の位置にはドラッグ用の仮配置が混ざる。解放先は安定した開始前の位置を使う。
            try await Task.sleep(nanoseconds:50_000_000)
            try await transport.send(up,to:icon.pid)
            let until = Date().addingTimeInterval(1.5)
            var lastFrame: CGRect?
            var stableSince = Date()
            while Date() < until {
                if let a = StatusWindows.frame(icon.id), let b = StatusWindows.frame(targetID), abs(left ? a.maxX-b.minX : a.minX-b.maxX) < 2 {
                    if a != lastFrame { lastFrame = a; stableSince = Date() }
                    else if Date().timeIntervalSince(stableSince) >= 0.08 { return }
                } else { lastFrame = nil; stableSince = Date() }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            throw SwitchFailure(message:"移動後のアイコンの並びを確認できませんでした")
        } catch {
            // 押下の途中でも必ず解放する。失敗を成功扱いにはしない。
            fallback.post(tap:.cgSessionEventTap); fallback.postToPid(icon.pid)
            try? await Task.sleep(nanoseconds:50_000_000)
            throw error
        }
    }
}
