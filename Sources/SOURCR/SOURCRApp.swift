import SwiftUI

@main
struct SOURCRApp: App {
    @NSApplicationDelegateAdaptor(SOURCRAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("SOURCR", systemImage: appState.menuBarIcon) {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
