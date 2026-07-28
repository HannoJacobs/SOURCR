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
    let updatedAt: Date
    let url: String

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

    func elapsed(at now: Date = Date()) -> TimeInterval {
        if isRunning {
            return max(0, now.timeIntervalSince(createdAt))
        }
        return max(0, updatedAt.timeIntervalSince(createdAt))
    }

    /// Newer run wins (createdAt, then databaseId).
    func isNewerThan(_ other: ActionRun) -> Bool {
        if createdAt != other.createdAt { return createdAt > other.createdAt }
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

    func durationSeconds() -> TimeInterval? {
        guard let startedAt else { return nil }
        let end = completedAt ?? Date()
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
}

struct RepoActionsSnapshot: Hashable {
    var remote: GitHubRemote?
    var runs: [ActionRun]
    var errorMessage: String?
    var fetchedAt: Date?

    static let empty = RepoActionsSnapshot(
        remote: nil,
        runs: [],
        errorMessage: nil,
        fetchedAt: nil
    )

    /// One entry per workflow name: the newest run only.
    /// A new in-progress run replaces the previous pass/fail for that workflow.
    var latestRunsByWorkflow: [ActionRun] {
        var best: [String: ActionRun] = [:]
        for run in runs {
            if let existing = best[run.workflowName], !run.isNewerThan(existing) {
                continue
            }
            best[run.workflowName] = run
        }
        return best.values.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning && !b.isRunning }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.databaseId > b.databaseId
        }
    }

    var runningCount: Int { latestRunsByWorkflow.filter(\.isRunning).count }
    var failedCount: Int { latestRunsByWorkflow.filter(\.isFailed).count }
    var passedCount: Int { latestRunsByWorkflow.filter(\.isPassed).count }
}
