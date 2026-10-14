import Cocoa
import ScreenCaptureKit

// ステータス項目の画像と、移動を隠す短時間のメニューバー画像だけをメモリで扱う。
// 録画・画像保存・ネット送信は行わない。
enum StatusImages {
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    static func request() {
        SCShareableContent.getWithCompletionHandler { _, _ in }
    }
    static func validationImage(_ image: CGImage, suffix: String) {
        guard let index = CommandLine.arguments.firstIndex(of: "--validation-output"), CommandLine.arguments.indices.contains(index + 1),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1] + suffix))
    }
    static func image(for entry: MenuEntry) -> NSImage? {
        guard permitted, let raw = MDWindowImage(entry.id), entry.frame.height > 0 else { return nil }
        let scale = CGFloat(raw.height) / entry.frame.height
        let height = min(CGFloat(raw.height), 22 * scale)
        let rect = CGRect(x: 0, y: (CGFloat(raw.height) - height) / 2, width: CGFloat(raw.width), height: height)
        guard let cropped = raw.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: CGFloat(cropped.width) / scale, height: height / scale))
    }
}

final class BarCover {
    private var window: NSPanel?
    private var region: CGRect?
    func show(on screen: NSScreen) {
        guard StatusImages.permitted, window == nil else { return }
        let right = screen.auxiliaryTopRightArea
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        let area = CGRect(x: right?.minX ?? screen.frame.midX, y: screen.frame.maxY - height, width: right?.width ?? screen.frame.width / 2, height: height)
        let screenID = CGDirectDisplayID((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID())
        let bounds = CGDisplayBounds(screenID)
        let rect = CGRect(x: bounds.minX + area.minX - screen.frame.minX, y: bounds.minY, width: area.width, height: area.height)
        guard let image = MDBarImage(rect) else { return }
        region = rect
        StatusImages.validationImage(image, suffix: ".frozen.png")
        let panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.hasShadow = false
        let view = NSImageView(frame: CGRect(origin: .zero, size: area.size))
        view.image = NSImage(cgImage: image, size: area.size)
        view.imageScaling = .scaleAxesIndependently
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
    }
    func recordVisibleState() {
        guard window != nil, let region, let image = MDBarImage(region) else { return }
        StatusImages.validationImage(image, suffix: ".during.png")
    }
    func hide() { window?.orderOut(nil); window = nil; region = nil }
}
