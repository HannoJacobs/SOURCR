import AppKit
import SwiftUI

/// A weak reference to the native view behind a PR badge, for AppKit's pointer.
struct PRBadgeAnchor: NSViewRepresentable {
    final class Reference { weak var view: NSView? }
    let reference: Reference

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        reference.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { reference.view = view }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
final class PRPopoverController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let popover = NSPopover()
    private var presentedURL: String?
    private var resizeStart: CGSize?

    init(state: AppState) {
        self.state = state
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let actions = PanelDragActions(
            began: { [weak self] in self?.resizeStart = self?.popover.contentSize },
            changed: { [weak self] delta in
                guard let self, let start = self.resizeStart else { return }
                self.state.resizePR(to: CGSize(
                    width: start.width + (self.state.pullRequestOpensRight ? delta.width : -delta.width),
                    height: start.height - delta.height))
            },
            ended: { [weak self] in self?.resizeStart = nil }
        )
        popover.contentViewController = NSHostingController(rootView:
            PullRequestDetailPane(resizeActions: actions).environment(state))
    }

    func sync(mainPanel: NSPanel) {
        guard let pr = state.selectedPullRequest, mainPanel.isVisible,
              let anchor = state.pullRequestAnchorView, anchor.window === mainPanel,
              let content = mainPanel.contentView else {
            popover.close()
            return
        }
        if presentedURL != pr.url { popover.close() }
        let visible = mainPanel.screen?.visibleFrame ?? mainPanel.frame
        let onRight = DetailPaneSide.resolve(columnMinX: mainPanel.frame.minX,
                                            columnMaxX: mainPanel.frame.maxX, visibleFrame: visible) == .right
        state.pullRequestOpensRight = onRight
        let availableWidth = onRight ? visible.maxX - mainPanel.frame.maxX : mainPanel.frame.minX - visible.minX
        let size = PRPanelSizing.fit(requested: state.requestedPRSize,
                                     available: CGSize(width: availableWidth - 28, height: visible.height - 32))
        popover.contentSize = size
        // Span the main panel horizontally, but use the clicked badge's row height.
        // This puts the arrow at that row without covering the branch list on the left.
        let row = anchor.convert(anchor.bounds, to: content)
        let target = NSRect(x: content.bounds.minX, y: row.minY,
                            width: content.bounds.width, height: row.height)
        presentedURL = pr.url
        popover.show(relativeTo: target, of: content, preferredEdge: onRight ? .maxX : .minX)
        state.displayedPRSize = popover.contentSize
        AppDiagnostics.info(.lifecycle, "PR popover shown number=\(pr.number) side=\(onRight ? "right" : "left") width=\(Int(size.width)) height=\(Int(size.height)) mainWidth=\(Int(mainPanel.frame.width))")
    }

    func close() { popover.close() }

    func popoverDidClose(_ notification: Notification) {
        guard let presentedURL, state.selectedPullRequest?.url == presentedURL else { return }
        state.clearActionSelection()
        AppDiagnostics.info(.appState, "PR popover dismissed")
    }
}
