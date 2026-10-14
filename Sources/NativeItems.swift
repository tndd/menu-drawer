import Cocoa
import ApplicationServices

// macOSのステータス項目を実際に移動・クリックする境界。
// 51はAppKitのイベントに入るウィンドウ番号のフィールド。
enum NativeItems {
    enum Failure: Error { case missingItem, eventUnavailable, moveFailed }
    struct Anchor { let id: CGWindowID; let rightSide: Bool }

    static func window(_ id: CGWindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).first { $0[kCGWindowNumber as String] as? CGWindowID == id }
    }
    static func frame(_ id: CGWindowID) -> CGRect? {
        guard let bounds = window(id)?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
    static func visibleWindows(pid: pid_t) -> [CGWindowID: Int] {
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [CGWindowID: Int] = [:]
        for row in rows where row[kCGWindowOwnerPID as String] as? pid_t == pid {
            if let id = row[kCGWindowNumber as String] as? CGWindowID, let layer = row[kCGWindowLayer as String] as? Int, layer != 25, layer != 24 { result[id] = layer }
        }
        return result
    }

    // 呼び出し元の専用キューで直列に実行する。返却前に実座標を確認する。
    static func move(_ entry: MenuEntry, to anchor: Anchor) throws {
        guard let start = frame(entry.id), let target = frame(anchor.id) else { throw Failure.missingItem }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw Failure.eventUnavailable }
        source.localEventsSuppressionInterval = 0
        let filters: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(filters, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(filters, state: .eventSuppressionStateSuppressionInterval)
        let cursor = CGEvent(source: nil)?.location
        let cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer {
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()) }
        }
        func event(_ type: CGEventType, _ point: CGPoint, _ windowID: CGWindowID, command: Bool) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw Failure.eventUnavailable }
            event.flags = command ? .maskCommand : []
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(entry.pid))
            for field in [CGEventField(rawValue: 51)!, .mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
                event.setIntegerValueField(field, value: Int64(windowID))
            }
            return event
        }
        func deliver(_ event: CGEvent) {
            CGEvent(source: nil)?.postToPid(entry.pid)
            Thread.sleep(forTimeInterval: 0.02)
            event.post(tap: .cgSessionEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            event.postToPid(entry.pid)
            Thread.sleep(forTimeInterval: 0.08)
        }
        // 画面上の別のアプリを押さない位置でドラッグを開始し、対象のウィンドウ番号へ届ける。
        let down = try event(.leftMouseDown, CGPoint(x: 20000, y: 20000), entry.id, command: true)
        let up = try event(.leftMouseUp, CGPoint(x: anchor.rightSide ? target.maxX + 8 : target.minX - 8, y: start.midY), anchor.id, command: false)
        deliver(down)
        let drag = try event(.leftMouseDragged, up.location, anchor.id, command: true)
        deliver(drag)
        deliver(up)
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if let item = frame(entry.id), let currentTarget = frame(anchor.id),
               anchor.rightSide ? item.minX >= currentTarget.maxX - 1 : item.maxX <= currentTarget.minX + 1 { return }
            Thread.sleep(forTimeInterval: 0.04)
        }
        NSLog("移動失敗 %@ start=%@ target=%@ current=%@", entry.name, NSStringFromRect(start), NSStringFromRect(target), NSStringFromRect(frame(entry.id) ?? .zero))
        throw Failure.moveFailed
    }

    // 本物のアイコンを押す間はカーソルを隠し、元の位置へ戻してから再表示する。
    static func click(_ entry: MenuEntry) throws {
        guard let frame = frame(entry.id), frame.width > 0,
              window(entry.id)?[kCGWindowIsOnscreen as String] as? Bool == true else { throw Failure.missingItem }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let cursor = CGEvent(source: nil)?.location
        let cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer {
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()) }
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw Failure.eventUnavailable }
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.06)
        }
    }
}
