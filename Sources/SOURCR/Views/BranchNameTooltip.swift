import AppKit
import SwiftUI

/// AppKit tracking keeps branch help available while another app has focus.
struct BranchNameTooltip: NSViewRepresentable {
    let text: String
    let onClick: () -> Void

    func makeNSView(context: Context) -> BranchNameTooltipView {
        let view = BranchNameTooltipView()
        view.clipsToBounds = true
        view.isEditable = false
        view.isSelectable = false
        view.isBordered = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 12, weight: .medium)
        view.lineBreakMode = .byTruncatingTail
        view.maximumNumberOfLines = 1
        view.cell?.usesSingleLineMode = true
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BranchNameTooltipView, context: Context) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        return CGSize(width: min(proposal.width ?? ideal.width, ideal.width), height: ideal.height)
    }

    func updateNSView(_ view: BranchNameTooltipView, context: Context) {
        view.onClick = onClick
        if view.stringValue != text {
            view.dismiss()
            view.stringValue = text
        }
    }

    static func dismantleNSView(_ view: BranchNameTooltipView, coordinator: ()) {
        view.dismiss()
    }
}

final class BranchNameTooltipView: NSTextField {
    static let delay: TimeInterval = 1
    var onClick: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    private var timer: Timer?
    private var tooltip: NSPanel?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { dismiss() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        dismiss()
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTooltip() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func mouseExited(with event: NSEvent) { dismiss() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismiss()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        if let tooltip {
            tooltip.parent?.removeChildWindow(tooltip)
            tooltip.orderOut(nil)
        }
        tooltip = nil
    }

    private func showTooltip() {
        timer = nil
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
              !stringValue.isEmpty,
              visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        else { return }

        let label = NSTextField(wrappingLabelWithString: stringValue)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        let screen = window.screen?.visibleFrame ?? window.frame
        let width = min(label.intrinsicContentSize.width, min(600, screen.width - 32))
        let height = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = NSRect(x: 8, y: 5, width: width, height: height)
        let size = NSSize(width: width + 16, height: height + 10)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let x = min(max(anchor.minX, screen.minX + 8), screen.maxX - size.width - 8)
        let below = anchor.minY - size.height - 4
        let y = below >= screen.minY + 8 ? below : anchor.maxY + 4
        let panel = NSPanel(
            contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView?.addSubview(label)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        tooltip = panel
        AppDiagnostics.debug(.lifecycle, "branch tooltip shown after \(Self.delay)s key=\(window.isKeyWindow) active=\(NSApp.isActive)")
    }
}
