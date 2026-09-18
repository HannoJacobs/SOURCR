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

    @Test func concurrentFastGitCommandsDoNotFalseTimeout() async throws {
        // Repro of the 1.8 false-timeout: many overlapping refreshes blocked pool
        // threads waiting for other pool threads to signal process exit, so even
        // `git rev-parse` appeared to hit the 20s ceiling.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sourcr-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(in: root.path, ["init"])
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try runGit(in: root.path, ["add", "README.md"])
        try runGit(in: root.path, ["-c", "user.email=sourcr-test@example.com", "-c", "user.name=SOURCR Test", "commit", "-m", "init"])

        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    _ = try GitService.loadSnapshot(repoPath: root.path)
                }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 10, "24 concurrent status calls should not false-timeout (elapsed=\(elapsed)s)")
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

// MARK: - Branch board

struct BranchBoardTests {
    private let repoID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(
        _ workflow: String,
        branch: String,
        status: String,
        conclusion: String?,
        ageSeconds: TimeInterval,
        durationSeconds: TimeInterval = 90,
        databaseId: Int = Int.random(in: 1...1_000_000)
    ) -> ActionRun {
        let started = now.addingTimeInterval(-ageSeconds)
        return ActionRun(
            databaseId: databaseId,
            repoID: repoID,
            workflowName: workflow,
            displayTitle: workflow,
            headBranch: branch,
            event: "push",
            status: status,
            conclusion: conclusion,
            createdAt: started,
            startedAt: started,
            updatedAt: started.addingTimeInterval(durationSeconds),
            url: "",
            attempt: 1
        )
    }

    private func branch(
        _ name: String,
        ageSeconds: TimeInterval,
        ahead: Int = 0,
        behind: Int = 0,
        isDefault: Bool = false,
        pr: BranchPullRequest? = nil
    ) -> BranchInfo {
        BranchInfo(
            name: name,
            lastCommitAt: now.addingTimeInterval(-ageSeconds),
            ahead: ahead,
            behind: behind,
            isDefault: isDefault,
            pullRequest: pr,
            hasDivergence: true
        )
    }

    private func snapshot(branches: [BranchInfo], runs: [ActionRun]) -> RepoActionsSnapshot {
        RepoActionsSnapshot(
            remote: GitHubRemote(owner: "o", name: "r"),
            runs: runs,
            branches: branches,
            defaultBranch: "develop",
            errorMessage: nil,
            fetchedAt: now,
            branchesFetchedAt: now
        )
    }

    @Test func hidesBranchesWithNoActivityInsideTheWindow() {
        let snap = snapshot(
            branches: [
                branch("develop", ageSeconds: 3_600, isDefault: true),
                branch("stale/old-thing", ageSeconds: 5 * 86_400)
            ],
            runs: []
        )

        let day = snap.branchActivities(repoID: repoID, window: .day, now: now)
        #expect(day.map(\.branch.name) == ["develop"])

        let all = snap.branchActivities(repoID: repoID, window: .all, now: now)
        #expect(Set(all.map(\.branch.name)) == ["develop", "stale/old-thing"])
    }

    @Test func aRunKeepsAnOtherwiseStaleBranchOnTheBoard() {
        // Last commit is 3 days old, but CI fired 10 minutes ago — still working on it.
        let snap = snapshot(
            branches: [branch("feat/x", ageSeconds: 3 * 86_400)],
            runs: [run("CI", branch: "feat/x", status: "in_progress", conclusion: nil, ageSeconds: 600)]
        )
        let rows = snap.branchActivities(repoID: repoID, window: .day, now: now)
        #expect(rows.map(\.branch.name) == ["feat/x"])
    }

    @Test func passedRunsCollapseToASingleTickAndAreHiddenFromTheRowList() {
        let snap = snapshot(
            branches: [branch("develop", ageSeconds: 600, isDefault: true)],
            runs: [
                run("CI", branch: "develop", status: "completed", conclusion: "success", ageSeconds: 600),
                run("Deploy", branch: "develop", status: "completed", conclusion: "success", ageSeconds: 500)
            ]
        )
        let row = snap.branchActivities(repoID: repoID, window: .day, now: now)[0]
        #expect(row.state == .clean)
        #expect(row.attentionRuns.isEmpty, "a fully green branch shows no run rows, only a tick")
        #expect(row.runs.count == 2, "the passed runs stay available behind the disclosure")
    }

    @Test func failedAndRunningWorkflowsKeepTheirOwnRowAndDuration() {
        let snap = snapshot(
            branches: [branch("feat/x", ageSeconds: 600)],
            runs: [
                run("CI", branch: "feat/x", status: "completed", conclusion: "success", ageSeconds: 900),
                run("Deploy", branch: "feat/x", status: "completed", conclusion: "failure", ageSeconds: 800, durationSeconds: 243),
                run("Lint", branch: "feat/x", status: "in_progress", conclusion: nil, ageSeconds: 112)
            ]
        )
        let row = snap.branchActivities(repoID: repoID, window: .day, now: now)[0]

        #expect(row.state == .running, "anything still running wins the branch summary")
        #expect(row.attentionRuns.map(\.workflowName) == ["Lint", "Deploy"], "running first, then failed; passed dropped")

        let running = row.attentionRuns[0]
        #expect(Int(running.elapsed(at: now).rounded()) == 112, "running rows count up to now")

        let failed = row.attentionRuns[1]
        #expect(Int(failed.elapsed(at: now).rounded()) == 243, "failed rows show how long they ran before dying")
    }

