import Foundation
import Testing
@testable import SOURCR

struct PullRequestFilesTests {
    @Test func unavailableAndPartialPatchesAreExplicit() throws {
        let raw = #"{"filename":"new.txt","previous_filename":"old.txt","status":"renamed","additions":2,"deletions":1,"patch":"@@ -1 +1,2 @@\n-old\n+new"}"#
        let file = try JSONDecoder().decode(PullRequestFile.self, from: Data(raw.utf8))
        #expect(file.previousFilename == "old.txt")
        #expect(file.note?.contains("partial") == true)
        let binary = PullRequestFile(filename: "photo.png", previousFilename: nil, status: "modified", additions: 0, deletions: 0, patch: nil)
        #expect(binary.note?.contains("no text patch") == true)
    }

    @Test func patchContentResemblingFileHeadersKeepsLineNumbers() {
        let patch = "@@ -4,1 +4,1 @@\n--- old value\n+++ new value"
        let diff = DiffParser.parse(path: "math.txt", unifiedDiff: patch)
        #expect(diff.lines[1].kind == .deletion)
        #expect(diff.lines[1].oldLineNumber == 4)
        #expect(diff.lines[2].kind == .addition)
        #expect(diff.lines[2].newLineNumber == 4)
        let rows = DiffParser.sideBySideRows(from: diff)
        #expect(rows[1].leftText == "-- old value")
        #expect(rows[1].rightText == "++ new value")
    }

    @Test @MainActor func switchingSurfacesClearsPRPayload() {
        let state = AppState()
        state.panelMode = .branches
        state.selectedPullRequest = BranchPullRequest(number: 42, title: "PR", url: "https://github.com/example/repo/pull/42", state: .open)
        state.pullRequestFiles = [.init(filename: "f", previousFilename: nil, status: "added", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+line")]
        state.selectPullRequestFile("f")
        state.isExpanded = true
        state.panelMode = .diff
        #expect(state.selectedPullRequest == nil)
        #expect(state.pullRequestFiles.isEmpty)
        #expect(state.pullRequestDiff == nil)
        #expect(!state.isExpanded)
    }
}
