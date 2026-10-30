import Foundation
import Testing
@testable import SOURCR

struct BranchHeadTests {
    @Test func rollupRepresentsExactHeadChecks() {
        #expect(BranchCheckState.fromRollup("SUCCESS") == .clean)
        #expect(BranchCheckState.fromRollup("FAILURE") == .failed)
        #expect(BranchCheckState.fromRollup("ERROR") == .failed)
        #expect(BranchCheckState.fromRollup("PENDING") == .running)
        #expect(BranchCheckState.fromRollup("EXPECTED") == .running)
        #expect(BranchCheckState.fromRollup(nil) == nil)
        #expect(BranchCheckState.fromRollup("UNKNOWN") == nil)
    }
}
