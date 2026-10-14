import Foundation
import CoreGraphics
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let screen = CGRect(x: 0, y: 0, width: 1470, height: 919)
let panel = DrawerGeometry.panel(anchor: CGRect(x: 1100, y: 919, width: 28, height: 37), visible: screen, size: CGSize(width: 276, height: 192))
expect(panel.maxY < 919, "パネルはメニューバーとノッチより下")
expect(screen.contains(panel), "通常のパネルが画面内に収まる")
let left = DrawerGeometry.panel(anchor: CGRect(x: 10, y: 919, width: 28, height: 37), visible: screen, size: CGSize(width: 276, height: 432))
expect(left.minX == 0, "左端では画面外にはみ出さない")
let second = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
let other = DrawerGeometry.panel(anchor: CGRect(x: -80, y: 960, width: 28, height: 24), visible: second, size: CGSize(width: 276, height: 432))
expect(second.contains(other), "負の座標の外部画面でも収まる")
let divider = CGRect(x: -9000, y: 0, width: 10000, height: 37)
expect(DrawerGeometry.containsItem(CGRect(x: 0, y: 0, width: 38, height: 37), divider: divider), "収納した項目を含む")
expect(!DrawerGeometry.containsItem(CGRect(x: 1050, y: 0, width: 38, height: 37), divider: divider), "右側の常時表示項目を除外")
expect(!DrawerGeometry.containsItem(CGRect(x: 20, y: 600, width: 224, height: 224), divider: divider), "同じレイヤーの別ウィンドウを除外")
expect(!DrawerGeometry.containsItem(CGRect(x: 20, y: -1080, width: 38, height: 24), divider: divider), "別の高さの画面を除外")
print("配置・収納境界の8検証に成功")
