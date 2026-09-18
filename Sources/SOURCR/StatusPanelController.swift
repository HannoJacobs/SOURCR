import AppKit
import SwiftUI

/// Menu-bar anchored panel. Right edge stays fixed; diff grows/shrinks to the left.
///
/// Two window modes:
/// - **anchored** — hangs off the status item (optionally pinned to skip auto-dismiss)
/// - **detached** — torn off by dragging the header; a free-floating window that
///   hovers above every other app and keeps its own position across hide/show.
///
/// Both modes share the same geometry rule (fixed right edge + fixed top, expanding
/// leftward), so switching between them never makes the content jump sideways.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private static let detachedMaxXKey = "sourcr.panelDetachedMaxX"
    private static let detachedTopYKey = "sourcr.panelDetachedTopY"

    /// How far the header must travel before an anchored panel tears off the menu bar.
    /// Small enough to feel immediate, large enough that a sloppy click never detaches.
    private static let detachThreshold: CGFloat = 8

    /// Keep at least this much of the window on screen while dragging.
    private static let onScreenMarginX: CGFloat = 120
    private static let onScreenMarginY: CGFloat = 80

    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var globalClickMonitor: Any?
    private var pendingPanelResize: Task<Void, Never>?
    private var panelResizeGeneration = 0

    /// Captured when the panel opens; reused for every Diff↔Actions / height resize
    /// so we never re-resolve against `NSScreen.main` (focus screen ≠ menu-bar screen).
    private var anchoredMaxX: CGFloat?
    private var anchoredTopY: CGFloat?
    private var anchoredVisibleFrame: NSRect?

    /// Right edge + top of the free-floating window, persisted across launches.
    private var detachedMaxX: CGFloat?
    private var detachedTopY: CGFloat?

    /// Geometry captured at mouse-down so a drag tracks the cursor 1:1.
    private var dragStartMaxX: CGFloat?
    private var dragStartTopY: CGFloat?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        loadDetachedPosition()
        appState.onPanelPinnedChanged = { [weak self] pinned in
            self?.handlePinChanged(pinned)
        }
        appState.onPanelDetachChanged = { [weak self] detached in
            self?.handleDetachChanged(detached)
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
        guard let panel else { return }

        if appState.isPanelDetached {
            // Seed a first-run position if the app was launched already detached.
            if detachedMaxX == nil || detachedTopY == nil {
                captureAnchorFromStatusItem()
                detachedMaxX = anchoredMaxX
                detachedTopY = anchoredTopY
            }
        } else {
            captureAnchorFromStatusItem()
        }

        applyWindowMode()
        applyFrame()
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
        appState.isPanelVisible = true
        // Opening / bringing the panel forward: refresh Diff + Actions immediately
        // so statuses, timers and branch divergence are never left on a stale snapshot.
        appState.refreshVisibleSurfaces(forceDiff: true, forceBranches: true)
        AppDiagnostics.info(
            .lifecycle,
            "panel shown expanded=\(appState.isExpanded) pinned=\(appState.isPanelPinned) detached=\(appState.isPanelDetached)"
        )
    }

    func hide() {
        pendingPanelResize?.cancel()
        pendingPanelResize = nil
        panelResizeGeneration += 1
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        // Detached position survives hide/show; the menu-bar anchor is re-read on open.
        clearAnchor()
        appState.isPanelVisible = false
        AppDiagnostics.info(.lifecycle, "panel hidden")
    }

    /// Keep the right edge fixed when diff expands/collapses / Diff↔Actions height changes.
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
            // Do not re-capture the anchor here — mode switches / body-height
            // updates must keep the open-time status-item screen, not jump to
            // whichever display currently owns keyboard focus (`NSScreen.main`).
            if !self.appState.isPanelDetached,
               self.anchoredMaxX == nil || self.anchoredTopY == nil || self.anchoredVisibleFrame == nil {
                self.captureAnchorFromStatusItem()
            }
            self.applyFrame()
        }
    }

    // MARK: - Dragging / detaching

    /// Header mouse-down: remember where the window's fixed corner was.
    func beginPanelDrag() {
        guard let panel else { return }
        dragStartMaxX = panel.frame.maxX
        dragStartTopY = panel.frame.maxY
    }

    /// Header drag: detach past the threshold, then follow the cursor 1:1.
    func updatePanelDrag(translation: CGSize) {
        guard let panel, let startMaxX = dragStartMaxX, let startTopY = dragStartTopY else { return }

        if !appState.isPanelDetached {
            guard hypot(translation.width, translation.height) > Self.detachThreshold else { return }
            // Tear off exactly where the panel already sits, so the window does not
            // jump under the cursor at the moment of detaching.
            detachedMaxX = startMaxX
            detachedTopY = startTopY
            appState.isPanelDetached = true
        }

        let visible = screenVisibleFrame(containing: NSEvent.mouseLocation)
        let width = panel.frame.width
        let height = panel.frame.height

        var maxX = startMaxX + translation.width
        var topY = startTopY + translation.height

        maxX = min(max(maxX, visible.minX + Self.onScreenMarginX), visible.maxX + width - Self.onScreenMarginX)
        topY = min(max(topY, visible.minY + Self.onScreenMarginY), visible.maxY)

        detachedMaxX = maxX
        detachedTopY = topY
        panel.setFrameOrigin(NSPoint(x: maxX - width, y: topY - height))
    }

    func endPanelDrag() {
        dragStartMaxX = nil
        dragStartTopY = nil
        saveDetachedPosition()
    }

    /// Double-click on the header: detach, or snap back to the menu bar.
    func togglePanelDetached() {
        appState.togglePanelDetached()
    }

    private func handleDetachChanged(_ detached: Bool) {
        if detached, detachedMaxX == nil || detachedTopY == nil, let panel {
            detachedMaxX = panel.frame.maxX
            detachedTopY = panel.frame.maxY
        }
        if !detached {
            captureAnchorFromStatusItem()
        }
        saveDetachedPosition()
        applyWindowMode()
        applyFrame()
        if isVisible {
            panel?.orderFrontRegardless()
        }
        AppDiagnostics.info(
            .lifecycle,
            detached ? "panel detached; free-floating above other apps" : "panel reattached to the menu bar"
        )
    }

    /// Level, collection behaviour and auto-dismiss eligibility for the current mode.
    private func applyWindowMode() {
        guard let panel else { return }
        if appState.isPanelDetached {
            panel.level = .floating
            // `.transient` would hide the window in Mission Control — wrong for a
            // window the user deliberately parked on top of their work.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.level = appState.isPanelPinned ? .floating : .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        }
    }

    private func loadDetachedPosition() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.detachedMaxXKey) != nil,
              defaults.object(forKey: Self.detachedTopYKey) != nil
        else { return }
        detachedMaxX = CGFloat(defaults.double(forKey: Self.detachedMaxXKey))
        detachedTopY = CGFloat(defaults.double(forKey: Self.detachedTopYKey))
    }

    private func saveDetachedPosition() {
        guard let detachedMaxX, let detachedTopY else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(detachedMaxX), forKey: Self.detachedMaxXKey)
        defaults.set(Double(detachedTopY), forKey: Self.detachedTopYKey)
    }

    // MARK: - Geometry

    private func clearAnchor() {
        anchoredMaxX = nil
        anchoredTopY = nil
        anchoredVisibleFrame = nil
    }

    /// Pin geometry to the status-item's display for the whole open session.
    private func captureAnchorFromStatusItem() {
        if let button = statusItem?.button, let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            anchoredMaxX = screenRect.midX + SOURCRLayout.scmWidth / 2
            anchoredTopY = screenRect.minY - 4
            // Prefer the button window's screen; fall back to the screen that
            // contains the icon. Never use `NSScreen.main` (focus screen).
            let screen = window.screen
                ?? NSScreen.screens.first(where: { $0.frame.intersects(screenRect) })
                ?? NSScreen.screens.first
            anchoredVisibleFrame = screen?.visibleFrame
            return
        }

        // Menu bar lives on screens[0], not necessarily `NSScreen.main`.
        let screen = NSScreen.screens.first
        anchoredVisibleFrame = screen?.visibleFrame
        anchoredMaxX = (screen?.visibleFrame.maxX ?? 800) - 16
        anchoredTopY = (screen?.visibleFrame.maxY ?? 800) - 8
    }

    /// Visible frame of the screen under `point`, falling back to the menu-bar screen.
    private func screenVisibleFrame(containing point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func applyFrame() {
        guard let panel else { return }
        let width = appState.isExpanded ? SOURCRLayout.expandedWidth : SOURCRLayout.scmWidth
        var height = appState.panelHeight

        let detached = appState.isPanelDetached
        let maxX = (detached ? detachedMaxX : anchoredMaxX) ?? 800
        let topY = (detached ? detachedTopY : anchoredTopY) ?? 800
        let visible: NSRect? = detached
            ? screenVisibleFrame(containing: NSPoint(x: maxX - 1, y: topY - 1))
            : anchoredVisibleFrame

        if let visible {
            // Never taller than the visible display under the menu bar.
            height = min(height, max(SOURCRLayout.minPanelHeight, visible.height - 16))
        }

        var origin = NSPoint(x: maxX - width, y: topY - height)

        if let visible {
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

    private func buildPanel() {
        let root = MenuBarView(
            onClose: { [weak self] in
                self?.hide()
            },
            dragActions: PanelDragActions(
                began: { [weak self] in self?.beginPanelDrag() },
                changed: { [weak self] translation in self?.updatePanelDrag(translation: translation) },
                ended: { [weak self] in self?.endPanelDrag() }
            )
        )
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
        // Dragging is driven by the header handle so clicks on rows never move the window.
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        p.delegate = self

        self.hostingView = hosting
        self.panel = p
        applyWindowMode()
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
        // Detached already floats and never auto-dismisses; pin is inert there.
        guard !appState.isPanelDetached else { return }
        applyWindowMode()
        if pinned {
            panel?.orderFrontRegardless()
            AppDiagnostics.info(.lifecycle, "panel pinned; auto-dismiss disabled")
        } else {
            AppDiagnostics.info(.lifecycle, "panel unpinned; auto-dismiss re-enabled")
            // If they unpinned after switching away, close like a normal menu-bar item.
            if NSApp.isActive == false {
                hide()
            }
        }
    }

    private func dismissIfClickOutside() {
        guard isVisible, let panel else { return }
        if appState.isPanelPinned || appState.isPanelDetached { return }

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
