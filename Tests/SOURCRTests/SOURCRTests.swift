import Foundation
import Testing
@testable import SOURCR

struct GitServiceHardeningTests {
    @Test func largeUntrackedStatusDoesNotDeadlock() throws {
        // Repro of the 1.7 production failure mode: `git status -uall` writing more
        // than the ~64KB pipe buffer while the parent waited before draining stdout.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sourcr-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(in: root.path, ["init"])
        try runGit(in: root.path, ["config", "user.email", "sourcr-test@example.com"])
        try runGit(in: root.path, ["config", "user.name", "SOURCR Test"])

        // ~2000 medium paths ≈ well over 64KB of porcelain when listed with -uall.
        for i in 0..<2_000 {
            let name = String(format: "untracked_file_%04d_with_padding_to_grow_porcelain_lines.txt", i)
            try Data("x\n".utf8).write(to: root.appendingPathComponent(name))
        }

        let started = Date()
        let snapshot = try GitService.loadSnapshot(repoPath: root.path)
        let elapsed = Date().timeIntervalSince(started)

        #expect(snapshot.untracked.count == 2_000)
        #expect(elapsed < 15, "status should complete well under the \(Int(GitService.commandTimeout))s timeout")
    }

    private func runGit(in workingDirectory: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitCommandError.gitFailed(command: arguments, status: process.terminationStatus, stderr: "test git failed")
        }
    }
}

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

struct ActionTimingTests {
    private let created = Date(timeIntervalSince1970: 1_785_330_643) // 2026-07-29T12:30:43Z
    private let startedRerun = Date(timeIntervalSince1970: 1_785_333_035) // 2026-07-29T13:10:35Z
    private let failedAt = Date(timeIntervalSince1970: 1_785_331_918) // 2026-07-29T12:51:58Z

    @Test func prefersStartedAtOverCreatedAtForReruns() {
        let now = startedRerun.addingTimeInterval(10 * 60 + 12)
        let elapsed = ActionTiming.elapsed(
            startedAt: startedRerun,
            createdAt: created,
            updatedAt: startedRerun.addingTimeInterval(13),
            isRunning: true,
            now: now
        )
        #expect(Int(elapsed.rounded()) == 612)
    }

    @Test func fallsBackToCreatedAtWhenStartedAtMissing() {
        let now = created.addingTimeInterval(90)
        let elapsed = ActionTiming.elapsed(
            startedAt: .distantPast,
            createdAt: created,
            updatedAt: .distantPast,
            isRunning: true,
            now: now
        )
        #expect(Int(elapsed.rounded()) == 90)
    }

    @Test func completedUsesUpdatedAtMinusStartedAt() {
        let elapsed = ActionTiming.elapsed(
            startedAt: created,
            createdAt: created,
            updatedAt: failedAt,
            isRunning: false,
            now: failedAt.addingTimeInterval(3600)
        )
        #expect(Int(elapsed.rounded()) == Int(failedAt.timeIntervalSince(created).rounded()))
    }

    @Test func completedPrefersJobCompletionHintOverUpdatedAtBump() {
        let jobEnd = startedRerun.addingTimeInterval(600)
        let updatedBump = jobEnd.addingTimeInterval(120) // artifact / metadata bump
        let elapsed = ActionTiming.elapsed(
            startedAt: startedRerun,
            createdAt: created,
            updatedAt: updatedBump,
            isRunning: false,
            now: updatedBump,
            completedAtHint: jobEnd
        )
        #expect(Int(elapsed.rounded()) == 600)
    }

    @Test func invertedTimestampsYieldZero() {
        let elapsed = ActionTiming.elapsed(
            startedAt: failedAt,
            createdAt: created,
            updatedAt: created,
            isRunning: false,
            now: failedAt
        )
        #expect(elapsed == 0)
    }

    @Test func missingTimestampsYieldZero() {
        let elapsed = ActionTiming.elapsed(
            startedAt: .distantPast,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            isRunning: true,
            now: Date()
        )
        #expect(elapsed == 0)
    }

    @Test func futureStartBeyondSkewYieldsZero() {
        let now = created
        let futureStart = now.addingTimeInterval(600)
        let elapsed = ActionTiming.elapsed(
            startedAt: futureStart,
            createdAt: created,
            updatedAt: .distantPast,
            isRunning: true,
            now: now
        )
        #expect(elapsed == 0)
    }

    @Test func rejectsPlaceholderDates() {
        #expect(GitHubActionsService.parseDateIfPresent("0001-01-01T00:00:00Z") == nil)
        #expect(GitHubActionsService.parseDateIfPresent("") == nil)
        #expect(GitHubActionsService.parseDateIfPresent("2026-07-29T13:10:35Z") != nil)
    }
}
