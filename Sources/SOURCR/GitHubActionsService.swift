import Foundation

enum GitHubActionsError: LocalizedError {
    case ghNotFound
    case noGitHubRemote
    case ghFailed(status: Int32, stderr: String)
    case timedOut(TimeInterval)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "GitHub CLI (`gh`) not found. Install it and run `gh auth login`."
        case .noGitHubRemote:
            return "No GitHub remote on origin"
        case .ghFailed(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "gh command failed" : trimmed
        case .timedOut(let timeout):
            return "gh timed out after \(Int(timeout))s"
        case .invalidJSON(let detail):
            return detail
        }
    }
}

/// Read-only GitHub Actions access via the `gh` CLI.
enum GitHubActionsService {
    /// Hard ceiling so a stuck `gh` cannot hold the Actions coalesce latch forever.
    static let commandTimeout: TimeInterval = 25

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Remote resolution

    static func resolveGitHubRemote(repoPath: String) throws -> GitHubRemote {
        let url = try GitService.remoteURL(repoPath: repoPath, name: "origin")
        guard let remote = parseGitHubRemoteURL(url) else {
            throw GitHubActionsError.noGitHubRemote
        }
        return remote
    }

    /// Accepts HTTPS, SSH, and SSH-host-alias remotes that point at GitHub.
    static func parseGitHubRemoteURL(_ raw: String) -> GitHubRemote? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        // git@host:owner/repo.git
        if let at = url.firstIndex(of: "@"),
           let colon = url[url.index(after: at)...].firstIndex(of: ":"),
           !url.lowercased().hasPrefix("ssh://"),
           !url.lowercased().hasPrefix("http") {
            let host = String(url[url.index(after: at)..<colon])
            guard isGitHubHost(host) else { return nil }
            let path = String(url[url.index(after: colon)...])
            return remoteFromPath(path)
        }

        // ssh://git@host/owner/repo.git  or  https://host/owner/repo.git
        if let components = URLComponents(string: url),
           let host = components.host,
           isGitHubHost(host) {
            return remoteFromPath(components.path)
        }

