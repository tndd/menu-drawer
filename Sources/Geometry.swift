import Foundation
import CoreGraphics

enum DrawerGeometry {
    static func panel(anchor: CGRect, visible: CGRect, size: CGSize) -> CGRect {
        CGRect(x: max(visible.minX, min(anchor.maxX - size.width, visible.maxX - size.width)),
               y: max(visible.minY, anchor.minY - size.height - 6), width: size.width, height: size.height)
    }
    static func containsItem(_ item: CGRect, divider: CGRect) -> Bool {
        item.width > 0 && item.width < 300 && abs(item.midY - divider.midY) < 5 && item.maxX <= divider.maxX + 1
    }
}
