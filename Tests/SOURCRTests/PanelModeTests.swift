import Testing
@testable import SOURCR

struct PanelModeTests {
    @Test func combinedNavigationAndSavedModeMigration() {
        #expect(PanelMode.allCases == [.branches, .diff])
        #expect(PanelMode.restored(from: "actions") == .branches)
        #expect(PanelMode.restored(from: "branches") == .branches)
        #expect(PanelMode.restored(from: "diff") == .diff)
        #expect(PanelMode.restored(from: "unknown") == nil)
    }
}