        return nil
    }

    private static func isGitHubHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "github.com" || lower.hasSuffix(".github.com") || lower.contains("github.com")
    }

    private static func remoteFromPath(_ path: String) -> GitHubRemote? {
        let trimmed = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "", options: [.caseInsensitive, .anchored, .backwards])
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[parts.count - 2]
        let name = parts[parts.count - 1]
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return GitHubRemote(owner: owner, name: name)
    }

    // MARK: - Runs

    static func listRuns(remote: GitHubRemote, repoID: UUID, limit: Int = 30) async throws -> [ActionRun] {
        try Task.checkCancellation()
        let json = try await runGH([
            "run", "list",
            "--repo", remote.slug,
            "--limit", "\(limit)",
            "--json",
            "databaseId,status,conclusion,displayTitle,name,headBranch,createdAt,startedAt,updatedAt,url,event,workflowName,attempt"
        ])

        guard let data = json.data(using: .utf8) else {
            throw GitHubActionsError.invalidJSON("Empty run list")
        }

        let rows = try JSONDecoder().decode([GHRunListRow].self, from: data)
        return rows.map { $0.asActionRun(repoID: repoID) }
    }

    static func loadRunDetail(remote: GitHubRemote, run: ActionRun) async throws -> ActionRunDetail {
        try Task.checkCancellation()
        let json = try await runGH([
            "run", "view", "\(run.databaseId)",
            "--repo", remote.slug,
            "--json",
            "databaseId,status,conclusion,displayTitle,name,headBranch,createdAt,startedAt,updatedAt,url,event,workflowName,attempt,jobs"
        ])

        guard let data = json.data(using: .utf8) else {
            throw GitHubActionsError.invalidJSON("Empty run detail")
        }

        let row = try JSONDecoder().decode(GHRunDetailRow.self, from: data)
        let updated = row.asActionRun(repoID: run.repoID)
        let jobs = (row.jobs ?? []).map { $0.asActionJob() }
        return ActionRunDetail(run: updated, jobs: jobs)
    }

    // MARK: - Branches

    /// Branch heads are paged in full (repos here run to 129 branches, and GitHub's
    /// `TAG_COMMIT_DATE` ref ordering does not actually order branch heads by commit
    /// date — verified against a live repo — so nothing may be trusted to come first).
    private static let branchPageSize = 100
    private static let maxBranchPages = 5

    /// Divergence is resolved only for the most recently committed branches: the ones
    /// any activity window can realistically surface. Comparing all 129 branches cost
    /// ~4.4s per page against ~1.9s without, for numbers nothing would ever draw.
    private static let divergenceBranchLimit = 30

    /// Every branch head with its last commit, open PR, and (for the recent ones)
    /// divergence from the default branch.
    static func loadBranches(
        remote: GitHubRemote,
        defaultBranchHint: String?
    ) async throws -> (branches: [BranchInfo], defaultBranch: String) {
        try Task.checkCancellation()

        let heads = try await loadBranchHeads(remote: remote)
        // Self-heals if the default branch changed since the cached hint.
        let base = heads.defaultBranch ?? defaultBranchHint ?? "main"

        let recent = heads.heads
            .sorted { $0.lastCommitAt > $1.lastCommitAt }
            .prefix(divergenceBranchLimit)
            .map(\.name)

        let divergence = recent.isEmpty
            ? [:]
            : try await loadDivergence(remote: remote, branches: Array(recent))

        let branches = heads.heads.map { head -> BranchInfo in
            let d = divergence[head.name]
            return BranchInfo(
                name: head.name,
                lastCommitAt: head.lastCommitAt,
                ahead: d?.ahead ?? 0,
                behind: d?.behind ?? 0,
                isDefault: head.name == base,
                pullRequest: head.pullRequest,
                hasDivergence: d != nil
            )
        }

        return (branches, base)
    }

    private struct BranchHead {
        let name: String
        let lastCommitAt: Date
        let pullRequest: BranchPullRequest?
    }

    private static func loadBranchHeads(
        remote: GitHubRemote
    ) async throws -> (heads: [BranchHead], defaultBranch: String?) {
        var heads: [BranchHead] = []
        var defaultBranch: String?
        var cursor: String?

        for _ in 0..<maxBranchPages {
            try Task.checkCancellation()

            var arguments = [
                "api", "graphql",
                "-f", "query=\(branchHeadsQuery)",
                "-f", "owner=\(remote.owner)",
                "-f", "name=\(remote.name)"
            ]
            if let cursor {
                arguments.append(contentsOf: ["-f", "after=\(cursor)"])
            }

            let json = try await runGH(arguments)
            guard let data = json.data(using: .utf8) else {
                throw GitHubActionsError.invalidJSON("Empty branch list")
            }

            let decoded = try JSONDecoder().decode(GHBranchHeadsResponse.self, from: data)
            guard let repository = decoded.data?.repository else {
                throw GitHubActionsError.invalidJSON("No repository in branch response")
            }

            defaultBranch = defaultBranch ?? repository.defaultBranchRef?.name

            for node in repository.refs?.nodes ?? [] {
                guard let node,
                      let committed = parseDateIfPresent(node.target?.committedDate)
                else { continue }
                let pr = node.associatedPullRequests?.nodes?.compactMap { $0 }.first
                heads.append(
                    BranchHead(
                        name: node.name,
                        lastCommitAt: committed,
                        pullRequest: pr.map {
                            BranchPullRequest(
                                number: $0.number,
                                title: $0.title ?? "",
                                url: $0.url ?? "",
                                isDraft: $0.isDraft ?? false
                            )
                        }
                    )
                )
            }

            guard let page = repository.refs?.pageInfo, page.hasNextPage == true, let next = page.endCursor else {
                break
            }
            cursor = next
        }

        return (heads, defaultBranch)
    }

    struct BranchDivergence {
        let ahead: Int
        let behind: Int
    }

    /// One aliased query from the default branch outward, so `aheadBy`/`behindBy` read
    /// exactly the way GitHub's Branches page labels them (ahead of / behind the default).
    /// Aliases are generated (`b0`, `b1`, …) because branch names are not valid GraphQL names.
    private static func loadDivergence(
        remote: GitHubRemote,
        branches: [String]
    ) async throws -> [String: BranchDivergence] {
        try Task.checkCancellation()

        let fields = branches.enumerated()
            .map { index, name in
                "    b\(index): compare(headRef:\"\(escapeGraphQLString(name))\"){ aheadBy behindBy }"
            }
            .joined(separator: "\n")

        let query = """
        query($owner:String!,$name:String!){
          repository(owner:$owner,name:$name){
            defaultBranchRef{
        \(fields)
            }
          }
        }
        """

        let json = try await runGH([
            "api", "graphql",
            "-f", "query=\(query)",
            "-f", "owner=\(remote.owner)",
            "-f", "name=\(remote.name)"
        ])

        guard let data = json.data(using: .utf8) else {
            throw GitHubActionsError.invalidJSON("Empty divergence response")
        }

        let decoded = try JSONDecoder().decode(GHDivergenceResponse.self, from: data)
        let comparisons = decoded.data?.repository?.defaultBranchRef ?? [:]

        var result: [String: BranchDivergence] = [:]
        for (index, name) in branches.enumerated() {
            guard let comparison = comparisons["b\(index)"] ?? nil,
                  let ahead = comparison.aheadBy,
                  let behind = comparison.behindBy
            else { continue }
            result[name] = BranchDivergence(ahead: max(0, ahead), behind: max(0, behind))
        }
        return result
    }

    static func escapeGraphQLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let branchHeadsQuery = """
    query($owner:String!,$name:String!,$after:String){
      repository(owner:$owner,name:$name){
        defaultBranchRef{ name }
        refs(refPrefix:"refs/heads/",first:100,after:$after){
          pageInfo{ hasNextPage endCursor }
          nodes{
            name
            target{ ... on Commit { committedDate } }
            associatedPullRequests(first:1,states:OPEN){ nodes{ number title url isDraft } }
          }
        }
      }
    }
    """

    // MARK: - Formatting

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh%02dm%02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm%02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }

    // MARK: - gh process

    /// Same temp-file + watchdog runner as git (`ExternalProcess`).
    private static func runGH(_ arguments: [String]) async throws -> String {
        guard let executable = resolveGHPath() else {
            throw GitHubActionsError.ghNotFound
        }

        try Task.checkCancellation()

        let environment = ghEnvironment()
        do {
            return try await Task.detached(priority: .utility) {
                try ExternalProcess.run(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    timeout: commandTimeout
                )
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch ExternalProcessError.timedOut(let seconds) {
            throw GitHubActionsError.timedOut(seconds)
        } catch ExternalProcessError.failed(let status, let stderr) {
            throw GitHubActionsError.ghFailed(status: status, stderr: stderr)
        }
    }

    private static func ghEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        if !path.contains("/opt/homebrew/bin") {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + path
        }
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        if env["LC_ALL"] == nil {
            env["LC_ALL"] = "C"
        }
        return env
    }

    private static func resolveGHPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func parseDate(_ raw: String?) -> Date {
        parseDateIfPresent(raw) ?? Date.distantPast
    }

    /// Parses GitHub/gh timestamps; rejects empty, year-0001 placeholders, and pre-Actions epochs.
    static func parseDateIfPresent(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("0001-") else { return nil }
        let parsed: Date?
        if let d = isoFractional.date(from: raw) {
            parsed = d
        } else if let d = isoBasic.date(from: raw) {
            parsed = d
        } else {
            parsed = nil
        }
        guard let parsed, ActionTiming.isPlausible(parsed) else { return nil }
        return parsed
    }
}

