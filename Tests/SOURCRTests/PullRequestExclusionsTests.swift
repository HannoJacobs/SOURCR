import XCTest
@testable import SOURCR

final class PullRequestExclusionsTests: XCTestCase {
    func testPersistsOnlyForObservedPRRevision() throws {
        let suite = "PullRequestExclusionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func pr(number: Int = 1011, repo: String = "repo", state: PullRequestState = .closed,
                updated: String = "t1", head: String = "head1", title: String = "Old PR") -> BranchPullRequest {
            BranchPullRequest(number: number, title: title,
                              url: "https://github.com/owner/\(repo)/pull/\(number)", state: state,
                              updatedAt: updated, headOID: head)
        }
        var exclusions = PullRequestExclusions(defaults: defaults)
        exclusions.hide(pr(), defaults: defaults)
        let reloaded = PullRequestExclusions(defaults: defaults)
        XCTAssertTrue(reloaded.contains(pr()))
        XCTAssertFalse(reloaded.contains(pr(number: 1012)))
        XCTAssertFalse(reloaded.contains(pr(repo: "other")))
        XCTAssertFalse(reloaded.contains(pr(state: .open)))
        XCTAssertFalse(reloaded.contains(pr(updated: "t2")))
        XCTAssertFalse(reloaded.contains(pr(head: "head2")))
        XCTAssertFalse(reloaded.contains(pr(title: "Renamed")))
    }
}
