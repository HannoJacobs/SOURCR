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

    static func migrateLegacyRepository(_ repo: WatchedRepo) -> WatchedRepo? {
        if repo.githubRemote != nil { return repo }
        if let remote = parseGitHubRemoteURL(repo.path) { return repo.linked(to: remote) }
        guard FileManager.default.fileExists(atPath: repo.path),
              let remote = try? resolveGitHubRemote(repoPath: repo.path) else { return nil }
        return repo.linked(to: remote)
    }

    /// Accepts repository URLs, SSH origins (including existing host aliases),
    /// and owner/repo. Reject subpages instead of watching the wrong repository.
    static func parseGitHubRemoteURL(_ raw: String) -> GitHubRemote? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        // git@host:owner/repo.git
        if url.hasPrefix("git@"), let at = url.firstIndex(of: "@"),
           let colon = url[url.index(after: at)...].firstIndex(of: ":"),
           !url.lowercased().hasPrefix("ssh://"),
           !url.lowercased().hasPrefix("http") {
            let host = String(url[url.index(after: at)..<colon])
            guard isGitHubSSHHost(host) else { return nil }
            let path = String(url[url.index(after: colon)...])
            return remoteFromPath(path)
        }

        // ssh://git@host/owner/repo.git  or  https://host/owner/repo.git
        if let components = URLComponents(string: url),
           let host = components.host,
           ["https", "ssh"].contains(components.scheme?.lowercased() ?? ""),
           components.query == nil, components.fragment == nil,
           components.password == nil,
           (components.scheme?.lowercased() == "ssh"
                ? isGitHubSSHHost(host)
                : host.lowercased() == "github.com" && components.user == nil) {
            return remoteFromPath(components.path)
        }

        guard !url.contains("://"), !url.hasPrefix("/") else { return nil }
        return remoteFromPath(url)
    }

    private static func isGitHubSSHHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "github.com" || lower.hasPrefix("github.com-")
    }

    private static func remoteFromPath(_ path: String) -> GitHubRemote? {
        let trimmed = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "", options: [.caseInsensitive, .anchored, .backwards])
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        let name = parts[1]
        let ownerChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let repoChars = ownerChars.union(CharacterSet(charactersIn: "._"))
        guard !owner.isEmpty, !name.isEmpty, name != ".", name != "..",
              owner.unicodeScalars.allSatisfy({ ownerChars.contains($0) }),
              name.unicodeScalars.allSatisfy({ repoChars.contains($0) }) else { return nil }
        return GitHubRemote(owner: owner, name: name)
    }

    // MARK: - Runs

    static func listRuns(remote: GitHubRemote, repoID: UUID, limit: Int = 30, credential: GitHubCredential) async throws -> [ActionRun] {
        try Task.checkCancellation()
        let json = try await runGH([
            "run", "list",
            "--repo", remote.slug,
            "--limit", "\(limit)",
            "--json",
            "databaseId,status,conclusion,displayTitle,name,headBranch,createdAt,startedAt,updatedAt,url,event,workflowName,attempt"
        ], credential: credential)

        guard let data = json.data(using: .utf8) else {
            throw GitHubActionsError.invalidJSON("Empty run list")
        }

        let rows = try JSONDecoder().decode([GHRunListRow].self, from: data)
        return rows.map { $0.asActionRun(repoID: repoID) }
    }

    static func loadRunDetail(remote: GitHubRemote, run: ActionRun, credential: GitHubCredential) async throws -> ActionRunDetail {
        try Task.checkCancellation()
        let json = try await runGH([
            "run", "view", "\(run.databaseId)",
            "--repo", remote.slug,
            "--json",
            "databaseId,status,conclusion,displayTitle,name,headBranch,createdAt,startedAt,updatedAt,url,event,workflowName,attempt,jobs"
        ], credential: credential)

        guard let data = json.data(using: .utf8) else {
            throw GitHubActionsError.invalidJSON("Empty run detail")
        }

        let row = try JSONDecoder().decode(GHRunDetailRow.self, from: data)
        let updated = row.asActionRun(repoID: run.repoID)
        let jobs = (row.jobs ?? []).map { $0.asActionJob() }
        return ActionRunDetail(run: updated, jobs: jobs)
    }

    // MARK: - Branches

    /// Fetch every remote head: GitHub's branch-ref ordering cannot be trusted to
    /// return newest commits first, and Show more must reach older branches too.
    private static let divergenceBatchSize = 30

    /// Every branch head with its last commit, checks, PR and default-branch divergence.
    static func loadBranches(
        remote: GitHubRemote,
        defaultBranchHint: String?,
        credential: GitHubCredential
    ) async throws -> (branches: [BranchInfo], defaultBranch: String) {
        try Task.checkCancellation()

        let heads = try await loadBranchHeads(remote: remote, credential: credential)
        // Self-heals if the default branch changed since the cached hint.
        let base = heads.defaultBranch ?? defaultBranchHint ?? "main"

        let names = heads.heads.map(\.name)
        var divergence: [String: BranchDivergence] = [:]
        for start in stride(from: 0, to: names.count, by: divergenceBatchSize) {
            let batch = Array(names[start..<min(start + divergenceBatchSize, names.count)])
            let values = try await loadDivergence(remote: remote, branches: batch, credential: credential)
            divergence.merge(values) { _, new in new }
        }

        // Non-fatal: a PR hiccup must not blank out divergence and the branch list too.
        var pullRequests: [String: BranchPullRequest] = [:]
        do {
            pullRequests = try await loadPullRequestsByHeadBranch(remote: remote, branches: names, credential: credential)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppDiagnostics.error(
                .appState,
                "pull request fetch failed repo=\(remote.slug) error=\(error.localizedDescription)"
            )
        }

        // Only refs that still exist on the remote become rows, so a branch deleted after
        // its PR merged drops off the board even while its workflow runs are still listed.
        let branches = heads.heads.map { head -> BranchInfo in
            let d = divergence[head.name]
            return BranchInfo(
                name: head.name,
                lastCommitAt: head.lastCommitAt,
                ahead: d?.ahead ?? 0,
                behind: d?.behind ?? 0,
                isDefault: head.name == base,
                pullRequest: pullRequests[head.name],
                hasDivergence: d != nil,
                headOID: head.oid,
                checkState: head.checkState
            )
        }

        return (branches, base)
    }

    private struct BranchHead {
        let name: String
        let lastCommitAt: Date
        let oid: String
        let checkState: BranchCheckState?
    }

    private static func loadBranchHeads(
        remote: GitHubRemote, credential: GitHubCredential
    ) async throws -> (heads: [BranchHead], defaultBranch: String?) {
        var heads: [BranchHead] = []
        var defaultBranch: String?
        var cursor: String?

        while true {
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

            let json = try await runGH(arguments, credential: credential)
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
                heads.append(BranchHead(
                    name: node.name, lastCommitAt: committed,
                    oid: node.target?.oid ?? "",
                    checkState: BranchCheckState.fromRollup(node.target?.statusCheckRollup?.state)
                ))
            }

            guard let page = repository.refs?.pageInfo, page.hasNextPage == true, let next = page.endCursor else {
                break
            }
            guard next != cursor else {
                throw GitHubActionsError.invalidJSON("Branch pagination did not advance")
            }
            cursor = next
        }

        return (heads, defaultBranch)
    }

    /// Resolve the newest PR for each existing head explicitly, so expanding an old
    /// branch does not lose its PR merely because a repository has newer PR history.
    static func loadPullRequestsByHeadBranch(
        remote: GitHubRemote, branches: [String], credential: GitHubCredential
    ) async throws -> [String: BranchPullRequest] {
        var result: [String: BranchPullRequest] = [:]
        for start in stride(from: 0, to: branches.count, by: divergenceBatchSize) {
            try Task.checkCancellation()
            let batch = Array(branches[start..<min(start + divergenceBatchSize, branches.count)])
            let fields = batch.enumerated().map { index, name in
                "b\(index): pullRequests(headRefName:\"\(escapeGraphQLString(name))\",states:[OPEN,CLOSED,MERGED],first:1,orderBy:{field:UPDATED_AT,direction:DESC}){ nodes{ number title url isDraft state headRefName updatedAt headRefOid } }"
            }.joined(separator: "\n")
            let query = """
            query($owner:String!,$name:String!){
              repository(owner:$owner,name:$name){
            \(fields)
              }
            }
            """
            let json = try await runGH([
                "api", "graphql", "-f", "query=\(query)",
                "-f", "owner=\(remote.owner)", "-f", "name=\(remote.name)"
            ], credential: credential)
            guard let data = json.data(using: .utf8) else {
                throw GitHubActionsError.invalidJSON("Empty pull request list")
            }
            let decoded = try JSONDecoder().decode(GHPullRequestsResponse.self, from: data)
            guard let repository = decoded.data?.repository else {
                throw GitHubActionsError.invalidJSON("No repository in pull request response")
            }
            for (index, name) in batch.enumerated() {
                guard let connection = repository["b\(index)"] ?? nil,
                      let node = connection.nodes?.compactMap({ $0 }).first else { continue }
                result[name] = BranchPullRequest(
                    number: node.number, title: node.title ?? "", url: node.url ?? "",
                    state: PullRequestState.from(rawState: node.state ?? "OPEN", isDraft: node.isDraft ?? false),
                    updatedAt: node.updatedAt, headOID: node.headRefOid
                )
            }
        }
        return result
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
        branches: [String], credential: GitHubCredential
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
        ], credential: credential)

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
            target{ ... on Commit { oid committedDate statusCheckRollup{ state } } }
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
    private static func runGH(_ arguments: [String], credential: GitHubCredential) async throws -> String {
        guard let executable = SOURCRGitHubEnvironment.executable else {
            throw GitHubActionsError.ghNotFound
        }

        try Task.checkCancellation()

        let environment = SOURCRGitHubEnvironment.authenticated(credential)
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
            throw GitHubActionsError.ghFailed(status: status, stderr: stderr.replacingOccurrences(of: credential.token, with: "[redacted]"))
        }
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
    }

    struct Target: Decodable {
        let committedDate: String?
        let oid: String?
        let statusCheckRollup: Rollup?
    }

    struct Rollup: Decodable {
        let state: String?
    }
}

private struct GHPullRequestsResponse: Decodable {
    let data: DataBlock?

    struct DataBlock: Decodable {
        let repository: [String: PRConnection?]?
    }

    struct PRConnection: Decodable {
        let nodes: [PRNode?]?
    }

    struct PRNode: Decodable {
        let number: Int
        let title: String?
        let url: String?
        let isDraft: Bool?
        let state: String?
        let headRefName: String?
        let updatedAt: String?
        let headRefOid: String?
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