// MARK: - gh JSON DTOs

private struct GHRunListRow: Decodable {
    let databaseId: Int
    let status: String
    let conclusion: String?
    let displayTitle: String?
    let name: String?
    let headBranch: String?
    let createdAt: String?
    let startedAt: String?
    let updatedAt: String?
    let url: String?
    let event: String?
    let workflowName: String?
    let attempt: Int?

    func asActionRun(repoID: UUID) -> ActionRun {
        let created = GitHubActionsService.parseDate(createdAt)
        // Keep missing startedAt as distantPast so timing falls back to createdAt
        // without pretending the attempt started at creation on a re-run.
        let started = GitHubActionsService.parseDate(startedAt)
        return ActionRun(
            databaseId: databaseId,
            repoID: repoID,
            workflowName: workflowName ?? name ?? "Workflow",
            displayTitle: displayTitle ?? name ?? "Workflow run",
            headBranch: headBranch ?? "—",
            event: event ?? "",
            status: status,
            conclusion: conclusion,
            createdAt: created,
            startedAt: started,
            updatedAt: GitHubActionsService.parseDate(updatedAt),
            url: url ?? "",
            attempt: max(1, attempt ?? 1)
        )
    }
}

private struct GHRunDetailRow: Decodable {
    let databaseId: Int
    let status: String
    let conclusion: String?
    let displayTitle: String?
    let name: String?
    let headBranch: String?
    let createdAt: String?
    let startedAt: String?
    let updatedAt: String?
    let url: String?
    let event: String?
    let workflowName: String?
    let attempt: Int?
    let jobs: [GHJob]?

