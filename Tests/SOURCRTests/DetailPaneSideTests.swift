import CoreGraphics
import Testing
@testable import SOURCR

struct DetailPaneSideTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

    @Test func opensTowardsTheLargerGap() {
        // List parked near the left edge: opening leftwards would shove it right.
        #expect(DetailPaneSide.resolve(columnMinX: 40, columnMaxX: 360, visibleFrame: screen) == .right)
        // List under a right-hand menu-bar icon: room is on the left.
        #expect(DetailPaneSide.resolve(columnMinX: 1380, columnMaxX: 1700, visibleFrame: screen) == .left)
    }

    @Test func tiesAndUnknownDisplaysKeepLeftwardExpansion() {
        #expect(DetailPaneSide.resolve(columnMinX: 704, columnMaxX: 1024, visibleFrame: screen) == .left)
        #expect(DetailPaneSide.resolve(columnMinX: 40, columnMaxX: 360, visibleFrame: nil) == .left)
    }

    @Test func usesTheColumnsOwnDisplay() {
        let secondary = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        #expect(DetailPaneSide.resolve(columnMinX: 1760, columnMaxX: 2080, visibleFrame: secondary) == .right)
    }
}
