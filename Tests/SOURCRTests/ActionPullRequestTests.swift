import Foundation
import Testing
@testable import SOURCR

struct ActionPullRequestTests {
    @Test func explicitRunAssociationsAndNoPRRemainDistinct() throws {
        let json = #"""
        {"workflow_runs":[
          {"id":1,"name":"CI","head_sha":"abc","head_branch":"feature","event":"pull_request","status":"in_progress","run_attempt":2,"pull_requests":[{"number":42},{"number":42},{"number":7}]},
          {"id":2,"head_sha":"def","event":"push","status":"completed","pull_requests":[]}
        ]}
        """#
        let rows = try JSONDecoder().decode(GHWorkflowRuns.self, from: Data(json.utf8)).workflow_runs
        let run = rows[0].asActionRun(repoID: UUID())
        #expect(run.pullRequestNumbers == [7, 42])
        #expect(run.pullRequestLabel == "(#7, #42)")
        #expect(run.attempt == 2)
        #expect(run.isRunning)
        #expect(rows[1].asActionRun(repoID: UUID()).pullRequestLabel == nil)
    }

    @Test func commitAssociationRequiresExactMergeOrBranchHead() throws {
        let json = #"""
        {"data":{"repository":{"c0":{"associatedPullRequests":{"nodes":[
          {"number":10,"merged":true,"mergeCommit":{"oid":"abc"}},
          {"number":11,"merged":true,"mergeCommit":{"oid":"other"}},
          {"number":12,"merged":false,"mergeCommit":{"oid":"abc"}},
          {"number":13,"merged":false,"headRefOid":"abc","headRefName":"feature"},
          {"number":14,"merged":false,"headRefOid":"abc","headRefName":"different"},
          null
        ]}},"c1":null}}}
        """#
        let result = try JSONDecoder().decode(GHRunCommitResponse.self, from: Data(json.utf8))
        #expect(result.pullRequestNumbers(alias: "c0", sha: "abc", branch: "feature") == [10, 13])
        #expect(result.pullRequestNumbers(alias: "c0", sha: "abc", branch: "main") == [10])
        #expect(result.pullRequestNumbers(alias: "c0", sha: "missing", branch: "feature").isEmpty)
        #expect(result.pullRequestNumbers(alias: "c1", sha: "abc", branch: "main").isEmpty)
    }
}