    func asActionRun(repoID: UUID) -> ActionRun {
        let created = GitHubActionsService.parseDate(createdAt)
        let started = GitHubActionsService.parseDate(startedAt)
        return ActionRun(
            databaseId: databaseId,
            repoID: repoID,
            workflowName: workflowName ?? name ?? "Workflow",
            displayTitle: displayTitle ?? name ?? "Workflow run",
            headBranch: headBranch ?? "—",
            event: event ?? "",
            status: status,
            conclusion: conclusion,
            createdAt: created,
            startedAt: started,
            updatedAt: GitHubActionsService.parseDate(updatedAt),
            url: url ?? "",
            attempt: max(1, attempt ?? 1)
        )
    }
}

private struct GHJob: Decodable {
    let databaseId: Int?
    let name: String?
    let status: String?
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let url: String?
    let steps: [GHStep]?

    func asActionJob() -> ActionJob {
        ActionJob(
            id: databaseId ?? 0,
            name: name ?? "Job",
            status: status ?? "",
            conclusion: conclusion,
            startedAt: optionalDate(startedAt),
            completedAt: optionalDate(completedAt),
            steps: (steps ?? []).map { $0.asActionStep() },
            url: url
        )
    }

    private func optionalDate(_ raw: String?) -> Date? {
        GitHubActionsService.parseDateIfPresent(raw)
    }
}

private struct GHStep: Decodable {
    let number: Int?
    let name: String?
    let status: String?
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?

    func asActionStep() -> ActionStep {
        ActionStep(
            number: number ?? 0,
            name: name ?? "Step",
            status: status ?? "",
            conclusion: conclusion,
            startedAt: optionalDate(startedAt),
            completedAt: optionalDate(completedAt)
        )
    }

    private func optionalDate(_ raw: String?) -> Date? {
        GitHubActionsService.parseDateIfPresent(raw)
    }
}

// MARK: - gh GraphQL DTOs (branches)

private struct GHBranchHeadsResponse: Decodable {
    let data: DataBlock?

    struct DataBlock: Decodable {
        let repository: Repository?
    }

    struct Repository: Decodable {
        let defaultBranchRef: RefName?
        let refs: RefConnection?
    }

    struct RefName: Decodable {
        let name: String
    }

    struct RefConnection: Decodable {
        let pageInfo: PageInfo?
        let nodes: [RefNode?]?
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool?
        let endCursor: String?
    }

    struct RefNode: Decodable {
        let name: String
        let target: Target?
        let associatedPullRequests: PRConnection?
    }

    struct Target: Decodable {
        let committedDate: String?
    }

    struct PRConnection: Decodable {
        let nodes: [PRNode?]?
    }

    struct PRNode: Decodable {
        let number: Int
        let title: String?
        let url: String?
        let isDraft: Bool?
    }
}

private struct GHDivergenceResponse: Decodable {
    let data: DataBlock?

    struct DataBlock: Decodable {
        let repository: Repository?
    }

    struct Repository: Decodable {
        /// Generated aliases (`b0`, `b1`, …) → comparison, so the keys are dynamic.
        let defaultBranchRef: [String: Comparison?]?
    }

    struct Comparison: Decodable {
        let aheadBy: Int?
        let behindBy: Int?
    }
}
