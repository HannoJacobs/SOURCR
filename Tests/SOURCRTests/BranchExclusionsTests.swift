import XCTest
@testable import SOURCR

final class BranchExclusionsTests: XCTestCase {
    func testHidePersistsForSameHeadAndReturnsAfterNewCommit() throws {
        let suite = "BranchExclusionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = GitHubRemote(owner: "owner", name: "repo")
        let other = GitHubRemote(owner: "owner", name: "other")
        func branch(_ oid: String, date: Date = .now) -> BranchInfo {
            BranchInfo(name: "feature/test", lastCommitAt: date, ahead: 1, behind: 0,
                       isDefault: false, pullRequest: nil, hasDivergence: true, headOID: oid)
        }
        var exclusions = BranchExclusions(defaults: defaults)
        exclusions.hide(branch("old"), remote: remote, defaults: defaults)
        let reloaded = BranchExclusions(defaults: defaults)
        XCTAssertTrue(reloaded.contains(branch("old"), remote: remote))
        // A new head must return even when its commit timestamp is older.
        XCTAssertFalse(reloaded.contains(branch("new", date: .distantPast), remote: remote))
        XCTAssertFalse(reloaded.contains(branch("old"), remote: other))
        XCTAssertFalse(reloaded.contains(branch(""), remote: remote))
    }
}
