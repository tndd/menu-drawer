import Cocoa

// B案の引き出しを18ptのテンプレート画像に簡略化。明暗はmacOSに任せる。
enum Brand {
    static func menuIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 2.5, y: 8))
            back.line(to: NSPoint(x: 3.5, y: 14))
            back.curve(to: NSPoint(x: 5.5, y: 16), controlPoint1: NSPoint(x: 3.7, y: 15.5), controlPoint2: NSPoint(x: 4.2, y: 16))
            back.line(to: NSPoint(x: 12.5, y: 16))
            back.curve(to: NSPoint(x: 14.5, y: 14), controlPoint1: NSPoint(x: 13.8, y: 16), controlPoint2: NSPoint(x: 14.3, y: 15.5))
            back.line(to: NSPoint(x: 15.5, y: 8))
            back.lineWidth = 1.3
            back.lineJoinStyle = .round
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2, width: 15, height: 8), xRadius: 2, yRadius: 2)
            front.lineWidth = 1.3
            front.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 6.5, y: 6))
            handle.line(to: NSPoint(x: 11.5, y: 6))
            handle.lineWidth = 1.3
            handle.lineCapStyle = .round
            handle.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "収納したアイコン"
        return image
    }
}
