import CoreGraphics
import SwiftUI

enum SOURCRLayout {
    static let scmWidth: CGFloat = 320
    static let expandedWidth: CGFloat = 1080

    /// Smallest usable panel (header + short body + footer).
    static let minPanelHeight: CGFloat = 160
    /// Cap so a huge file/run list scrolls instead of covering the display.
    static let maxPanelHeight: CGFloat = 560
    /// When Diff/Actions detail is open, keep enough height to read the left pane.
    static let minExpandedPanelHeight: CGFloat = 420
    /// Empty-list placeholder body height.
    static let emptyBodyHeight: CGFloat = 160

    /// Header + dividers + Quit footer (kept in sync with MenuBarView chrome).
    static let chromeHeight: CGFloat = 72

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
