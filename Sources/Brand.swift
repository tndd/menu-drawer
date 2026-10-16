import Cocoa

enum Brand {
    static func menuIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // 左の中抜きと右の塗りで、表示側と収納側の二領域を表す。
            NSColor.black.setFill()
            let visible = NSBezierPath(roundedRect: NSRect(x: 2, y: 1.5, width: 5.5, height: 15), xRadius: 1.7, yRadius: 1.7)
            visible.append(NSBezierPath(roundedRect: NSRect(x: 3.5, y: 3, width: 2.5, height: 12), xRadius: 0.6, yRadius: 0.6))
            visible.windingRule = .evenOdd
            visible.fill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 1.5, width: 5.5, height: 15), xRadius: 1.7, yRadius: 1.7).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "アイコン収納"
        return image
    }
}
