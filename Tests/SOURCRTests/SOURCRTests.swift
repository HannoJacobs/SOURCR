import Testing
@testable import SOURCR

struct DiffParserTests {
    @Test func parsesUnifiedDiff() {
        let raw = """
        diff --git a/foo.txt b/foo.txt
        index 111..222 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,3 +1,4 @@
         keep
        -old
        +new
        +extra
         end
        """
        let parsed = DiffParser.parse(path: "foo.txt", unifiedDiff: raw)
        #expect(!parsed.isEmpty)
        #expect(parsed.lines.contains { $0.kind == .deletion && $0.text == "old" })
        #expect(parsed.lines.contains { $0.kind == .addition && $0.text == "new" })
        #expect(parsed.lines.contains { $0.kind == .addition && $0.text == "extra" })
    }

    @Test func sideBySidePairsEdits() {
        let raw = """
        @@ -1,2 +1,2 @@
        -a
        +b
         c
        """
        let parsed = DiffParser.parse(path: "x", unifiedDiff: raw)
        let rows = DiffParser.sideBySideRows(from: parsed)
        #expect(rows.contains { $0.leftText == "a" && $0.rightText == "b" })
    }

    @Test func syntheticAddition() {
        let parsed = DiffParser.syntheticAddition(path: "new.txt", contents: "hello\nworld")
        #expect(parsed.lines.filter { $0.kind == .addition }.count == 2)
    }
}

struct GitPorcelainTests {
    @Test func changeLetters() {
        #expect(GitChangeType.modified.shortLetter == "M")
        #expect(GitChangeType.added.shortLetter == "A")
        #expect(GitChangeType.deleted.shortLetter == "D")
    }
}
