import Testing
@testable import SOURCR

struct PRDiffDocumentTests {
    @Test func documentRowsKeepExactPathsAcrossRepeatedLineNumbers() {
        let files = ["a/same.txt", "b/same.txt"].map {
            PullRequestFile(filename: $0, previousFilename: nil, status: "modified", additions: 1, deletions: 1,
                            patch: "@@ -1 +1 @@\n-old\n+new")
        }
        let rows = PRDiffDocumentRow.build(files: files)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for row in rows {
            #expect(files.contains { $0.filename == row.filePath })
            if case .file(let file) = row {
                #expect(row.id == PRDiffDocumentRow.fileID(file.filename))
            }
        }
    }

    @Test @MainActor func viewportTrackingDoesNotCreateOrRetargetScrollCommands() {
        let state = AppState()
        state.pullRequestFiles = ["a/one", "b/two"].map {
            .init(filename: $0, previousFilename: nil, status: "added", additions: 0, deletions: 0, patch: nil)
        }
        state.selectPullRequestFile("b/two")
        let request = state.pullRequestScrollRequest
        state.collapsedPullRequestFolders = ["a", "b"]
        state.trackVisiblePullRequestFile("a/one")
        #expect(state.selectedPullRequestFile == "a/one")
        #expect(state.collapsedPullRequestFolders == ["b"])
        #expect(state.pullRequestScrollRequest == request)
        #expect(state.pullRequestScrollTarget == "b/two")
    }

    @Test func allFilesShareOneStreamWithUniqueLineAndHeaderAnchors() {
        let files = ["src/a.txt", "test/a.txt"].map {
            PullRequestFile(filename: $0, previousFilename: nil, status: "modified", additions: 1, deletions: 1,
                            patch: "@@ -10 +20 @@\n-old\n+new")
        }
        let rows = PRDiffDocumentRow.build(files: files)
        let headers = rows.compactMap { row -> String? in
            if case .file(let file) = row { return file.filename }; return nil
        }
        #expect(headers == ["src/a.txt", "test/a.txt"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.contains { $0.id == PRDiffDocumentRow.fileID("test/a.txt") })
        let additions = rows.compactMap { row -> Int? in
            if case .line(_, let line) = row, line.kind == .addition { return line.newLineNumber }; return nil
        }
        #expect(additions == [20, 20])
    }

    @Test func unavailablePatchDoesNotStopFollowingFile() {
        let files = [
            PullRequestFile(filename: "photo.png", previousFilename: nil, status: "added", additions: 0, deletions: 0, patch: nil),
            PullRequestFile(filename: "after.txt", previousFilename: "before.txt", status: "renamed", additions: 1, deletions: 0,
                            patch: "@@ -0,0 +1 @@\n+after")
        ]
        let rows = PRDiffDocumentRow.build(files: files)
        #expect(rows.contains { if case .note(let path, _) = $0 { return path == "photo.png" }; return false })
        #expect(rows.contains { if case .line(let path, let line) = $0 { return path == "after.txt" && line.text == "after" }; return false })
    }

    @Test @MainActor func repeatedFileClicksRequestAnotherJump() {
        let state = AppState()
        state.pullRequestFiles = [.init(filename: "a", previousFilename: nil, status: "added", additions: 1, deletions: 0, patch: nil)]
        state.selectPullRequestFile("a")
        let first = state.pullRequestScrollRequest
        state.selectPullRequestFile("a")
        #expect(state.pullRequestScrollRequest == first + 1)
        #expect(state.selectedPullRequestFile == "a")
    }
}
