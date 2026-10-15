import Cocoa

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let name = Bundle.main.object(forInfoDictionaryKey: "FixtureStatusName") as! String
        // 初回だけ標準の保存値を準備し、復元自体はAppKitへ任せる。
        if UserDefaults.standard.object(forKey: "NSStatusItem Visible \(name)") == nil {
            UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(name)")
        }
        item = NSStatusBar.system.statusItem(withLength: 24)
        item.behavior = [.removalAllowed]
        item.autosaveName = name
        item.button?.title = Bundle.main.object(forInfoDictionaryKey: "FixtureLabel") as? String ?? "T"
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = FixtureDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
