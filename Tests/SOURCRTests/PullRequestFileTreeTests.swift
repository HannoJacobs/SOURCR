import Testing
@testable import SOURCR

struct PullRequestFileTreeTests {
    private let paths = ["src/features/alpha/main.swift", "src/features/beta/main.swift", "README.md"]

    @Test func compactChainsRetainIndentationAndDuplicateFilenames() {
        let rows = PullRequestFileTree.rows(paths: paths, collapsed: [], filter: "")
        #expect(rows.map(\.name) == ["src/features", "alpha", "main.swift", "beta", "main.swift", "README.md"])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 2, 0])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func collapsingHidesOnlyDescendants() {
        let rows = PullRequestFileTree.rows(paths: paths, collapsed: ["src/features/alpha"], filter: "")
        #expect(!rows.contains { $0.id == "src/features/alpha/main.swift" })
        #expect(rows.contains { $0.id == "src/features/beta/main.swift" })
        #expect(rows.first { $0.name == "alpha" }?.isExpanded == false)
    }

    @Test func filteringKeepsMatchingFolderContext() {
        let rows = PullRequestFileTree.rows(paths: paths, collapsed: [], filter: "BETA")
        #expect(rows.map(\.name) == ["src/features/beta", "main.swift"])
        #expect(rows.last?.id == "src/features/beta/main.swift")
    }
}
