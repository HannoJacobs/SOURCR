import Foundation

enum GitFileKind: String, Codable, Hashable {
    /// Combined staged + unstaged working-tree change (shown as one row).
    case changed
    case staged
    case unstaged
    case untracked
    case unchanged
}

enum GitChangeType: String, Codable, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case unchanged
    case unknown

    var shortLetter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "U"
        case .unchanged: return " "
        case .unknown: return "?"
        }
    }
}

struct WatchedRepo: Identifiable, Codable, Hashable {
    var id: UUID
    var path: String
    var displayName: String

    init(id: UUID = UUID(), path: String, displayName: String? = nil) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
    }
}

struct GitFileEntry: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(path)" }
    let path: String
    let kind: GitFileKind
    let changeType: GitChangeType
    let oldPath: String?

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var directoryPath: String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return dir == "." ? "" : dir
    }
}

struct RepoSnapshot: Hashable {
    var branch: String
    var headSHA: String
    /// Staged + unstaged, deduped by path (preferred UI list).
    var changes: [GitFileEntry]
    var untracked: [GitFileEntry]
    var unchangedSample: [GitFileEntry]
    var errorMessage: String?
    /// Fingerprint of porcelain output — skip UI churn when unchanged.
    var statusFingerprint: String

    static let empty = RepoSnapshot(
        branch: "—",
        headSHA: "",
        changes: [],
        untracked: [],
        unchangedSample: [],
        errorMessage: nil,
        statusFingerprint: ""
    )

    var totalChanges: Int {
        changes.count + untracked.count
    }

    var allListedFiles: [GitFileEntry] {
        changes + untracked + unchangedSample
    }
}

enum DiffViewMode: String, CaseIterable, Identifiable {
    case inline
    case sideBySide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inline: return "Inline"
        case .sideBySide: return "Side By Side"
        }
    }
}

enum DiffLineKind: Hashable {
    case context
    case addition
    case deletion
    case header
    case meta
}

struct DiffLine: Identifiable, Hashable {
    let id: Int
    let kind: DiffLineKind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct ParsedDiff: Hashable {
    var path: String
    var lines: [DiffLine]
    var isBinary: Bool
    var isEmpty: Bool

    static func empty(path: String) -> ParsedDiff {
        ParsedDiff(path: path, lines: [], isBinary: false, isEmpty: true)
    }
}

struct SideBySideRow: Identifiable, Hashable {
    let id: Int
    let leftNumber: Int?
    let leftText: String?
    let leftKind: DiffLineKind
    let rightNumber: Int?
    let rightText: String?
    let rightKind: DiffLineKind
}

// MARK: - Actions (GitHub)

enum PanelMode: String, CaseIterable, Identifiable {
    case diff
    case actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diff: return "Diff"
        case .actions: return "Actions"
        }
    }
}

enum ActionWorkflowKind: String, Hashable {
    case ci
    case cd
    case other

    var badge: String {
        switch self {
        case .ci: return "CI"
        case .cd: return "CD"
        case .other: return "misc"
        }
    }

    static func classify(workflowName: String) -> ActionWorkflowKind {
        let lower = workflowName.lowercased()
        if lower.contains("deploy") { return .cd }
        if lower.contains("ci") || lower.contains("test") || lower.contains("build") { return .ci }
        return .other
    }
}

struct GitHubRemote: Hashable, Codable {
    var owner: String
    var name: String

    var slug: String { "\(owner)/\(name)" }
}

struct ActionRun: Identifiable, Hashable {
    /// Stable across repos: "\(repoID.uuidString):\(databaseId)"
    var id: String { "\(repoID.uuidString):\(databaseId)" }

    let databaseId: Int
    let repoID: UUID
    let workflowName: String
    let displayTitle: String
    let headBranch: String
    let event: String
    let status: String
    let conclusion: String?
    let createdAt: Date
    /// Start of the latest attempt (`run_started_at`). Resets when a run is re-run.
    let startedAt: Date
    let updatedAt: Date
    let url: String
    /// 1 for the first attempt; increments on re-run.
    let attempt: Int

    var workflowKind: ActionWorkflowKind {
        ActionWorkflowKind.classify(workflowName: workflowName)
    }

    var isRunning: Bool {
        status == "in_progress" || status == "queued" || status == "requested" || status == "waiting" || status == "pending"
    }

    var isFailed: Bool {
        guard !isRunning else { return false }
        return conclusion == "failure" || conclusion == "timed_out" || conclusion == "startup_failure"
    }

    var isPassed: Bool {
        !isRunning && conclusion == "success"
    }

    var isCancelled: Bool {
        !isRunning && (conclusion == "cancelled" || conclusion == "skipped")
    }

    /// Anchor for live/completed duration: latest attempt start, not original createdAt.
    /// Using createdAt wrongly includes prior failed attempts and the idle gap before a re-run.
    var timingStart: Date? {
        ActionTiming.preferredStart(startedAt: startedAt, createdAt: createdAt)
    }