    @Test func runsAreScopedPerBranchNotJustPerWorkflowName() {
        // Same workflow name on two branches must not collapse into one row.
        let snap = snapshot(
            branches: [
                branch("develop", ageSeconds: 300, isDefault: true),
                branch("feat/x", ageSeconds: 300)
            ],
            runs: [
                run("CI", branch: "develop", status: "completed", conclusion: "success", ageSeconds: 300, databaseId: 1),
                run("CI", branch: "feat/x", status: "completed", conclusion: "failure", ageSeconds: 200, databaseId: 2)
            ]
        )
        let rows = snap.branchActivities(repoID: repoID, window: .day, now: now)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.branch.name, $0) })

        #expect(byName["develop"]?.state == .clean)
        #expect(byName["feat/x"]?.state == .failed)
    }

    @Test func boardSortsRunningThenFailedThenMostRecent() {
        let snap = snapshot(
            branches: [
                branch("clean-old", ageSeconds: 7_200),
                branch("clean-new", ageSeconds: 60),
                branch("broken", ageSeconds: 3_600),
                branch("busy", ageSeconds: 3_600)
            ],
            runs: [
                run("CI", branch: "clean-old", status: "completed", conclusion: "success", ageSeconds: 7_200),
                run("CI", branch: "clean-new", status: "completed", conclusion: "success", ageSeconds: 60),
                run("CI", branch: "broken", status: "completed", conclusion: "failure", ageSeconds: 3_600),
                run("CI", branch: "busy", status: "in_progress", conclusion: nil, ageSeconds: 30)
            ]
        )
        let names = snap.branchActivities(repoID: repoID, window: .day, now: now).map(\.branch.name)
        #expect(names == ["busy", "broken", "clean-new", "clean-old"])
    }

    @Test func fallsBackToRunDerivedBranchesWhenBranchMetadataIsUnavailable() {
        // The GraphQL branch call can fail (SAML, scopes, network) while runs succeed.
        // The board must still render rather than going blank.
        let snap = snapshot(
            branches: [],
            runs: [run("CI", branch: "feat/x", status: "in_progress", conclusion: nil, ageSeconds: 120)]
        )
        let rows = snap.branchActivities(repoID: repoID, window: .day, now: now)
        #expect(rows.map(\.branch.name) == ["feat/x"])
        #expect(!rows[0].branch.hasDivergence, "divergence is unknown here, not zero")
        #expect(rows[0].state == .running)
    }

    @Test func aDeletedBranchDropsOffEvenWhileItsRunsRemain() {
        // Merge a PR, GitHub deletes the branch, but its workflow runs stay in the
        // history for days. Rows come from live refs, so the branch must disappear.
        let snap = snapshot(
            branches: [branch("develop", ageSeconds: 300, isDefault: true)],
            runs: [
                run("CI", branch: "develop", status: "completed", conclusion: "success", ageSeconds: 300),
                run("CI", branch: "feat/merged-and-deleted", status: "completed", conclusion: "failure", ageSeconds: 600)
            ]
        )
        let names = snap.branchActivities(repoID: repoID, window: .day, now: now).map(\.branch.name)
        #expect(names == ["develop"])
        #expect(!names.contains("feat/merged-and-deleted"))
    }

    @Test func pullRequestStateCoversOpenDraftMergedAndClosed() {
        #expect(PullRequestState.from(rawState: "OPEN", isDraft: false) == .open)
        #expect(PullRequestState.from(rawState: "OPEN", isDraft: true) == .draft)
        #expect(PullRequestState.from(rawState: "MERGED", isDraft: false) == .merged)
        #expect(PullRequestState.from(rawState: "CLOSED", isDraft: false) == .closed)
        // A draft that was closed reads as closed, matching GitHub's Branches page.
        #expect(PullRequestState.from(rawState: "CLOSED", isDraft: true) == .closed)
        // A merged PR is never reported as draft.
        #expect(PullRequestState.from(rawState: "MERGED", isDraft: true) == .merged)
    }

    @Test func branchCarriesItsPullRequestWhateverTheState() {
        let pr = BranchPullRequest(number: 984, title: "Cards proof", url: "https://x/984", state: .merged)
        let snap = snapshot(
            branches: [branch("hanno/hea-1643-cards-proof", ageSeconds: 600, pr: pr)],
            runs: []
        )
        let row = snap.branchActivities(repoID: repoID, window: .day, now: now)[0]
        #expect(row.branch.pullRequest?.number == 984)
        #expect(row.branch.pullRequest?.state == .merged)
    }

    @Test func branchWithNoRunsReadsAsIdleNotGreen() {
        let snap = snapshot(branches: [branch("docs/typo", ageSeconds: 300)], runs: [])
        let row = snap.branchActivities(repoID: repoID, window: .day, now: now)[0]
        #expect(row.state == .idle, "no workflows ran — that is not a pass")
        #expect(row.attentionRuns.isEmpty)
    }
}
