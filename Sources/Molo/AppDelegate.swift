import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dock: DockController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            dock = DockController()
            dock?.start()
        }
    }

    /// Riaprire Molo dal Finder o da Spotlight apre le Impostazioni.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { dock?.showSettings() }
        return false
    }
}
