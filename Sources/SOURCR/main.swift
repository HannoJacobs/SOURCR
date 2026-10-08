import AppKit

// Plain AppKit entry point. A SwiftUI `App` must declare a scene, and the empty
// `Settings` scene that satisfies it surfaces as a blank "SOURCR Settings" window
// whenever the app is reopened. The menu-bar panel is the only window, so there is
// no scene at all.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = SOURCRAppDelegate()
    app.delegate = delegate
    app.mainMenu = makeMainMenu()
    withExtendedLifetime(delegate) {
        app.run()
    }
}

/// Key equivalents (⌘C, ⌘V, ⌘X, ⌘Z, ⌘A, ⌘Q) are dispatched through the main menu.
/// The menu bar of a menu-bar-only app is never shown, but text in the panel still
/// needs these shortcuts, which the SwiftUI lifecycle used to supply.
@MainActor
private func makeMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit SOURCR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        .keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    return mainMenu
}
