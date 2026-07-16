import AppKit
import SwiftUI

/// Menu-bar anchored panel. Right edge stays fixed; diff grows/shrinks to the left.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var globalClickMonitor: Any?

    /// Stable screen X of the panel's right edge while visible.
    private var anchoredMaxX: CGFloat?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "arrow.triangle.branch",
                accessibilityDescription: "SOURCR"
            )
            button.image?.isTemplate = true
            button.toolTip = "SOURCR — Source Control (read-only)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        AppDiagnostics.info(.lifecycle, "status item installed")
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        toggle()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            buildPanel()
        }
        guard panel != nil else { return }

        anchoredMaxX = preferredAnchorMaxX()
        applyFrame()
        panel?.orderFrontRegardless()
        installOutsideClickMonitor()
        appState.isPanelVisible = true
        appState.refreshAll(force: false)
        AppDiagnostics.info(.lifecycle, "panel shown expanded=\(appState.isExpanded)")
    }

    func hide() {
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        anchoredMaxX = nil
        appState.isPanelVisible = false
        AppDiagnostics.info(.lifecycle, "panel hidden")
    }

    /// Keep the right edge fixed when diff expands/collapses.
    func syncPanelSize() {
        guard isVisible else { return }
        if anchoredMaxX == nil {
            anchoredMaxX = preferredAnchorMaxX()
        }
        // Resize immediately (no animator) so SwiftUI width and window width never diverge.
        applyFrame()
    }

    private func applyFrame() {
        guard let panel else { return }
        let width = appState.isExpanded ? SOURCRLayout.expandedWidth : SOURCRLayout.scmWidth
        let size = NSSize(width: width, height: SOURCRLayout.panelHeight)
        let maxX = anchoredMaxX ?? preferredAnchorMaxX()
        let topY = preferredTopY()
        var origin = NSPoint(x: maxX - width, y: topY - SOURCRLayout.panelHeight)

        if let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + width > visible.maxX - 8 {
                origin.x = visible.maxX - width - 8
            }
            if origin.x < visible.minX + 8 {
                origin.x = visible.minX + 8
            }
            if origin.y < visible.minY + 8 {
                origin.y = visible.minY + 8
            }
        }

        // contentView auto-fills the window, so only the window frame needs setting.
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func preferredAnchorMaxX() -> CGFloat {
        if let button = statusItem?.button, let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            return screenRect.midX + SOURCRLayout.scmWidth / 2
        }
        if let screen = NSScreen.main {
            return screen.visibleFrame.maxX - 16
        }
        return 800
    }

    private func preferredTopY() -> CGFloat {
        if let button = statusItem?.button, let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            return screenRect.minY - 4
        }
        if let screen = NSScreen.main {
            return screen.visibleFrame.maxY - 8
        }
        return 800
    }

    private func buildPanel() {
        let root = MenuBarView(onClose: { [weak self] in
            self?.hide()
        })
        .environment(appState)

        let size = NSSize(width: SOURCRLayout.scmWidth, height: SOURCRLayout.panelHeight)
        // Hosting view is the contentView, so it always fills the window exactly.
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        p.delegate = self

        self.hostingView = hosting
        self.panel = p
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // Global only — local monitors were racing with in-panel file clicks.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismissIfClickOutside()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func dismissIfClickOutside() {
        guard isVisible, let panel else { return }
        let screenPoint = NSEvent.mouseLocation

        if let button = statusItem?.button, let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect).insetBy(dx: -4, dy: -4)
            if screenRect.contains(screenPoint) {
                return
            }
        }

        if !panel.frame.contains(screenPoint) {
            hide()
        }
    }
}
