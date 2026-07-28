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

struct GitHubRemoteParseTests {
    @Test func parsesSSHAliasRemote() {
        let remote = GitHubActionsService.parseGitHubRemoteURL(
            "git@github.com-hb:hb-innovation-lab/PPA-Wrapper.git"
        )
        #expect(remote?.slug == "hb-innovation-lab/PPA-Wrapper")
    }

    @Test func parsesHTTPSRemote() {
        let remote = GitHubActionsService.parseGitHubRemoteURL(
            "https://github.com/HannoJacobs/SOURCR.git"
        )
        #expect(remote?.owner == "HannoJacobs")
        #expect(remote?.name == "SOURCR")
    }

    @Test func rejectsNonGitHubRemote() {
        let remote = GitHubActionsService.parseGitHubRemoteURL(
            "git@ssh.dev.azure.com:v3/healthbridge/Innovation%20Lab/Practice-Partner-Agent"
        )
        #expect(remote == nil)
    }

    @Test func formatsDurations() {
        #expect(GitHubActionsService.formatDuration(16) == "16s")
        #expect(GitHubActionsService.formatDuration(89) == "1m29s")
        #expect(GitHubActionsService.formatDuration(3614) == "1h00m14s")
    }
}
