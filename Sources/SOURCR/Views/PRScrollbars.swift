import AppKit
import SwiftUI

/// Attach inside scroll content so the policy affects only this enclosing pane.
struct PRScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> PRScrollbarPolicyView { PRScrollbarPolicyView() }
    func updateNSView(_ view: PRScrollbarPolicyView, context: Context) { view.scheduleUpdate() }

    @MainActor static func configure(_ scroll: NSScrollView) {
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.tile()
    }
}

final class PRScrollbarPolicyView: NSView {
    private var updatePending = false
    private weak var configuredScroll: NSScrollView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }

    @objc private func styleChanged() { scheduleUpdate() }

    func scheduleUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            guard let scroll = self.enclosingScrollView else { return }
            if scroll.scrollerStyle != .legacy || scroll.autohidesScrollers ||
                !scroll.hasVerticalScroller || scroll.hasHorizontalScroller {
                PRScrollbars.configure(scroll)
            }
            if self.configuredScroll !== scroll {
                self.configuredScroll = scroll
                AppDiagnostics.info(.appState, "PR scrollbar configured style=legacy autohide=false reservedGutter=true")
            }
        }
    }
}
