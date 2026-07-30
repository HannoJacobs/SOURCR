import Foundation

enum GitHubActionsError: LocalizedError {
    case ghNotFound
    case noGitHubRemote
    case ghFailed(status: Int32, stderr: String)
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
        case .invalidJSON(let detail):
            return detail
        }
    }
}

/// Read-only GitHub Actions access via the `gh` CLI.
enum GitHubActionsService {
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

    /// Prefer the user's real environment (so `HOME` / `gh` auth config resolve),
    /// and make the wait cancellable so rapid Diff↔Actions toggles don't pile up.
    private static func runGH(_ arguments: [String]) async throws -> String {
        guard let executable = resolveGHPath() else {
            throw GitHubActionsError.ghNotFound
        }

        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ghEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let box = ResumeOnce(continuation)

                process.terminationHandler = { proc in
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""

                    if proc.terminationStatus == 0 {
                        box.resume(.success(out))
                    } else if proc.terminationReason == .uncaughtSignal {
                        box.resume(.failure(CancellationError()))
                    } else {
                        box.resume(.failure(
                            GitHubActionsError.ghFailed(status: proc.terminationStatus, stderr: err)
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    box.resume(.failure(error))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
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

/// Ensures a CheckedContinuation is resumed exactly once across process callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private let continuation: CheckedContinuation<String, Error>

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        continuation.resume(with: result)
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
