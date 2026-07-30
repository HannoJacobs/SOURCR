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
    private var pendingPanelResize: Task<Void, Never>?
    private var panelResizeGeneration = 0

    /// Stable screen X of the panel's right edge while visible.
    private var anchoredMaxX: CGFloat?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        appState.onPanelPinnedChanged = { [weak self] pinned in
            self?.handlePinChanged(pinned)
        }
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
        panel?.level = appState.isPanelPinned ? .floating : .statusBar
        panel?.orderFrontRegardless()
        installOutsideClickMonitor()
        appState.isPanelVisible = true
        // Opening / bringing the panel forward: refresh Diff + Actions immediately
        // so statuses and timers are never left on a stale snapshot from last open.
        appState.refreshVisibleSurfaces(forceDiff: true)
        AppDiagnostics.info(
            .lifecycle,
            "panel shown expanded=\(appState.isExpanded) pinned=\(appState.isPanelPinned)"
        )
    }

    func hide() {
        pendingPanelResize?.cancel()
        pendingPanelResize = nil
        panelResizeGeneration += 1
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        anchoredMaxX = nil
        appState.isPanelVisible = false
        AppDiagnostics.info(.lifecycle, "panel hidden")
    }

    /// Keep the right edge fixed when diff expands/collapses.
    func syncPanelSize() {
        guard isVisible else { return }
        panelResizeGeneration += 1
        let generation = panelResizeGeneration
        pendingPanelResize?.cancel()

        // `isExpanded` changes inside an Observation mutation. Resizing here
        // synchronously re-enters NSHostingView/AttributeGraph layout before that
        // mutation has settled. Coalesce requests and resize on the next actor turn.
        pendingPanelResize = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.isVisible,
                  self.panelResizeGeneration == generation
            else { return }

            self.pendingPanelResize = nil
            if self.anchoredMaxX == nil {
                self.anchoredMaxX = self.preferredAnchorMaxX()
            }
            self.applyFrame()
        }
    }

    private func applyFrame() {
        guard let panel else { return }
        let width = appState.isExpanded ? SOURCRLayout.expandedWidth : SOURCRLayout.scmWidth
        var height = appState.panelHeight
        let maxX = anchoredMaxX ?? preferredAnchorMaxX()
        let topY = preferredTopY()

        if let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            // Never taller than the visible display under the menu bar.
            height = min(height, max(SOURCRLayout.minPanelHeight, visible.height - 16))
        }

        var origin = NSPoint(x: maxX - width, y: topY - height)

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

        let targetFrame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        guard panel.frame != targetFrame else { return }

        // contentView auto-fills the window. AppKit will redraw on its normal pass;
        // forcing display here would synchronously traverse the SwiftUI hierarchy.
        panel.setFrame(targetFrame, display: false)
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

        let size = NSSize(width: SOURCRLayout.scmWidth, height: appState.panelHeight)
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
        p.level = appState.isPanelPinned ? .floating : .statusBar
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

    /// When pinned: stay hovering above other apps and skip auto-dismiss.
    /// Explicit hide via the status-item toggle still works.
    private func handlePinChanged(_ pinned: Bool) {
        guard isVisible else { return }
        if pinned {
            panel?.level = .floating
            panel?.orderFrontRegardless()
            AppDiagnostics.info(.lifecycle, "panel pinned; auto-dismiss disabled")
        } else {
            panel?.level = .statusBar
            AppDiagnostics.info(.lifecycle, "panel unpinned; auto-dismiss re-enabled")
            // If they unpinned after switching away, close like a normal menu-bar item.
            if NSApp.isActive == false {
                hide()
            }
        }
    }

    private func dismissIfClickOutside() {
        guard isVisible, let panel else { return }
        if appState.isPanelPinned { return }

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
