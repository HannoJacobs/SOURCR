import AppKit

final class SOURCRAppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var panelController: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay a menu-bar app by default; temporarily flipped to .regular only
        // while presenting NSOpenPanel (see AppState.presentOpenPanel).
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        let controller = StatusPanelController(appState: state)
        controller.install()
        self.appState = state
        self.panelController = controller

        // Expose close + resize hooks for SwiftUI.
        state.onPanelClose = { [weak controller] in
            controller?.hide()
        }
        state.onPanelLayoutChange = { [weak controller] in
            controller?.syncPanelSize()
        }

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
        panelController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.info(.lifecycle, "applicationWillTerminate")
    }
}
