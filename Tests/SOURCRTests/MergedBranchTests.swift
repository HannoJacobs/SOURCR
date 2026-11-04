import XCTest
@testable import SOURCR

final class MergedBranchTests: XCTestCase {
    private func branch(head: String, pr: PullRequestState?, prHead: String? = "abc",
                        isDefault: Bool = false) -> BranchInfo {
        BranchInfo(name: "feature/x", lastCommitAt: .now, ahead: 0, behind: 3, isDefault: isDefault,
                   pullRequest: pr.map { BranchPullRequest(number: 7, title: "x", url: "", state: $0, headOID: prHead) },
                   hasDivergence: true, headOID: head)
    }

    func testMergedPRAtSameHeadIsHidden() {
        XCTAssertTrue(branch(head: "abc", pr: .merged).isMergedAtHead)
    }

    func testNewCommitAfterMergeBringsBranchBack() {
        XCTAssertFalse(branch(head: "def", pr: .merged).isMergedAtHead)
    }

    func testUnknownHeadsStillHideMergedBranch() {
        XCTAssertTrue(branch(head: "abc", pr: .merged, prHead: nil).isMergedAtHead)
    }

    func testOpenClosedNoPRAndDefaultStayVisible() {
        XCTAssertFalse(branch(head: "abc", pr: .open).isMergedAtHead)
        XCTAssertFalse(branch(head: "abc", pr: .closed).isMergedAtHead)
        XCTAssertFalse(branch(head: "abc", pr: nil).isMergedAtHead)
        XCTAssertFalse(branch(head: "abc", pr: .merged, isDefault: true).isMergedAtHead)
    }
}