    /// Wall-clock elapsed for this run's latest attempt.
    /// - Running / queued / waiting: `now - start`
    /// - Completed: `end - start`, where `end` prefers an optional job-completion hint, else `updatedAt`
    /// Invalid/missing timestamps and mild clock skew collapse to `0` instead of huge values.
    func elapsed(at now: Date = Date(), completedAtHint: Date? = nil) -> TimeInterval {
        ActionTiming.elapsed(
            startedAt: startedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isRunning: isRunning,
            now: now,
            completedAtHint: completedAtHint
        )
    }

    /// Newer run wins (createdAt, then higher attempt, then databaseId).
    func isNewerThan(_ other: ActionRun) -> Bool {
        if createdAt != other.createdAt { return createdAt > other.createdAt }
        if attempt != other.attempt { return attempt > other.attempt }
        return databaseId > other.databaseId
    }
}

struct ActionStep: Identifiable, Hashable {
    var id: Int { number }
    let number: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?

    var isCompleted: Bool { status == "completed" }
    var isInProgress: Bool { status == "in_progress" }
    var isPending: Bool { !isCompleted && !isInProgress }

    var isSuccess: Bool { conclusion == "success" }
    var isFailure: Bool {
        conclusion == "failure" || conclusion == "timed_out" || conclusion == "startup_failure"
    }

    func durationSeconds(at now: Date = Date()) -> TimeInterval? {
        guard let startedAt, ActionTiming.isPlausible(startedAt) else { return nil }
        if startedAt > now.addingTimeInterval(ActionTiming.futureSkewTolerance) { return 0 }
        let end: Date
        if let completedAt, ActionTiming.isPlausible(completedAt) {
            end = max(completedAt, startedAt)
        } else {
            end = now
        }
        return max(0, end.timeIntervalSince(startedAt))
    }
}

struct ActionJob: Identifiable, Hashable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let steps: [ActionStep]
    let url: String?
}

struct ActionRunDetail: Hashable {
    let run: ActionRun
    let jobs: [ActionJob]

    var primaryJob: ActionJob? {
        if let running = jobs.first(where: { $0.status == "in_progress" }) {
            return running
        }
        if let failed = jobs.first(where: {
            $0.conclusion == "failure" || $0.conclusion == "timed_out" || $0.conclusion == "startup_failure"
        }) {
            return failed
        }
        return jobs.first
    }

    var completedStepCount: Int {
        jobs.reduce(0) { $0 + $1.steps.filter(\.isCompleted).count }
    }

    var totalStepCount: Int {
        jobs.reduce(0) { $0 + $1.steps.count }
    }

    /// Prefer job completion timestamps when present so post-finish `updatedAt` bumps
    /// (artifacts, UI metadata) do not inflate the reported duration.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        let jobEnd = jobs.compactMap(\.completedAt).filter(ActionTiming.isPlausible).max()
        let hint = run.isRunning ? nil : jobEnd
        return run.elapsed(at: now, completedAtHint: hint)
    }
}

/// Shared wall-clock math for Actions run/step durations.
enum ActionTiming {
    /// Tolerate mild client/server clock skew before treating a start as invalid.
    static let futureSkewTolerance: TimeInterval = 120
    /// GitHub Actions did not exist before this; reject garbage epochs.
    static let earliestPlausible = Date(timeIntervalSince1970: 1_420_070_400) // 2015-01-01 UTC

    static func isPlausible(_ date: Date?) -> Bool {
        guard let date else { return false }
        guard date > Date.distantPast else { return false }
        guard date >= earliestPlausible else { return false }
        return true
    }

    static func preferredStart(startedAt: Date, createdAt: Date) -> Date? {
        if isPlausible(startedAt) { return startedAt }
        if isPlausible(createdAt) { return createdAt }
        return nil
    }

    static func elapsed(
        startedAt: Date,
        createdAt: Date,
        updatedAt: Date,
        isRunning: Bool,
        now: Date,
        completedAtHint: Date? = nil
    ) -> TimeInterval {
        guard let start = preferredStart(startedAt: startedAt, createdAt: createdAt) else { return 0 }
        if start > now.addingTimeInterval(futureSkewTolerance) { return 0 }

        let end: Date
        if isRunning {
            end = now
        } else if let hint = completedAtHint, isPlausible(hint) {
            // Job completion is the best end anchor; clamp inverted timestamps to 0.
            end = hint < start ? start : hint
        } else if isPlausible(updatedAt) {
            end = updatedAt < start ? start : updatedAt
        } else {
            end = start
        }

        return max(0, end.timeIntervalSince(start))
    }
}

// MARK: - Branches (GitHub)

/// Open pull request associated with a branch head.
struct BranchPullRequest: Hashable {
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
}

/// Remote branch metadata: divergence from the default branch, last commit, open PR.
struct BranchInfo: Hashable {
    let name: String
    let lastCommitAt: Date
    /// Commits this branch has that the default branch does not.
    let ahead: Int
    /// Commits the default branch has that this branch does not.
    let behind: Int
    let isDefault: Bool
    let pullRequest: BranchPullRequest?
    /// False when `ahead`/`behind` could not be resolved — an old branch outside the
    /// divergence window, or a row derived from workflow runs after the branch query
    /// failed. Divergence is then *unknown*, not zero, and must not be drawn as a value.
    let hasDivergence: Bool
}

