import AppKit

final class SOURCRAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDiagnostics.info(
            .lifecycle,
            "applicationDidFinishLaunching \(AppDiagnostics.runtimeSummary)"
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppDiagnostics.info(.lifecycle, "applicationDidBecomeActive")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppDiagnostics.info(.lifecycle, "applicationShouldHandleReopen hasVisibleWindows=\(flag)")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.info(.lifecycle, "applicationWillTerminate")
    }
}
