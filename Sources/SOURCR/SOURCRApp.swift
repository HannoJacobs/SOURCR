import AppKit
import SwiftUI

@main
struct SOURCRApp: App {
    @NSApplicationDelegateAdaptor(SOURCRAppDelegate.self) private var appDelegate

    var body: some Scene {
        // No MenuBarExtra — status item + floating panel are owned by the AppDelegate.
        // Settings scene keeps the SwiftUI app lifecycle alive for an LSUIElement app.
        Settings {
            EmptyView()
        }
    }
}
