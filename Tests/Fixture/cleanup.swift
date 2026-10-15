import Cocoa
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
let fixtures = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.deletingLastPathComponent().standardizedFileURL == root }
for app in fixtures { _ = app.terminate() }
let deadline = Date().addingTimeInterval(3)
while fixtures.contains(where: { !$0.isTerminated }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
for url in urls {
    guard let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix("local.codex.MenuDrawerTest.") else { continue }
    if let keys = CFPreferencesCopyKeyList(id as CFString,kCFPreferencesCurrentUser,kCFPreferencesAnyHost) as? [String] {
        for key in keys { CFPreferencesSetAppValue(key as CFString,nil,id as CFString) }
        CFPreferencesAppSynchronize(id as CFString)
    }
}
