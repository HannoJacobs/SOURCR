import AppKit
import SwiftUI

/// Drag callbacks the panel controller hands down to the SwiftUI header.
struct PanelDragActions {
    var began: () -> Void = {}
    /// Screen-space translation since mouse-down (y up, matching `NSWindow` origin).
    var changed: (CGSize) -> Void = { _ in }
    var ended: () -> Void = {}
}

/// Invisible AppKit drag surface for the panel header.
///
/// AppKit rather than a SwiftUI `DragGesture` on purpose: the panel is a
/// `.nonactivatingPanel`, so the drag has to work without the app ever becoming
/// active, and the window must track the cursor 1:1 in screen coordinates with no
/// gesture-recognizer latency and no flipped-coordinate conversion. Placed behind
/// the header controls — SwiftUI buttons in front keep their own clicks, and a drag
/// anywhere on the empty header space moves the window.
struct PanelDragHandle: NSViewRepresentable {
    let onBegan: () -> Void
    /// Screen-space translation since mouse-down (y up, matching `NSWindow` origin).
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void
    /// Double-click toggles detach/reattach, the way a title bar zooms.
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PanelDragHandleView {
        let view = PanelDragHandleView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PanelDragHandleView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: PanelDragHandleView) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onDoubleClick = onDoubleClick
    }
}

final class PanelDragHandleView: NSView {
    var onBegan: (() -> Void)?
    var onChanged: ((CGSize) -> Void)?
    var onEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    /// Cursor position at mouse-down, in screen space. `nil` when not dragging.
    private var dragAnchor: NSPoint?

    /// An `NSViewRepresentable` with no intrinsic size is greedy in BOTH axes. Without
    /// this the header row absorbed every spare point of height when the detail pane
    /// made the window taller, stranding the list in the middle of a blank band.
    /// Flexible across, fixed down.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: PanelDragHandleView.handleHeight)
    }

    static let handleHeight: CGFloat = 26

    /// The panel never takes key focus, so the first click must still count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragAnchor = nil
            onDoubleClick?()
            return
        }
        dragAnchor = NSEvent.mouseLocation
        onBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor else { return }
        let current = NSEvent.mouseLocation
        onChanged?(
            CGSize(
                width: current.x - dragAnchor.x,
                height: current.y - dragAnchor.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        onEnded?()
    }
}
