import Cocoa
import ApplicationServices

// Ice MenuBarItemManager.scrombleEventの配送手順を移植。
// PID宛てnullイベント → セッションへの実イベント → 到達確認 → PIDへ転送。
// 出典・ライセンスはTHIRD_PARTY.mdを参照。
@MainActor final class ItemTransport {
    @MainActor private final class Delivery {
        let packet: CGEvent
        let pid: pid_t
        let token: Int64
        var pidTap: CFMachPort?
        var sessionTap: CFMachPort?
        var sources: [CFRunLoopSource] = []
        var timer: Timer?
        var continuation: CheckedContinuation<Void,Error>?
        init(packet: CGEvent,pid: pid_t) {
            self.packet = packet; self.pid = pid
            token = packet.getIntegerValueField(.eventSourceUserData)
        }
        func finish(_ error: Error? = nil) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.invalidate(); timer = nil
            for tap in [pidTap,sessionTap].compactMap({ $0 }) { CGEvent.tapEnable(tap:tap,enable:false); CFMachPortInvalidate(tap) }
            for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
            sources.removeAll(); pidTap = nil; sessionTap = nil
            if let error { continuation.resume(throwing:error) } else { continuation.resume() }
        }
    }
    static let windowField = CGEventField(rawValue:0x33)!
    private var serial: Int64 = Int64(ProcessInfo.processInfo.processIdentifier) << 32
    private var active: Delivery?

    func event(type: CGEventType, point: CGPoint, window: CGWindowID, pid: pid_t, source: CGEventSource) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:.left) else { throw SwitchFailure(message:"移動イベントを作成できません") }
        event.flags = type == .leftMouseDown ? .maskCommand : []
        serial += 1
        event.setIntegerValueField(.eventSourceUserData,value:serial)
        event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
        for field in [CGEventField.mouseEventWindowUnderMousePointer,.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,Self.windowField] { event.setIntegerValueField(field,value:Int64(window)) }
        return event
    }
    func send(_ packet: CGEvent, to pid: pid_t) async throws {
        guard active == nil else { throw SwitchFailure(message:"別の移動処理が実行中です") }
        let delivery = Delivery(packet:packet,pid:pid); active = delivery
        defer { active = nil }
        try await withCheckedThrowingContinuation { continuation in
            delivery.continuation = continuation
            let context = Unmanaged.passUnretained(delivery).toOpaque()
            delivery.pidTap = CGEvent.tapCreateForPid(pid:pid,place:.tailAppendEventTap,options:.defaultTap,eventsOfInterest:1 << CGEventType.null.rawValue,callback:{ _,type,event,context in
                MainActor.assumeIsolated {
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let d = Unmanaged<Delivery>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = d.pidTap { CGEvent.tapEnable(tap:tap,enable:true) }; return Unmanaged.passUnretained(event)
                    }
                    guard event.getIntegerValueField(.eventSourceUserData) == d.token else { return Unmanaged.passUnretained(event) }
                    if let tap = d.pidTap { CGEvent.tapEnable(tap:tap,enable:false) }
                    d.packet.post(tap:.cgSessionEventTap)
                    return nil
                }
            },userInfo:context)
            delivery.sessionTap = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.tailAppendEventTap,options:.listenOnly,eventsOfInterest:1 << packet.type.rawValue,callback:{ _,type,event,context in
                MainActor.assumeIsolated {
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let d = Unmanaged<Delivery>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = d.sessionTap { CGEvent.tapEnable(tap:tap,enable:true) }; return Unmanaged.passUnretained(event)
                    }
                    guard event.getIntegerValueField(.eventSourceUserData) == d.token,
                          event.getIntegerValueField(ItemTransport.windowField) == d.packet.getIntegerValueField(ItemTransport.windowField) else { return Unmanaged.passUnretained(event) }
                    if let tap = d.sessionTap { CGEvent.tapEnable(tap:tap,enable:false) }
                    d.packet.postToPid(d.pid)
                    // コールバック終了後にタップと参照を解放する。
                    DispatchQueue.main.async { d.finish() }
                    return Unmanaged.passUnretained(event)
                }
            },userInfo:context)
            guard let pidTap = delivery.pidTap, let sessionTap = delivery.sessionTap else {
                delivery.finish(SwitchFailure(message:"移動用のイベントタップを作成できません。アクセシビリティの許可を確認してください。")); return
            }
            for tap in [pidTap,sessionTap] {
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)!
                delivery.sources.append(source); CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
                CGEvent.tapEnable(tap:tap,enable:true)
            }
            let timer = Timer(timeInterval:0.25,repeats:false) { _ in
                MainActor.assumeIsolated { delivery.finish(SwitchFailure(message:"移動イベントの到達を確認できませんでした")) }
            }
            delivery.timer = timer; RunLoop.main.add(timer,forMode:.common)
            guard let null = CGEvent(source:nil) else { delivery.finish(SwitchFailure(message:"配送確認イベントを作成できません")); return }
            null.setIntegerValueField(.eventSourceUserData,value:delivery.token)
            null.postToPid(pid)
        }
    }
}
