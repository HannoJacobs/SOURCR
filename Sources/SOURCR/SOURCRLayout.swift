import CoreGraphics
import SwiftUI

enum SOURCRLayout {
    static let scmWidth: CGFloat = 320
    static let expandedWidth: CGFloat = 1080

    /// Smallest usable panel (header + short body).
    static let minPanelHeight: CGFloat = 160
    /// Cap so a huge file/run list scrolls instead of covering the display.
    static let maxPanelHeight: CGFloat = 560
    /// When Diff/Actions detail is open, keep enough height to read the left pane.
    static let minExpandedPanelHeight: CGFloat = 420
    /// Empty-list placeholder body height.
    static let emptyBodyHeight: CGFloat = 160

    /// Header bar + its divider (kept in sync with MenuBarView chrome).
    static let chromeHeight: CGFloat = 40

    static var maxBodyHeight: CGFloat { maxPanelHeight - chromeHeight }

    static var diffWidth: CGFloat { expandedWidth - scmWidth }
}

/// Ideal height of the scrollable body (repo list / settings form), not the viewport.
struct SCMBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Sizes the SCM/Actions scroll body to its content (capped), or fills when the
/// detail pane forces a taller panel.
struct SCMBodyHeightFrame: ViewModifier {
    let measured: CGFloat
    let fill: Bool

    func body(content: Content) -> some View {
        if fill {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            content.frame(height: displayHeight, alignment: .top)
        }
    }

    private var displayHeight: CGFloat {
        let intrinsic = measured > 1 ? measured : 80
        return min(intrinsic, SOURCRLayout.maxBodyHeight)
    }
}

/// Where a detached panel's fixed corner (right edge + top) may sit, given the
/// displays that are connected *right now*.
///
/// A saved position is just screen coordinates: after a monitor is unplugged it can
/// point at a display that no longer exists, leaving the window invisible and
/// unreachable. Every placement goes through here so the corner always lands on a
/// live display, with at least a collapsed panel's footprint visible on it.
enum DetachedPlacement {
    static let edgeInset: CGFloat = 8

    struct Result: Equatable {
        var maxX: CGFloat
        var topY: CGFloat
        /// Visible frame of the display the panel was placed on.
        var visibleFrame: CGRect
    }

    /// `visibleFrames` are the connected screens' visible frames, menu-bar screen first.
    /// Returns nil only when no display is connected at all.
    static func resolve(maxX: CGFloat, topY: CGFloat, visibleFrames: [CGRect]) -> Result? {
        let corner = CGPoint(x: maxX - 1, y: topY - 1)
        // The display under the corner, else the nearest one (the unplugged monitor's
        // neighbour), so a rescue lands next to where the panel used to be.
        guard let visible = visibleFrames.first(where: { $0.contains(corner) })
            ?? visibleFrames.min(by: { distance(from: corner, to: $0) < distance(from: corner, to: $1) })
        else { return nil }

        let minMaxX = visible.minX + SOURCRLayout.scmWidth + edgeInset
        let maxMaxX = visible.maxX - edgeInset
        let minTopY = visible.minY + SOURCRLayout.minPanelHeight + edgeInset
        let maxTopY = visible.maxY

        return Result(
            maxX: min(max(maxX, minMaxX), max(minMaxX, maxMaxX)),
            topY: min(max(topY, minTopY), max(minTopY, maxTopY)),
            visibleFrame: visible
        )
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
