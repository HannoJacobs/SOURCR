import CoreGraphics

enum SOURCRLayout {
    static let scmWidth: CGFloat = 320
    static let expandedWidth: CGFloat = 1080
    static let panelHeight: CGFloat = 560

    static var diffWidth: CGFloat { expandedWidth - scmWidth }
}