/// Collapsed check state for a branch — the only four states worth a glance.
enum BranchCheckState {
    case running
    case failed
    /// Every workflow that ran most recently on this branch passed.
    case clean
    /// Nothing has run on this branch (or only cancelled/skipped runs).
    case idle
}

/// How far back a branch counts as "something I'm working on".
enum BranchActivityWindow: String, CaseIterable, Identifiable {
    case day
    case threeDays
    case week
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "1d"
        case .threeDays: return "3d"
        case .week: return "7d"
        case .all: return "All"
        }
    }

    /// `nil` means no cutoff.
    var interval: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .threeDays: return 3 * 86_400
        case .week: return 7 * 86_400
        case .all: return nil
        }
    }

    func includes(_ activity: Date, now: Date) -> Bool {
        guard let interval else { return true }
        return now.timeIntervalSince(activity) <= interval
    }
}

/// One branch plus the newest run per workflow on it — the Actions list row.
struct BranchActivity: Identifiable, Hashable {
    let repoID: UUID
    let branch: BranchInfo
    /// Newest run per workflow name on this branch.
    let runs: [ActionRun]

    var id: String { "\(repoID.uuidString):\(branch.name)" }

    var runningRuns: [ActionRun] { runs.filter(\.isRunning) }
    var failedRuns: [ActionRun] { runs.filter(\.isFailed) }
    var passedRuns: [ActionRun] { runs.filter(\.isPassed) }

    /// The noise rule: only running and failed runs earn a row of their own.
    /// Running first (live timers), then failures (newest first).
    var attentionRuns: [ActionRun] {
        let running = runningRuns.sorted { $0.createdAt > $1.createdAt }
        let failed = failedRuns.sorted { $0.createdAt > $1.createdAt }
        return running + failed
    }

    var state: BranchCheckState {
        if !runningRuns.isEmpty { return .running }
        if !failedRuns.isEmpty { return .failed }
        if !passedRuns.isEmpty { return .clean }
        return .idle
    }

    /// Newest of: last commit on the branch, and any run touching it.
    /// Drives the "am I actually working on this?" cutoff.
    var lastActivityAt: Date {
        var latest = branch.lastCommitAt
        for run in runs {
            latest = max(latest, max(run.createdAt, run.updatedAt))
        }
        return latest
    }

    /// Live/failed runs sort above clean branches; then most recently touched.
    var sortRank: Int {
        switch state {
        case .running: return 0
        case .failed: return 1
        case .clean: return 2
        case .idle: return 3
        }
    }
}

struct RepoActionsSnapshot: Hashable {
    var remote: GitHubRemote?
    var runs: [ActionRun]
    var branches: [BranchInfo]
    var defaultBranch: String?
    var errorMessage: String?
    var fetchedAt: Date?
    /// Separate from `fetchedAt`: branch metadata polls on a slower cadence than runs.
    var branchesFetchedAt: Date?

    static let empty = RepoActionsSnapshot(
        remote: nil,
        runs: [],
        branches: [],
        defaultBranch: nil,
        errorMessage: nil,
        fetchedAt: nil,
        branchesFetchedAt: nil
    )

    /// One entry per (branch, workflow): the newest run only.
    /// Deduping by workflow name alone would collide CI on `develop` with CI on a feature branch.
    var latestRunsByBranchAndWorkflow: [ActionRun] {
        var best: [String: ActionRun] = [:]
        for run in runs {
            let key = "\(run.headBranch)\u{0000}\(run.workflowName)"
            if let existing = best[key], !run.isNewerThan(existing) { continue }
            best[key] = run
        }
        return Array(best.values)
    }

    /// Branch rows for the panel, filtered by the activity window and sorted
    /// running → failed → clean, then most recently touched.
    func branchActivities(repoID: UUID, window: BranchActivityWindow, now: Date) -> [BranchActivity] {
        var runsByBranch: [String: [ActionRun]] = [:]
        for run in latestRunsByBranchAndWorkflow {
            runsByBranch[run.headBranch, default: []].append(run)
        }

        // If the branch query failed (auth, SAML, network), still show what the runs
        // know about — a board without divergence beats a blank panel.
        let sourceBranches = branches.isEmpty
            ? syntheticBranches(from: runsByBranch)
            : branches

        return sourceBranches
            .map { branch in
                BranchActivity(
                    repoID: repoID,
                    branch: branch,
                    runs: (runsByBranch[branch.name] ?? []).sorted { $0.createdAt > $1.createdAt }
                )
            }
            .filter { window.includes($0.lastActivityAt, now: now) }
            .sorted { a, b in
                if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
                if a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
                return a.branch.name < b.branch.name
            }
    }

    private func syntheticBranches(from runsByBranch: [String: [ActionRun]]) -> [BranchInfo] {
        runsByBranch.map { name, runs in
            BranchInfo(
                name: name,
                lastCommitAt: runs.map(\.createdAt).max() ?? Date.distantPast,
                ahead: 0,
                behind: 0,
                isDefault: name == defaultBranch,
                pullRequest: nil,
                hasDivergence: false
            )
        }
    }
}
