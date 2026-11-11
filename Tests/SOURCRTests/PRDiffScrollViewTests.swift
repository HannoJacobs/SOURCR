import AppKit
import Testing
@testable import SOURCR

@MainActor
struct PRDiffScrollViewTests {
    private func fixture() -> [PRDiffDocumentRow] {
        PRDiffDocumentRow.build(files: (0..<40).map { file in
            let lines = (0..<60).map { line in
                "+file \(file) line \(line) " + (line % 3 == 0 ? String(repeating: "wrapped source 🌍\t", count: 25) : "short")
            }.joined(separator: "\n")
            return PullRequestFile(filename: "folder-\(file)/same.swift", previousFilename: file == 5 ? "old.swift" : nil,
                                   status: "modified", additions: 60, deletions: 0,
                                   patch: "@@ -0,0 +1,60 @@\n" + lines)
        })
    }

    private func makeScroll(rows: [PRDiffDocumentRow]) -> PRDiffTableScrollView {
        let scroll = PRDiffTableScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.update(rows: rows, version: 1, request: 0, target: nil)
        scroll.layoutSubtreeIfNeeded()
        return scroll
    }

    @Test func mixedWrappedRowsKeepExactGeometryWhileScrollingBothDirections() throws {
        let rows = fixture()
        let scroll = makeScroll(rows: rows)
        let table = scroll.table
        let height = table.bounds.height
        let lastRect = table.rect(ofRow: rows.count - 1)
        #expect(height > 40000)
        var previousRow = -1
        for y in stride(from: CGFloat(0), to: height - 400, by: 271) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            let row = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            try #require(rows.indices.contains(row), "Invalid row \(row) at y=\(y), clip=\(scroll.contentView.bounds), table=\(table.frame), first=\(table.rect(ofRow: 0)), last=\(lastRect)")
            #expect(row >= previousRow)
            #expect(scroll.visibleFile == rows[row].filePath)
            #expect(table.bounds.height == height)
            #expect(table.rect(ofRow: rows.count - 1) == lastRect)
            previousRow = row
        }
        for y in stride(from: scroll.contentView.bounds.minY, through: CGFloat(0), by: -733) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            table.layoutSubtreeIfNeeded()
            let row = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            #expect(row <= previousRow)
            #expect(table.bounds.height == height)
            previousRow = row
        }
        // Reusable native cells stay bounded even after traversing the document.
        #expect(table.subviews.count < 200)
    }

    @Test func distantAndRepeatedFileJumpsLandExactlyWithoutSelectionUpdatesMovingContent() {
        let rows = fixture()
        let scroll = makeScroll(rows: rows)
        for (request, file) in [35, 2, 35, 35, 0].enumerated() {
            let path = "folder-\(file)/same.swift"
            scroll.update(rows: rows, version: 1, request: request + 1, target: path)
            let header = rows.firstIndex { if case .file(let f) = $0 { return f.filename == path }; return false }!
            #expect(abs(scroll.contentView.bounds.minY - scroll.table.rect(ofRow: header).minY) < 1)
            #expect(scroll.visibleFile == path)
            let origin = scroll.contentView.bounds.origin
            let cell = scroll.table.view(atColumn: 0, row: header, makeIfNecessary: true)
            // A SwiftUI update for highlight/summary changes must not reload cells or issue a jump.
            scroll.update(rows: rows, version: 1, request: request + 1, target: "folder-1/same.swift")
            #expect(scroll.contentView.bounds.origin == origin)
            #expect(scroll.table.view(atColumn: 0, row: header, makeIfNecessary: true) === cell)
        }
    }

    @Test func narrowingRewrapsAllRowsAndPreservesTheVisibleRowAndOffset() {
        let rows = fixture()
        let scroll = makeScroll(rows: rows)
        scroll.scrollToFile("folder-25/same.swift")
        let targetRow = scroll.table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY)) + 10
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.table.rect(ofRow: targetRow).minY + 3))
        let oldHeight = scroll.table.bounds.height
        scroll.setFrameSize(NSSize(width: 360, height: 400))
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.table.bounds.height > oldHeight)
        #expect(scroll.table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY)) == targetRow)
        #expect(abs(scroll.contentView.bounds.minY - scroll.table.rect(ofRow: targetRow).minY - 3) < 1)
        #expect(scroll.visibleFile == rows[targetRow].filePath)
    }

    @Test func replacingDocumentsInvalidatesHeightsAndFileTargets() {
        let rows = fixture()
        let scroll = makeScroll(rows: rows)
        let tallHeight = scroll.table.bounds.height
        let short = PRDiffDocumentRow.build(files: [
            .init(filename: "new.txt", previousFilename: nil, status: "added", additions: 1,
                  deletions: 0, patch: "@@ -0,0 +1 @@\n+short")
        ])
        scroll.update(rows: short, version: 2, request: 1, target: "new.txt")
        #expect(scroll.table.numberOfRows == short.count + 1) // Trailing viewport space.
        #expect(scroll.table.bounds.height < tallHeight)
        #expect(scroll.visibleFile == "new.txt")
        let cell = scroll.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        #expect(cell?.accessibilityLabel() == "new.txt")
        scroll.update(rows: rows, version: 3, request: 2, target: "folder-35/same.swift")
        #expect(scroll.table.numberOfRows == rows.count + 1)
        #expect(scroll.table.bounds.height == tallHeight)
        #expect(scroll.visibleFile == "folder-35/same.swift")
    }

    @Test func lastSmallFileCanReachTheTopAndKeepsItsHighlight() {
        let rows = PRDiffDocumentRow.build(files: ["first.txt", "last.txt"].map {
            .init(filename: $0, previousFilename: nil, status: "added", additions: 1,
                  deletions: 0, patch: "@@ -0,0 +1 @@\n+short")
        })
        let scroll = makeScroll(rows: rows)
        for request in 1...3 {
            scroll.update(rows: rows, version: 1, request: request, target: "last.txt")
            #expect(scroll.visibleFile == "last.txt")
            let header = rows.firstIndex { $0.id == PRDiffDocumentRow.fileID("last.txt") }!
            #expect(scroll.contentView.bounds.minY == scroll.table.rect(ofRow: header).minY)
        }
    }
}
