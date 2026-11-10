import AppKit
import SwiftUI

/// Read actual AppKit row frames when the clip view scrolls, including scroller
/// and accessibility scrolling that doesn't always update SwiftUI's ID binding.
@MainActor
final class PRDiffScrollTracker: NSObject {
    var onVisibleFile: ((String) -> Void)?
    private let markers = NSHashTable<PRDiffRowMarkerView>.weakObjects()
    private weak var scrollView: NSScrollView?
    weak var viewport: NSView?
    private var updatePending = false
    private var isActive = true

    func register(_ marker: PRDiffRowMarkerView) {
        markers.add(marker)
        scheduleUpdate()
    }

    func stop() {
        isActive = false
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
    }

    func start() { isActive = true; scheduleUpdate() }

    func scheduleUpdate() {
        guard isActive, !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            guard self.isActive else { return }
            self.updateVisibleFile()
        }
    }

    @objc private func scrolled(_ notification: Notification) { scheduleUpdate() }

    func updateVisibleFile() {
        let rows = markers.allObjects
        let scroll = rows.compactMap(\.enclosingScrollView).first
        if let scroll, scrollView !== scroll {
            NotificationCenter.default.removeObserver(self)
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                name: NSView.frameDidChangeNotification, object: scroll.contentView)
        }
        guard let coordinateView = viewport ?? scroll?.documentView else { return }
        let visible = viewport?.bounds ?? scroll!.documentVisibleRect
        let top = rows.compactMap { marker -> (String, NSRect)? in
            guard marker.superview != nil, !marker.isHiddenOrHasHiddenAncestor else { return nil }
            if viewport == nil, marker.enclosingScrollView !== scroll { return nil }
            guard marker.window === coordinateView.window else { return nil }
            let frame = marker.convert(marker.bounds, to: coordinateView)
            guard frame.width > 0, frame.height > 0, frame.intersects(visible) else { return nil }
            return (marker.path, frame)
        }.min {
            coordinateView.isFlipped ? $0.1.minY < $1.1.minY : $0.1.maxY > $1.1.maxY
        }
        if let top { onVisibleFile?(top.0) }
    }
}

struct PRDiffViewportMarker: NSViewRepresentable {
    let tracker: PRDiffScrollTracker
    func makeNSView(context: Context) -> PRDiffRowMarkerView {
        let view = PRDiffRowMarkerView()
        view.tracker = tracker
        tracker.viewport = view
        return view
    }
    func updateNSView(_ view: PRDiffRowMarkerView, context: Context) { tracker.scheduleUpdate() }
}

struct PRDiffScrollObservation: ViewModifier {
    let tracker: PRDiffScrollTracker
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, _ in
                tracker.scheduleUpdate()
            }
        } else {
            content
        }
    }
}

struct PRDiffRowMarker: NSViewRepresentable {
    let path: String
    let tracker: PRDiffScrollTracker

    func makeNSView(context: Context) -> PRDiffRowMarkerView {
        let view = PRDiffRowMarkerView()
        view.path = path
        view.tracker = tracker
        tracker.register(view)
        return view
    }

    func updateNSView(_ view: PRDiffRowMarkerView, context: Context) {
        view.path = path
        tracker.scheduleUpdate()
    }
}

final class PRDiffRowMarkerView: NSView {
    var path = ""
    weak var tracker: PRDiffScrollTracker?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); tracker?.scheduleUpdate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tracker?.scheduleUpdate() }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { tracker?.scheduleUpdate() }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { tracker?.scheduleUpdate() }
    }
}
